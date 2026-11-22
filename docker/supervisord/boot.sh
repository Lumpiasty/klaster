#!/usr/bin/env bash
# Container entrypoint: run the image's normal entrypoint (/entrypoint.sh ->
# supervisord) inside a persistent root filesystem kept on a PVC.
# See README.md in this directory. Any failure while preparing the rootfs falls
# back to booting the plain image so inference keeps working.
#
# Inputs:
#   /rootfs                    PVC mount point (holds $NEWROOT and seed temp dir)
#   /root/.no-chroot           file on the models PVC: same, no redeploy needed
#   /root/.rootfs-reset        file on the models PVC: wipe rootfs and reseed
#                              on this boot (file is removed afterwards)

RFS_PVC="${RFS_PVC:-/rootfs}"
NEWROOT="$RFS_PVC/os"
SEEDTMP="$RFS_PVC/os.seeding"
SEEDINFO=var/lib/rootfs-seed
INNER=/entrypoint.sh

log() { echo "[boot] $*" >&2; }

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

    # Fresh state for volatile dirs (they live on disk now, so stale sockets
    # and pidfiles from the previous boot would otherwise survive).
    find "$NEWROOT/tmp" "$NEWROOT/run" -mindepth 1 -delete 2>/dev/null || true

    mkdir -p "$NEWROOT"/{dev,proc,sys,root}
    for d in dev proc sys root; do
        if ! mountpoint -q "$NEWROOT/$d"; then
            mount --rbind "/$d" "$NEWROOT/$d"
            mount --make-rslave "$NEWROOT/$d"
        fi
    done

    # kubelet-managed files; a symlink here (e.g. from a resolver package)
    # would make the bind land somewhere else, so replace it with a file.
    for f in etc/resolv.conf etc/hosts etc/hostname; do
        [[ -L "$NEWROOT/$f" ]] && rm -f "$NEWROOT/$f"
        [[ -e "$NEWROOT/$f" ]] || : > "$NEWROOT/$f"
        mountpoint -q "$NEWROOT/$f" || mount --bind "/$f" "$NEWROOT/$f"
    done

    [[ -x "$NEWROOT$INNER" ]] || { log "$INNER missing in $NEWROOT"; return 1; }
}

if [[ "${1:-}" == "--prepare" ]]; then
    prepare
    exit
fi

# Re-run ourselves for the risky part so set -e works and failure is catchable.
if "$0" --prepare; then
    log "entering $NEWROOT"
    exit
    # exec chain keeps PID 1 = supervisord and the pod env untouched.
fi

log "rootfs preparation failed"
exit 1
