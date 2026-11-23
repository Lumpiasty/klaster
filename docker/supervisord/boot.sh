#!/usr/bin/env bash
# Container entrypoint: pivot_root into a persistent root filesystem kept on a
# PVC, then boot systemd in it (or, without systemd, run /entrypoint.sh ->
# supervisord directly).
# Because the whole mount namespace is pivoted (not chrooted), `kubectl exec`
# lands in the persistent rootfs too.
# See README.md in this directory. Any failure while preparing the rootfs falls
# back to booting the plain image so inference keeps working.
#
# Inputs:
#   /rootfs                    PVC mount point (holds $NEWROOT and seed temp dir)
#   SUPERVISORD_NO_PIVOT=1     env var: skip the rootfs, boot plain image
#   /root/.no-pivot            file on the models PVC: same, no redeploy needed
#   SUPERVISORD_NO_SYSTEMD=1   env var: pivot, but run supervisord as PID 1
#   /root/.no-systemd          file on the models PVC: same, no redeploy needed
#   /root/.rootfs-reset        file on the models PVC: wipe rootfs and reseed
#                              on this boot (file is removed afterwards)

RFS_PVC="${RFS_PVC:-/rootfs}"
NEWROOT="$RFS_PVC/os"
SEEDTMP="$RFS_PVC/os.seeding"
SEEDINFO=var/lib/rootfs-seed
INNER=/entrypoint.sh
SYSTEMD=/usr/lib/systemd/systemd
UNIT=rootfs-supervisord.service

# Units that would try to act on the host (devices, kernel modules, sysctls,
# clock); the pod has CAP_SYS_ADMIN, and these were outright harmful back when
# it was privileged. Also things that make no sense in a pod. Masked in /run
# on every boot, so packages installed later cannot re-enable them; a unit
# file of the same name in /etc still wins.
MASK=(
    systemd-udevd.service systemd-udevd-control.socket
    systemd-udevd-kernel.socket systemd-udev-trigger.service
    systemd-udev-settle.service systemd-hwdb-update.service
    systemd-sysctl.service systemd-modules-load.service kmod-static-nodes.service
    systemd-binfmt.service proc-sys-fs-binfmt_misc.automount
    proc-sys-fs-binfmt_misc.mount
    systemd-remount-fs.service systemd-pstore.service systemd-random-seed.service
    systemd-timesyncd.service systemd-networkd.service systemd-resolved.service
    systemd-firstboot.service systemd-machine-id-commit.service
    systemd-journald-audit.socket systemd-tpm2-setup.service
    systemd-tpm2-setup-early.service systemd-pcrmachine.service
    systemd-hibernate-resume.service systemd-boot-update.service
    sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount
    sys-fs-fuse-connections.mount dev-hugepages.mount dev-mqueue.mount
    getty.target console-getty.service getty@tty1.service
    swap.target cryptsetup.target tmp.mount
    # the Debian package's own supervisord (/etc/supervisor); ours is $UNIT
    supervisor.service
)

log() { echo "[boot] $*" >&2; }

# Pod env (WORKSPACE, ...) for systemd services, which get a clean env.
write_env() {
    local kv k v
    while IFS= read -r -d '' kv; do
        k=${kv%%=*} v=${kv#*=}
        [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        case $k in HOME|PWD|OLDPWD|SHLVL|_|container) continue ;; esac
        v=${v//\\/\\\\} v=${v//\"/\\\"}
        printf '%s="%s"\n' "$k" "$v"
    done < <(env -0)
}

# Runtime glue in /run (a fresh tmpfs each boot): masks, the supervisord
# unit, pod env. Lives outside /etc so the rootfs itself stays untouched.
prepare_systemd() {
    local rs="$NEWROOT/run/systemd/system" u
    mkdir -p "$rs/multi-user.target.wants"
    for u in "${MASK[@]}"; do ln -sfn /dev/null "$rs/$u"; done

    write_env > "$NEWROOT/run/pod.env"
    cat > "$rs/$UNIT" <<EOF
[Unit]
Description=supervisord from \$WORKSPACE (llama-swap etc.)
After=network.target

[Service]
EnvironmentFile=/run/pod.env
ExecStart=$INNER
KillMode=mixed
TimeoutStopSec=45
Restart=always
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    ln -sfn "../$UNIT" "$rs/multi-user.target.wants/$UNIT"

    # journald must not try to ingest the host's kernel log (/dev/kmsg).
    mkdir -p "$NEWROOT/run/systemd/journald.conf.d"
    printf '[Journal]\nReadKMsg=no\n' \
        > "$NEWROOT/run/systemd/journald.conf.d/50-pod.conf"

    # systemd's status lines and $UNIT's output go to /dev/console, which
    # only exists with `tty: true` in the pod spec; that is `kubectl logs`.
    [[ -e /dev/console ]] || log "no /dev/console (set tty: true); logs only in journal"
}

prepare() {
    set -euo pipefail

    mountpoint -q "$RFS_PVC" || { log "$RFS_PVC is not a mount point (PVC missing?)"; return 1; }

    if [[ -e /root/.rootfs-reset ]]; then
        log "factory reset requested via /root/.rootfs-reset"
        rm -rf --one-file-system "$NEWROOT" "$SEEDTMP"
        rm -f /root/.rootfs-reset
    fi

    # The rename of $SEEDTMP -> $NEWROOT is the commit point: a copy killed
    # half way leaves only $SEEDTMP, which is discarded on the next boot.
    if [[ ! -e "$NEWROOT/$SEEDINFO/seeded" ]]; then
        log "seeding $NEWROOT from the image"
        rm -rf --one-file-system "$NEWROOT" "$SEEDTMP"
        mkdir -p "$SEEDTMP"
        # --one-file-system: other mounts (/proc /sys /dev /root /rootfs and
        # kubelet bind-mounts of directories) are stored as empty directories,
        # which become the mount points. Bind-mounted *files* (/etc/hosts,
        # resolv.conf, hostname) are copied as plain files and re-bound below.
        tar --one-file-system --numeric-owner --xattrs \
            --xattrs-include='security.capability' -C / -cf - . \
            | tar -C "$SEEDTMP" --numeric-owner --xattrs \
                  --xattrs-include='security.capability' -xpf -
        mkdir -p "$SEEDTMP/$SEEDINFO"
        dpkg-query -W -f='${binary:Package}\t${Version}\n' \
            > "$SEEDTMP/$SEEDINFO/packages.seed"
        {
            echo "seeded_at=$(date -u +%FT%TZ)"
            echo "dpkg_status_sha256=$(sha256sum /var/lib/dpkg/status | cut -d' ' -f1)"
            echo "image_hostname=$(cat /etc/hostname)"
        } > "$SEEDTMP/$SEEDINFO/seeded"
        sync
        mv "$SEEDTMP" "$NEWROOT"
        log "seed done"
    fi

    # pivot_root refuses shared mounts; keep our mounts out of the host too.
    mount --make-rprivate /
    # pivot_root needs new_root to be a mount point. Bind it before the
    # submounts below so they sit on top of this bind.
    mountpoint -q "$NEWROOT" || mount --bind "$NEWROOT" "$NEWROOT"

    # /dev carries /dev/dri/renderD* (from the device plugin), /dev/shm and
    # /dev/termination-log; /root is the models PVC.
    mkdir -p "$NEWROOT"/{dev,proc,sys,root,run,tmp}
    for d in dev proc sys root; do
        if ! mountpoint -q "$NEWROOT/$d"; then
            mount --rbind "/$d" "$NEWROOT/$d"
        fi
    done

    # An unprivileged pod gets /sys/fs/cgroup (its own cgroup namespace)
    # read-only; systemd as PID 1 needs it writable to manage its units.
    # Only this mount's flag changes (bind remount), /sys stays read-only.
    # Not fatal: without it systemd fails to boot, but supervisord still runs
    # via SUPERVISORD_NO_SYSTEMD / /root/.no-systemd.
    local cg="$NEWROOT/sys/fs/cgroup"
    if [[ ",$(findmnt -no VFS-OPTIONS "$cg" 2>/dev/null)," == *,ro,* ]]; then
        mount -o remount,bind,rw "$cg" \
            || log "could not make $cg writable; systemd will likely fail"
    fi

    # /run is a fresh tmpfs (systemd expects that). /tmp stays on disk (builds
    # can be large) and is emptied instead.
    mountpoint -q "$NEWROOT/run" \
        || mount -t tmpfs -o mode=755,nosuid,nodev,size=256m tmpfs "$NEWROOT/run"
    find "$NEWROOT/tmp" -mindepth 1 -delete 2>/dev/null || true
    chmod 1777 "$NEWROOT/tmp"

    # kubelet-managed files; a symlink here (e.g. from a resolver package)
    # would make the bind land somewhere else, so replace it with a file.
    for f in etc/resolv.conf etc/hosts etc/hostname; do
        [[ -L "$NEWROOT/$f" ]] && rm -f "$NEWROOT/$f"
        [[ -e "$NEWROOT/$f" ]] || : > "$NEWROOT/$f"
        mountpoint -q "$NEWROOT/$f" || mount --bind "/$f" "$NEWROOT/$f"
    done

    [[ -x "$NEWROOT$INNER" ]] || { log "$INNER missing in $NEWROOT"; return 1; }

    # Boot systemd if the rootfs has it (decided after seeding). The glue in
    # /run/systemd/system doubles as the marker the parent checks.
    if [[ -z "${SUPERVISORD_NO_SYSTEMD:-}" && ! -e /root/.no-systemd \
          && -x "$NEWROOT$SYSTEMD" ]]; then
        prepare_systemd
    fi
}

# Run $INNER without systemd. The image's STOPSIGNAL is SIGRTMIN+3 (what
# systemd wants); supervisord ignores that, so keep bash as PID 1 and
# translate it to SIGTERM.
run_inner() {
    "$INNER" "$@" &
    local child=$!
    trap 'kill -TERM $child 2>/dev/null' TERM INT RTMIN+3
    while kill -0 "$child" 2>/dev/null; do wait "$child"; done
    wait "$child"
    exit
}

if [[ "${1:-}" == "--prepare" ]]; then
    prepare
    exit
fi

if [[ -n "${SUPERVISORD_NO_PIVOT:-}" || -e /root/.no-pivot ]]; then
    log "rootfs disabled, booting plain image"
    run_inner "$@"
fi

# Re-run ourselves for the risky part so set -e works and failure is catchable.
# Mounts are per mount namespace, so the child's work is visible here.
if "$0" --prepare; then
    log "pivoting into $NEWROOT"
    # `pivot_root . .` stacks the old root on top of the new one; the lazy
    # umount then drops it (same trick runc uses). pivot_root also moves the
    # root/cwd of every process in the namespace, and runc exec joins the
    # namespace at its root, so kubectl exec sees the new root.
    if cd "$NEWROOT" && pivot_root . .; then
        umount -l . || log "could not detach old root (continuing)"
        cd /
        if [[ -d /run/systemd/system ]]; then
            log "booting systemd"
            exec env container=docker "$SYSTEMD"
        fi
        log "no systemd, running $INNER"
        run_inner "$@"
    fi
    log "pivot_root failed"
    cd /
fi

log "rootfs preparation failed, booting plain image"
run_inner "$@"
