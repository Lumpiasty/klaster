# supervisord image: persistent rootfs ("VPS mode")

The `llama/supervisord` pod behaves like a small VPS: its root filesystem lives
on the `llama-rootfs-lvmssd` PVC (30Gi, btrfs, ssd-lvmpv), so `apt install`,
a custom Mesa in `/usr`, sshd, etc. survive pod restarts. Models, builds and
`supervisord.conf` stay on the existing `llama-models-lvmssd` PVC at `/root`.

## How it works

`ENTRYPOINT` is `/boot.sh` (outside the chroot):

1. PVC is mounted at `/rootfs`; the chroot is `/rootfs/os`.
2. If `/rootfs/os/var/lib/rootfs-seed/seeded` is missing, copy the image's root
   (`tar --one-file-system`, so `/proc /sys /dev /root /rootfs` are not copied) into
   `/rootfs/os.seeding`, then `mv` it to `/rootfs/os`. The rename is the commit
   point; a killed seed leaves only `os.seeding`, which is deleted on next boot.
   The seed records `packages.seed` (dpkg list at seed time) and `seeded` (date, hash).
3. Every boot: clean `/tmp` and `/run` in the rootfs, `rbind` `/dev` (includes
   `/dev/kfd`, `/dev/dri`, `/dev/shm`), `/proc`, `/sys`, `/root`, and bind the
   kubelet files `/etc/resolv.conf`, `/etc/hosts`, `/etc/hostname`.
4. `exec chroot /rootfs/os /entrypoint.sh` -> `exec supervisord -n -c $WORKSPACE/supervisord.conf`.
   Everything is `exec`, so PID 1 is still supervisord (as before) and SIGTERM from
   kubelet reaches it. Pod env (`WORKSPACE`, ...) is inherited unchanged.

If anything in the prepare step fails (PVC missing, disk full, ...), the script
logs `[boot] ...` and boots the plain image so inference still works.

## Escape hatches

- Skip the chroot without redeploying: `touch /root/.no-chroot` (models PVC)
  then restart the pod. Or set env `SUPERVISORD_NO_CHROOT=1` on the container.
  Remove the file/env to return.
- Factory reset: `touch /root/.rootfs-reset` and restart; the rootfs is wiped
  and reseeded from the current image on that boot (file is deleted).
  Offline alternative: scale to 0 and empty the PVC, or delete `/rootfs/os`.
- Because the plain-image fallback is always available, `kubectl exec` still
  works for repair even if the rootfs is broken.

## Image updates no longer apply automatically (drift)

After the first seed, `/rootfs/os` is the machine; new image builds change
nothing in it (including `/entrypoint.sh` and the Debian packages). To adopt a
new image either factory-reset (loses hand-made changes) or apply changes by hand
(`apt full-upgrade`, copy a new `/entrypoint.sh` from the plain image:
`touch /root/.no-chroot`, restart, then `cp /entrypoint.sh /rootfs/os/entrypoint.sh`).
Keep the Dockerfile's package list in sync with what you want after a reset.

Record hand-installed things so they can be folded back into the Dockerfile:

```sh
# inside the pod: what differs from the seed
dpkg-query -W -f='${binary:Package}\t${Version}\n' | diff /var/lib/rootfs-seed/packages.seed - 
apt-mark showmanual > /root/packages-manual.txt   # lives on the models PVC
```

Anything not under `/root` and not from apt (custom Mesa under `/usr/local`, `/etc`
edits) should get a line in `/root/rootfs-notes.md`.

## Optional: sshd (not enabled, nothing exposed)

Inside the pod: `apt install openssh-server`, put keys in `/root/.ssh/authorized_keys`,
`mkdir -p /run/sshd` (`/run` is cleaned each boot), `ssh-keygen -A` (host keys persist).
Add to `/root/supervisord.conf` (autostart off by default):

```ini
[program:sshd]
command=/usr/sbin/sshd -D -e
autostart=false
autorestart=true
stdout_logfile=/tmp/sshd.log
redirect_stderr=true
```

Start with `supervisorctl start sshd`. To reach it, prefer
`kubectl -n llama port-forward deploy/supervisord 2222:22`. Exposing it via a
Service/ingress is a deliberate separate change (the pod is privileged).
Do not use `PermitRootLogin yes` with password auth.

## Rollout

Flux applies `apps/` on push to `fresh-start` (Woodpecker triggers
`flux reconcile source git`), and Woodpecker builds the image on pushes touching
`docker/**`. Pushing therefore deploys. Two commits so the pod restarts once:

1. Commit 1 (image + PVC + this README): push. CI builds
   `gitea.lumpiasty.xyz/lumpiasty/supervisord:latest` and `:<sha8>`; Flux creates the
   rootfs PVC. Pod is untouched.
2. Get the new digest, put it in `apps/llama/deployment.yaml` (commit 2 carries the
   volume/mount and needs the digest filled in), push. One restart: seed runs
   (~1.1G image root: expect roughly 30-90 s extra), then supervisord starts.
   Total downtime about 1-2 min (pod is `Recreate`, GPU is exclusive).
3. Verify: `kubectl -n llama logs deploy/supervisord | grep '\[boot\]'`,
   `exec` -> `ls /rootfs/os` is NOT visible inside the chroot (the PVC is not
   mounted there; check `cat /proc/1/root` or `findmnt /` instead: `/` is on the rootfs PVC),
   `ls -l /dev/kfd /dev/dri`, `supervisorctl status`, hit llama-swap.

## Rollback

Revert the deployment to the previous image digest (and optionally drop the
rootfs mount); the old image's entrypoint ignores the PVC. Keep the PVC: the
installed system is still there. Quicker without a deploy: `touch /root/.no-chroot`.

## Known limits

- The pod is privileged; it needs `mount`. Do not drop `privileged`.
- `/dev/shm` stays the kubelet's 64M (same as before; `LLAMA_VRAM_ARENA` lives there).
- Mounts made by the boot script exist only in the container's mount namespace
  (gone on restart; redone each boot).
- `/tmp` and `/run` are wiped on each boot, but are on disk (not tmpfs).
- `terminationGracePeriodSeconds` is 60 so apt/dpkg and llama-swap (stopwaitsecs=30)
  can finish before SIGKILL.
