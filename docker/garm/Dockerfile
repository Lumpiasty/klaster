FROM golang:1.26-alpine AS build

ARG GARM_COMMIT
ARG GARM_PROVIDER_K8S_VERSION=0.3.2

RUN apk add --no-cache ca-certificates git wget tar build-base util-linux-dev linux-headers

WORKDIR /src
RUN git clone https://github.com/cloudbase/garm.git . && git checkout "${GARM_COMMIT}"

RUN CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
  go build -trimpath \
  -tags osusergo,netgo,sqlite_omit_load_extension \
  -ldflags="-linkmode external -extldflags '-static' -s -w" \
  -o /out/garm ./cmd/garm

RUN mkdir -p /out/providers.d \
  && wget -qO /tmp/garm-provider-k8s.tar.gz "https://github.com/mercedes-benz/garm-provider-k8s/releases/download/v${GARM_PROVIDER_K8S_VERSION}/garm-provider-k8s_Linux_x86_64.tar.gz" \
  && tar -xzf /tmp/garm-provider-k8s.tar.gz -C /out/providers.d \
  && chmod 0755 /out/providers.d/garm-provider-k8s

FROM busybox

COPY --from=build /out/garm /bin/garm
COPY --from=build /out/providers.d/garm-provider-k8s /opt/garm/providers.d/garm-provider-k8s
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

ENTRYPOINT ["/bin/garm"]
