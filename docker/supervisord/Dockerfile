FROM debian:13.6

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y --no-install-recommends\
    curl wget vim \
    build-essential cmake libvulkan-dev glslc spirv-headers libssl-dev git \
    mesa-utils mesa-vulkan-drivers \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

ADD --chmod=755 entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]