FROM debian:13.7

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y --no-install-recommends\
    curl wget vim \
    ca-certificates \
    build-essential cmake libvulkan-dev glslc spirv-headers libssl-dev git \
    mesa-utils mesa-vulkan-drivers \
    supervisor \
    systemd systemd-sysv dbus \
    && rm -rf /var/lib/apt/lists/*

ADD --chmod=755 entrypoint.sh boot.sh /

# boot.sh seeds/enters the persistent rootfs PVC, then boots systemd in it
# (which runs /entrypoint.sh -> supervisord as a unit)
ENTRYPOINT ["/boot.sh"]
# systemd as PID 1 re-executes itself on SIGTERM; this is its "halt" signal
STOPSIGNAL SIGRTMIN+3
