# Stage 1: build CoreDNS with minimal plugin set
FROM golang:1.25-alpine AS build

RUN apk add --no-cache git make bash

WORKDIR /src
RUN git clone --depth 1 --branch v1.12.1 \
    https://github.com/coredns/coredns .

# Overwrite plugin.cfg with our trimmed list before compilation
COPY plugin.cfg .

RUN go generate && make

# Stage 2: extract CA certificates from a full image
FROM debian:stable-slim AS certs
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates && rm -rf /var/lib/apt/lists/*

# Stage 3: minimal runtime — scratch + binary + certs only
FROM scratch

COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /src/coredns /coredns
COPY Corefile /Corefile

# 53:  DNS (UDP + TCP)
# 8080: health endpoint
EXPOSE 53/udp 53/tcp 8080/tcp

# RouterOS requires root to bind port 53 — no USER directive
ENTRYPOINT ["/coredns", "-conf", "/Corefile"]
