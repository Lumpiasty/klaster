# Mikrotik containers

RouterOS containers running on the CRS418 providing network services that
RouterOS cannot handle natively.

## CoreDNS

Replaces the built-in RouterOS DNS forwarder. Plain forwarding resolver with
selective AAAA suppression: AAAA is suppressed by default so clients prefer IPv4
(avoiding the HE tunnel's datacenter-flagged egress), while our own zone and any
whitelisted domains keep AAAA for native IPv6.

Source: [`coredns/`](coredns/). Image built by Woodpecker CI
([`.woodpecker/coredns-build.yaml`](../.woodpecker/coredns-build.yaml)), pushed to
`gitea.lumpiasty.xyz/lumpiasty/coredns-mikrotik`.

The Corefile is baked into the image — edit [`coredns/Corefile`](coredns/Corefile)
and push; the pipeline rebuilds and pushes a new image. Custom-built with a
minimal plugin set (~6-8 MB vs the official ~20 MB image) to fit the CRS flash.

See [docs/coredns.md](../docs/coredns.md) for design rationale, including why
the earlier NAT64/DNS64 approach was removed.

### Why not the official coredns/coredns image?

The official image ships ~40 plugins and weighs ~20 MB compressed. A custom build with the 7 plugins we actually need fits in ~6-8 MB — important for the CRS internal flash.

## Deployment

The router configuration (container definitions, veth interfaces, bridge ports,
DNS settings, firewall) is managed declaratively via Ansible, not by manual CLI
commands. See [`ansible/roles/routeros/`](../ansible/roles/routeros/) and run:

```sh
cd ansible && ansible-playbook playbooks/routeros.yml
```

Containers do not auto-start on first image pull; after the initial deploy,
start manually once (subsequent boots are handled by `start-on-boot=yes`):

```
/container/start [find name=coredns]
```
