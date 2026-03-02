# Homelab

This repo contains configuration and documentation for my homelab setup, which is based on Talos OS for Kubernetes cluster and MikroTik router.

## Architecture

Physical setup consists of MikroTik router which connects to the internet and serves as a gateway for the cluster and other devices in the home network as shown in the diagram below.

```mermaid
%%{init: {"flowchart": {"ranker": "tight-tree"}}}%%
flowchart TD

   subgraph internet[Internet]
      ipv4[IPv4 Internet]
      ipv6[IPv6 Internet]
      he_tunnel[Hurricane Electric IPv6 Tunnel Broker]
      isp[ISP]
   end

   subgraph home[Home network]
      router[MikroTik Router]
      cluster[Talos cluster]
      lan[LAN]
      mgmt[Management network]
      cam[Camera system]
      router --> lan
      router --> cluster
      router --> mgmt
      router --> cam
   end

   ipv4 -- "Public IPv4 address" --> isp
   ipv6 -- "Routed /48 IPv6 prefix" --> he_tunnel -- "6in4 Tunnel" --> isp
   isp --> router
```

Devices are separated into VLANs and subnets for isolation and firewalling between devices and services. Whole internal network is configured to eliminate NAT where unnecessary. Pods on the Kubernetes cluster communicate with the router using native IP routing, there is no encapsulation, overlay network nor NAT on the nodes. Router knows where to direct packets destined for the pods because the cluster announces its IP prefixes to the router using BGP. Router also performs NAT for IPv4 traffic from the cluster to and from the internet, while IPv6 traffic is routed directly to the internet without NAT. High level logical routing diagram is shown below.

```mermaid
flowchart TD
   isp[ISP] --- gpon

   subgraph device[MikroTik CRS418-8P-8G-2s+]
      direction TB
      gpon[SFP GPON ONU]
      pppoe[PPPoE client]

      he_tunnel[HE Tunnel]

      router[Router]@{ shape: cyl }

      dockers["""
         Dockers Containers (bridge)
         2001:470:61a3:500::/64
         172.17.0.0/16
      """]@{ shape: cloud }
      tailscale["Tailscale Container"]

      lan["""
         LAN (vlan2)
         2001:470:61a3::/64
         192.168.0.0/24
      """]@{ shape: cloud }

      mgmt["""
         Management network (vlan1)
         192.168.255.0/24
      """]@{ shape: cloud }

      cam["""
         Camera system (vlan3)
         192.168.3.0/24
      """]@{ shape: cloud }

      cluster["""
         Kubernetes cluster (vlan4)
         2001:470:61a3:100::/64
         192.168.1.0/24
      """]@{ shape: cloud }

      gpon --- pppoe -- """
         139.28.40.212
         Default IPv4 gateway
      """ --- router

      pppoe --- he_tunnel -- """
         2001:470:61a3:: incoming
         Default IPv6 gateway
      """ --- router

      router -- """
         2001:470:61a3:500:ffff:ffff:ffff:ffff
         172.17.0.1/16
      """ --- dockers --- tailscale

      router -- """
         2001:470:61a3:0:ffff:ffff:ffff:ffff
         192.168.0.1
      """--- lan

      router -- """
         192.168.255.10
      """--- mgmt

      router -- "192.168.3.1" --- cam
      router -- """
         2001:470:61a3:100::1
         192.168.1.1
      """ --- cluster

   end

   subgraph k8s[K8s cluster]
      direction TB
      pod_network["""
         Pod networks
         2001:470:61a3:200::/104
         10.42.0.0/16
         (Dynamically allocated /120 IPv6 and /24 IPv4 prefixes per node)
      """]@{ shape: cloud }

      service_network["""
         Service network
         2001:470:61a3:300::/112
         10.43.0.0/16
         (Advertises vIP addresses via BGP from nodes hosting endpoints)
      """]@{ shape: cloud }

      load_balancer["""
         Load balancer network
         2001:470:61a3:400::/112
         10.44.0.0/16
         (Advertises vIP addresses via BGP from nodes hosting endpoints)
      """]@{ shape: cloud }
   end

   cluster -- "Routes exported via BGP" ----- k8s
```

Currently the k8s cluster consists of single node (hostname anapistula-delrosalae), which is a PC with Ryzen 5 3600, 64GB RAM, RX 580 8GB (for accelerating LLMs), 1TB NVMe SSD, 2TB and 3TB HDDs and serves both as control plane and worker node.

## Software stack

The cluster itself is based on [Talos Linux](https://www.talos.dev/) (which is also a Kubernetes distribution) and uses [Cilium](https://cilium.io/) as CNI, IPAM, kube-proxy replacement, Load Balancer, and BGP control plane. Persistent volumes are managed by [OpenEBS LVM LocalPV](https://openebs.io/docs/user-guides/local-storage-user-guide/local-pv-lvm/lvm-overview). Applications are deployed using GitOps (this repo) and reconciled on cluster using [Flux](https://fluxcd.io/). Git repository is hosted on [Gitea](https://gitea.io/) running on a cluster itself. Secets are kept in [OpenBao](https://openbao.org/) (HashiCorp Vault fork) running on a cluster and synced to cluster objects using [Vault Secrets Operator](https://github.com/hashicorp/vault-secrets-operator). Deployments are kept up to date using self hosted [Renovate](https://www.mend.io/renovate/) bot updating manifests in the Git repository. Incoming HTTP traffic is routed to cluster using [Nginx Ingress Controller](https://kubernetes.github.io/ingress-nginx/) and certificates are issued by [cert-manager](https://cert-manager.io/) with [Let's Encrypt](https://letsencrypt.org/) ACME issuer with [cert-manager-webhook-ovh](https://github.com/aureq/cert-manager-webhook-ovh) resolving DNS-01 challanges. Cluster also runs [CloudNativePG](https://cloudnative-pg.io/) operator for managing PostgreSQL databases. High level core cluster software architecture is shown on the diagram below.

```mermaid
flowchart TD
      router[MikroTik Router]
      router -- "Routes HTTP traffic" --> nginx
      cilium -- "Announces routes via BGP" --> router
   subgraph cluster[K8s cluster]
      direction TB
      flux[Flux CD] -- "Reconciles manifests" --> kubeapi[Kube API Server]
      flux -- "Fetches Git repo" --> gitea[Gitea]

      
      kubeapi -- "Configs, Services, Pods" --> cilium[Cilium]
      cilium -- "Routing" --> services[Services] -- "Endpoints" --> pods[Pods]
      cilium -- "Configures routing, interfaces, IPAM" --> pods[Pods]


      kubeapi -- "Ingress rules" --> nginx[NGINX Ingress Controller] -- "Routes HTTP traffic" ---> pods

      kubeapi -- "Certificate requests" --> cert_manager[cert-manager] -- "Provides certificates" --> nginx
      cert_manager -- "ACME DNS-01 challanges" --> dns_webhook[cert-manager-webhook-ovh] -- "Resolves DNS challanges" --> ovh[OVH DNS]
      cert_manager -- "Requests DNS-01 challanges" --> acme[Let's Encrypt ACME server] -- "Verifies domain ownership" --> ovh

      kubeapi -- "Assigns pods" --> kubelet[Kubelet] -- "Manages" --> pods

      kubeapi -- "PVs, LvmVols" --> openebs[OpenEBS LVM LocalPV]
      openebs -- "Mounts volumes" --> pods
      openebs -- "Manages" --> lv[LVM LVs]

      kubeapi -- "Gets Secret refs" --> vault_operator[Vault Secrets Operator] -- "Syncs secrets" --> kubeapi
      vault_operator -- "Retrieves secrets" --> vault[OpenBao] -- "Secret storage" --> lv
      vault -- "Auth method" --> kubeapi

      gitea -- "Stores repositories" --> lv

      gitea --> renovate[Renovate Bot] -- "Updates manifests" --> gitea


   end
```

<!-- TODO: Backups, monitoring, logging, deployment with ansible etc -->

## Applications / Services

| Logo | Name | Address | Description |
|------|------|---------|-------------|
| <img src="docs/assets/gitea.svg" alt="Gitea" height="50" width="50"> | Gitea | https://gitea.lumpiasty.xyz/ | Private Git repository hosting and artifact storage (Docker, Helm charts) |
| <img src="docs/assets/openbao.svg" alt="OpenBao" height="50" width="50"> | OpenBao | https://openbao.lumpiasty.xyz:8200/ | Secret storage (HashiCorp Vault compatible) |
| <img src="docs/assets/renovate.svg" alt="Renovate" height="50" width="50"> | Renovate | | Bot for keeping dependencies up to date |
| <img src="docs/assets/cert-manager.svg" alt="cert-manager" height="50" width="50"> | cert-manager | | Automatic TLS certificate management |
| <img src="docs/assets/nginx.svg" alt="Nginx" height="50" width="50"> | Nginx Ingress Controller | | Ingress controller for routing external traffic to services in the cluster |
| <img src="docs/assets/cloudnativepg.svg" alt="CloudNativePG" height="50" width="50"> | CloudNativePG | | PostgreSQL operator for managing PostgreSQL instances |
| <img src="docs/assets/immich.svg" alt="Immich" height="50" width="50"> | Immich | https://immich.lumpiasty.xyz/ | Self-hosted photo and video backup and streaming service |
| <img src="docs/assets/teamspeak.svg" alt="iSpeak3" height="50" width="50"> | iSpeak3.pl | [ts3server://ispeak3.pl](ts3server://ispeak3.pl) | Public TeamSpeak 3 voice communication server |
| <img src="docs/assets/llama-cpp.svg" alt="LLaMA.cpp" height="50" width="50"> | LLaMA.cpp | https://llama.lumpiasty.xyz/ | LLM inference server running local models with GPU acceleration |
| <img src="docs/assets/open-webui.png" alt="Open WebUI" height="50" width="50"> | Open WebUI | https://openwebui.lumpiasty.xyz/ | Web UI for chatting with LLMs running on the cluster |
| <img src="docs/assets/frigate.svg" alt="Frigate" height="50" width="50"> | Frigate | https://frigate.lumpiasty.xyz/ | NVR for camera system with AI object detection and classification |

