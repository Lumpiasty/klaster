# garm

This app deploys `garm` with external `garm-provider-k8s`.

- API/UI ingress: `https://garm.lumpiasty.xyz`
- Internal service DNS: `http://garm.garm.svc.cluster.local:9997`

## Vault secret requirements

`VaultStaticSecret` reads `secret/data/garm` and expects at least:

- `jwt_auth_secret`
- `database_passphrase` (must be 32 characters)

## Connect garm to Gitea

After Flux reconciles this app, initialize garm and add Gitea endpoint/credentials.

```bash
# 1) Initialize garm (from your local devenv shell)
garm-cli init \
  --name homelab \
  --url https://garm.lumpiasty.xyz \
  --username admin \
  --email admin@lumpiasty.xyz \
  --password '<STRONG_ADMIN_PASSWORD>' \
  --metadata-url http://garm.garm.svc.cluster.local:9997/api/v1/metadata \
  --callback-url http://garm.garm.svc.cluster.local:9997/api/v1/callbacks \
  --webhook-url http://garm.garm.svc.cluster.local:9997/webhooks

# 2) Add Gitea endpoint
garm-cli gitea endpoint create \
  --name local-gitea \
  --description 'Cluster Gitea' \
  --base-url http://gitea-http.gitea.svc.cluster.local:80 \
  --api-base-url http://gitea-http.gitea.svc.cluster.local:80/api/v1

# 3) Add Gitea PAT credentials
garm-cli gitea credentials add \
  --name gitea-pat \
  --description 'PAT for garm' \
  --endpoint local-gitea \
  --auth-type pat \
  --pat-oauth-token '<GITEA_PAT_WITH_write:repository,write:organization>'
```

Then add repositories/orgs and create pools against provider `kubernetes_external`.

If Gitea refuses webhook installation to cluster-local URLs, set `gitea.config.webhook.ALLOWED_HOST_LIST` in `apps/gitea/release.yaml`.
