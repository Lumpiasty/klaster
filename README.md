# Homelab

## Goals

Wanting to set up homelab kubernetes cluster.

### Software

1. Running applications
   1. NAS, backups, security recorder
   2. Online presence, website, email, communicators (ts3, matrix?)
   3. Git server, container registry
   4. Environment to deploy my own apps
   5. Some LLM server, apps for my own use
   6. Public services like Tor, mirrors of linux distros etc.
   7. [Some frontends](https://libredirect.github.io/)
   8. [Awesome-Selfhosted](https://github.com/awesome-selfhosted/awesome-selfhosted), [Awesome Sysadmin](https://github.com/awesome-foss/awesome-sysadmin)
2. Managing them hopefully using GitOps
   1. FluxCD, Argo etc.
   2. State of cluster in git, all apps version pinned
   3. Some bot to inform about updates?
3. It's a home**lab**
   1. Should be open to experimenting
   2. Avoiding vendor lock-in, changing my mind shouldn't block me for too long
   3. Backups of important data in easy to access format
   4. Expecting downtime, no critical workloads
   5. Trying to keep it reasonably up anyways

### Infrastructure

1. Using commodity hardware
2. Reasonably scalable
3. Preferably mobile workloads, software should be a bit more flexible than me moving disks and data
4. Replication is overkill for most data
5. Preferably dynamically configured network
   1. BGP with OpenWRT router
   2. Dynamically allocated host subnets
   3. Load-balancing (MetalLB?), ECMP on router
   4. Static IP configurations on nodes
6. IPv6 native, IPv4 accessible
   1. IPv6 has whole block routed to us which gives us control over address routing and usage
   2. Which allows us to expose services directly to the internet without complex router config
   3. Which allows us to use eg. ExternalDNS to autoconfigure domain names for LB
   4. But majority of the world still runs IPv4, which should be supported for public services
   5. Exposing IPv4 service may require additional reconfiguration of router, port forwarding, manual domain setting or controller doing this some day in future
   6. One public IPv4 address means probably extensive use of rule-based ingress controllers
   7. IPv6 internet from pods should not be NATed
   8. IPv4 internet from pods should be NATed by router

### Current implementation idea

1. Cluster server nodes running Talos
2. OpenWRT router
   1. VLAN / virtual interface, for cluster
   2. Configuring using Ansible
   3. Peering with cluster using BGP
   4. Load-balancing using ECMP
3. Cluster networking
   1. Cilium CNI
   2. Native routing, no encapsulation or overlay
   3. Using Cilium's network policies for firewall needs
   4. IPv6 address pool
      1. Nodes: 2001:470:61a3:100::/64
      2. Pods: 2001:470:61a3:200::/64
      3. Services: 2001:470:61a3:300::/112
      4. Load balancer: 2001:470:61a3:400::/112
   5. IPv4 address pool
      1. Nodes: 192.168.1.32/27
      2. Pods: 10.42.0.0/16
      3. Services: 10.43.0.0/16
      4. Load balancer: 10.44.0.0/16
4. Storage
   1. OS is installed on dedicated disk
   2. Mayastor managing all data disks
      1. DiskPool for each data disk in cluster, labelled by type SSD or HDD
      2. Creating StorageClass for each topology need (type, whether to replicate, on which node etc.)

## Working with repo

Repo is preconfigured to use with nix and vscode

Install nix, vscode should pick up settings and launch terminals in `nix develop` with all needed utils.

## Bootstrapping cluster

1. Configure OpenWRT, create dedicated interface for connecting server
   1. Set up node subnet, routing
   2. Create static host entry `kube-api.homelab.lumpiasty.xyz` pointing at ipv6 of first node
2. Connect server
3. Grab Talos ISO, dd it to usb stick
4. Boot it and using keyboard set up static ip ipv6 subnet, should become reachable from pc
5. `talosctl gen config homelab https://kube-api.homelab.lumpiasty.xyz:6443`
6. Generate secrets `talosctl gen secrets`, **backup, keep `secrets.yml` safe**
7. Generate config files `make gen-talos-config`
8. Apply config to first node `talosctl apply-config --insecure -n 2001:470:61a3:100::2 -f controlplane.yml`
9. Wait for reboot then `talosctl bootstrap --talosconfig=talosconfig -n 2001:470:61a3:100::2`
10. Set up router and CNI

## Updating Talos config

Update patches and re-generate and apply configs.

```
make gen-talos-config
make apply-talos-config
```
