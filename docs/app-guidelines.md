# App deployment guidelines

This document summarizes current guidelines, requirements, common patterns, and standards that newly deployed apps should meet.

## Structure

Each app on cluster should be contained in its own kustomization living in subdirectory under [apps](/apps) and imported from main [apps kustomization](/apps/kustomization.yaml). Apps that provide infrastructural services belong to [infra](/infra). Few examples:

- **Open WebUI**: Web app, belongs in [apps/openwebui](/apps/openwebui/) together with its direct and unique dependencies eg. database
- **llama-swap** (llama.cpp + whisper + stablediffusion): Inference server, service used by other deployments on cluster but does not manages cluster, belongs in [apps/llama](/apps/llama/)
- **kokoro**: Text to speech inference server, also service used by other deployments, I consider it closely related to llama-swap, so due to arbitrary decision, keeping it together with llama-swap under [apps/llama](/apps/llama/)
- **crawl4ai**: Web scraper, another service used only by other apps, belongs in [apps/crawl4ai](/apps/crawl4ai/)
- **Gitea**: Code forge, despite being essential for overall architecture (holding cluster's code) is not a core cluster software, belongs in [apps/gitea](/apps/gitea/)
- **Woodpecker**: Continous Integration system, belongs in [apps/woodpecker](/apps/woodpecker/)
- **Cilium**: Kubernetes CNI, core cluster functionality, belongs in [infra/controllers/cilium.yaml](/infra/controllers/cilium.yaml)
- **Nginx Ingress Controller**: Provides ingress kubernetes functionality, belongs in [infra/controllers/nginx-ingress.yaml](/infra/controllers/nginx-ingress.yaml)
- **CloudNativePG**: Kubernetes PostgreSQL operator, belongs in [infra/controllers/cloudnative-pg.yaml](/infra/controllers/cloudnative-pg.yaml)
- **OpenBao** Secret storage and Kubernetes operator, belongs in [infra/controllers/openbao.yaml](/infra/controllers/openbao.yaml)

Kustomizations are reconciled on `git push` by flux running on cluster, triggered by [Woodpecker job](/.woodpecker/flux-reconcile-source.yaml). App Kustomization should import all resources related to app in `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - release.yaml
```

## Namespace

Each app kustomization should have its own kubernetes namespace to contain all resources related to app in `namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: immich
```

## Helm charts

If app is distributed via Helm chart, you can deploy it using flux HelmRepository and HelmRelease resources like in following example:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: secustor
  namespace: immich
spec:
  interval: 24h
  url: https://secustor.dev/helm-charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: immich
  namespace: immich
spec:
  interval: 30m
  chart:
    spec:
      chart: immich
      version: 1.2.6
      sourceRef:
        kind: HelmRepository
        name: secustor
  values:
    <values>
```

If the app does not have a helm repository, but helm chart is available in git repository directly in repository, you can make use of it using GitRepository flux source:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kaneo
  namespace: kaneo
spec:
  interval: 24h
  url: https://github.com/usekaneo/kaneo.git
  ref:
    tag: v2.7.5
  ignore: |
    # exclude all
    /*
    # include charts directory
    !/charts/
```

You can use third-party helm charts to deploy applications, consider this possibility if:

- There is no official helm chart for the application
- The official helm chart is unmaintained
- The official helm chart is using glaring bad practices
- The official helm chart is missing configuration options for what we need

When deciding which helm chart to use, watch out for following things in particular:

- Development activity, stability, maturity
- Whether the app deployed by chart is up to date - automated updates are large bonus
- Unresolved / breaking issues
- Configurability, can we configure things we need, disable undesired features

When configuring Helm chart, keep in mind:
- Do not use bundled PVCs, bring our own one or at least configure chart to bind it to manually created `PersistentVolume` according to [Data / PVCs pattern](#data--pvcs-pattern)
- Do not use bundled Postgres database unless the chart is using CloudNativePG's Cluster resource, bring our own one using [Postgres operator](#postgres-operator)
- do not

## Bare Kubernetes deployments

If:

- the app is not packaged as a helm chart or
- it would be simpler to deploy it without package (for example custom privileged pod with access to gpu) or
- the app is so simple it doesn't make sense to make helm package it (for example, simple http proxy that alters headers or stateless single-binary app) or
- for any other reason it would make more sense to skip helm

You can deploy app skipping helm chart and just create raw Kubernetes manifests like Deployment, StatefulSet and other supporting resources like ConfigMap, Service, Ingress directly.

## Data / PVCs pattern

Data are stored on local disk of node using OpenEBS LVM LocalPV. To create a persistent volume, use following example:

```yaml
---
apiVersion: local.openebs.io/v1alpha1
kind: LVMVolume
metadata:
  labels:
    kubernetes.io/nodename: anapistula-delrosalae
  name: immich-library-lvmhdd
  namespace: openebs
spec:
  capacity: 150Gi
  ownerNodeID: anapistula-delrosalae
  shared: "yes"
  thinProvision: "no"
  vgPattern: ^openebs-hdd$
  volGroup: openebs-hdd
---
kind: PersistentVolume
apiVersion: v1
metadata:
  name: immich-library-lvmhdd
spec:
  capacity:
    storage: 150Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: hdd-lvmpv
  volumeMode: Filesystem
  csi:
    driver: local.csi.openebs.io
    fsType: btrfs
    volumeHandle: immich-library-lvmhdd
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: library-lvmhdd
  namespace: immich
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 150Gi
  storageClassName: hdd-lvmpv
  volumeName: immich-library-lvmhdd
```

Create LVMVolume and PersistentVolume resources manually and **do not** rely on automatic scheduling of PVCs because we want created LVM LVs on disk to have deterministic names and be reused if already exist on disk, which scheduler does not give us. There are two LVM storage classes:

- **hdd-lvmpv**, volume group: openebs-hdd, use for bulk data, like media library
- **ssd-lvmpv**, volume group: openebs-ssd, use for small datasets that benefit from quick storage access like databases, state data etc.

When deciding the size of the volume, make minimal prediction, starting with 1GiB if you do not predict app to use much disk space.

## Vault secrets

There is OpenBao installed on cluster that manages access to secrets. The KV2 secret engine is mounted at `secret`, use it to store static secrets like API keys to external services, passwords and other entries you do not want to keep in plaintext in git repository.

To access the KV secrets on cluster, use Vault Secrets Operator installed on cluster, which provides `VaultStaticSecret` custom resource that syncs a path from OpenBao to Kubernetes `Secret` object.

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: llama-proxy
  namespace: llama
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: llama
  namespace: llama
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: llama-proxy
    serviceAccount: llama-proxy
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: llama-api-key
  namespace: llama
spec:
  type: kv-v2

  mount: secret
  path: ollama

  destination:
    create: true
    name: llama-api-key
    type: Opaque
    transformation:
      excludeRaw: true

  vaultAuthRef: llama
```

To give access to specified secret for given k8s ServiceAccount, you need to create kubernetes auth role and policy. Create a kubernetes auth role named `llama-proxy`, by creating file `vault/kubernetes-auth-roles/llama-proxy.yaml`:

```yaml
bound_service_account_names:
  - llama-proxy
bound_service_account_namespaces:
  - llama
token_policies:
  - ollama
```

Create policy named `ollama` by creating file `vault/policy/ollama.hcl`:

```hcl
path "secret/data/ollama" {
    capabilities = ["read"]
}
```

Once these files are created, ask operator to reconcile OpenBao configuration and create required secret.

## Postgres operator

There is CloudNativePG operator installed on cluster that manages databases of applications running on cluster. You can create Postgres database by creating `Cluster` resource:

```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: kaneo-db
  namespace: kaneo
spec:
  instances: 1

  storage:
    pvcTemplate:
      storageClassName: ssd-lvmpv
      resources:
        requests:
          storage: 10Gi
      volumeName: kaneo-db-1

```

Create a `PersistentVolume` and `LVMVol` resources manually but **do not** create `PersistentVolumeClaim`, CloudNativePG will create one on its own referencing `PersistentVolume` specified in `volumeName`. Do not replicate the database, there is only one node in the cluster currently. The `Cluster` resource will automatically create secret, use it to configure app:

```
Name:         kaneo-db-app
Namespace:    kaneo
Labels:       app.kubernetes.io/managed-by=cloudnative-pg
              cnpg.io/cluster=kaneo-db
              cnpg.io/reload=true
              cnpg.io/userType=app
Annotations:  cnpg.io/operatorVersion: 1.29.1

Type:  kubernetes.io/basic-auth

Data
====
dbname:         3 bytes
fqdn-jdbc-uri:  145 bytes
fqdn-uri:       126 bytes
host:           11 bytes
jdbc-uri:       127 bytes
password:       64 bytes
pgpass:         90 bytes
port:           4 bytes
uri:            108 bytes
user:           3 bytes
username:       3 bytes
```

## LoadBalancers

You can expose installed app to the Internet using Cilium's LoadBalancer configured on cluster:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: teamspeak3
  namespace: ispeak3
spec:
  selector:
    app: teamspeak3
  ports:
  - name: voice
    protocol: UDP
    port: 9987
    targetPort: 9987
  - name: filetransfer
    protocol: TCP
    port: 30033
    targetPort: 30033
  type: LoadBalancer
  externalTrafficPolicy: Local
  ipFamilyPolicy: PreferDualStack
```

IPv6 will be directly reachable from the internet by its assigned address, for IPv4 currently you need to configure port forward on router in `ansible/roles/routeros/firewall.yml`, that step is not yet automated. The assigned internal IP will be known after manifests are applied on cluster. For this reason, there is no ExternalDNS configured yet, if you need a DNS name, ask the operator to configure DNS name for LoadBalancer. Assign names from lumpiasty.xyz subdomains (eg. kaneo.lumpiasty.xyz) unless explicitly requested. Do not use LoadBalancer for exposing HTTP applications, use Ingress instead.

## Ingress

You can expose HTTP applications using NGINX Ingress Controller:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: llama
  name: llama
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    acme.cert-manager.io/http01-edit-in-place: "true"
    nginx.ingress.kubernetes.io/proxy-buffering: "false"
    nginx.ingress.kubernetes.io/proxy-read-timeout: 30m
    nginx.ingress.kubernetes.io/proxy-body-size: 8m
spec:
  ingressClassName: nginx-ingress
  rules:
    - host: llama.lumpiasty.xyz
      http:
        paths:
          - backend:
              service:
                name: llama-proxy
                port:
                  number: 80
            path: /
            pathType: Prefix
  tls:
    - hosts:
        - llama.lumpiasty.xyz
      secretName: llama-ingress
```

TLS certificates are automatically issued for subdomains of lumpiasty.xyz using cert-manager. DNS name assignment is not automatic yet, ask operator to create DNS name for ingress resources.

## Keeping app up to date

There is a Renovate job configured for this repository as [Woodpecker job](/.woodpecker/renovate.yaml) to keep applications up to date. Renovate automatically keeps track of:

- Docker images specified in Kubernetes manifests like Deployment, StatefulSet etc
- HelmRelease versions
- GitRepository tags

To make Renovate automatically update applications, always specify full versions of docker images or helm chart release. If you use ambigous tags, renovate will not have chance to update and the cluster will never download new image because this tag already existed on node. **Do not** use:

- latest (or its variants like stable, current, main, master current)
- "Sliding" versions, like 1 or 1.2 that point at 1.2.1 currently and will change image it points at when version 1.2.2 is released

As a last resort if the application does not publish stable image tags, pin digest of image.

Renovate may require custom configuration if:

- App is using non-standard versioning schema

  Example app versioned by date (unified-vulkan-2026-01-01), renovate.json:
  
  ```json
    {
        "matchDatasources": ["docker"],
        "matchPackageNames": ["ghcr.io/mostlygeek/llama-swap"],
        "versioning": "regex:^unified-vulkan-(?<major>\\d{4})-(?<minor>\\d{2})-(?<patch>\\d{2})$",
        "automerge": true,
        "automergeType": "pr",
        "platformAutomerge": true
    }
  ```

- Docker image tag is specified in non-standard field that Renovate may not recognise automatically such as Helm values
  
  Example app with non-standard image selected in helm values instead of image's default (which is latest in this chart):
  ```yaml
    values:
      kaneo:
        image:
          tag: "2.7.3"  # renovate: depName=ghcr.io/usekaneo/kaneo registryUrl=https://ghcr.io
  ```

Renovate is configured so it automatically merges patch versions, other updates are created as pull requests to be manually reviewed and merged unless explicitly desired on per case basis.

## SSO / OIDC / Authentik

There is an Authentik running on cluster providing SSO for applications. Configure user-facing apps to utilize it correctly.

Authentik supports following protocols:

- OAuth2 / OpenID Connect
- SAML
- Radius
- LDAP
- SCIM

Currently, there is no Authentik configuration in code, ask operator to create application in the UI and save OAuth id and secret in OpenBao under `secret/authentik/<app>`. Authentik provides discovery URL for OAuth applications: `https://authentik.lumpiasty.xyz/application/o/<app slug>/.well-known/openid-configuration`.

Configure the app to disable guest access, built-in registration and automatically register unprivileged users with `user` role and privileged users with `admin` role as the app allows.

## Privileged apps

Some apps require direct access to devices, like GPU. There are no specific operators yet, apps that require access to GPU are simply launched as privileged pods, example:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-swap
  namespace: llama
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: llama-swap
  template:
    metadata:
      labels:
        app: llama-swap
    spec:
      containers:
        - name: llama-swap
          volumeMounts:
            - mountPath: /dev/kfd
              name: kfd
            - mountPath: /dev/dri
              name: dri
          securityContext:
            privileged: true
      volumes:
        - name: kfd
          hostPath:
            path: /dev/kfd
            type: CharDevice
        - name: dri
          hostPath:
            path: /dev/dri
            type: Directory
```

Creating of such pods is forbidden unless explicitly allowed in Talos config:

```yaml
# CSI driver requirement
cluster:
  apiServer:
    admissionControl:
      - name: PodSecurity
        configuration:
          apiVersion: pod-security.admission.config.k8s.io/v1beta1
          kind: PodSecurityConfiguration
          exemptions:
            namespaces:
              - llama
```

Create the patch like this under `talos/patches/<app>.patch`, add it to `gen-talos-config` target in Makefile and ask operator to apply reconcile Talos config to allow privileged pods in specified namespace.
