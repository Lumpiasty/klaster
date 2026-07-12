FROM debian:13.5

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y --no-install-recommends\
    supervisor \
    && rm -rf /var/lib/apt/lists/*

ADD --chmod=755 entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]