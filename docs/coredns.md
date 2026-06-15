# CoreDNS resolver

## Goal

Replace the RouterOS built-in DNS forwarder with a CoreDNS container for
configurability, and suppress IPv6 (AAAA) resolution by default to keep traffic
on IPv4.

## Background

The ISP provides no native IPv6 — only a Hurricane Electric (HE) tunnel
(`2001:470:61a3::/48`). HE addresses fall in ranges some sites flag as
datacenter/bot traffic, producing endless CAPTCHAs. The goal is to prefer IPv4
egress while keeping IPv6 available for our own services and any domain
explicitly trusted over IPv6.

## What this is NOT (and why)

An earlier iteration used **DNS64 + NAT64 (Tayga)** to force traffic through
IPv4. It was removed:

- **Performance**: Tayga is a userspace translator with no hardware offload.
  Every translated packet crossed RouterOS twice (v6 in, v4 out) plus a
  userspace hop, capping throughput at ~250 Mbps against a 1 Gbps line.
- **SPOF**: two containers (CoreDNS + Tayga) in the datapath of nearly all
  traffic on a router whose native forwarder had been rock-solid.
- **Architectural inversion**: NAT64 exists to let IPv6-only clients reach IPv4.
  We don't want IPv6 egress at all — using NAT64 to avoid IPv6 was solving the
  problem backwards.

Plain AAAA suppression in CoreDNS achieves the same IPv4-preferred outcome with
zero datapath overhead — DNS is the only thing touched, packet forwarding stays
on the RouterOS fastpath at line rate.

The full account of the NAT64/IPv6-mostly attempt and why it was abandoned is in
[nat64-dns64-postmortem.md](./nat64-dns64-postmortem.md).

## How it works

CoreDNS runs as a single container (`172.20.0.3`), reachable from RouterOS DNS
which forwards client queries to it. The [Corefile](../mikrotik/coredns/Corefile)
has three server blocks:

1. **`lumpiasty.xyz`** — our own zone. Forwards normally, keeps AAAA, so internal
   services reachable over the HE prefix resolve to their real IPv6 addresses.
2. **`.` (default)** — forwards everything else, but a `template IN AAAA` block
   returns empty NOERROR for all AAAA queries, so clients fall back to IPv4 and
   avoid the HE tunnel's flagged egress. A records and all other types pass
   through untouched.

The whitelist is implemented as a reusable `(aaaa_allowed)` snippet imported by
zones that should keep AAAA. To trust another domain over IPv6, add a server
block for it that imports `aaaa_allowed`.

### Why suppression, not NXDOMAIN

The AAAA template returns NOERROR with an empty answer (NODATA), not NXDOMAIN.
This is correct: the name exists, it just has no (advertised) AAAA. Clients
treat it as "no IPv6 address" and use the A record. Returning NXDOMAIN would
wrongly imply the name doesn't exist and break the A lookup.

## Future improvement

The current global-suppress-plus-whitelist is coarse: a domain that is genuinely
IPv6-only (no A record) and not whitelisted becomes unreachable. The intended
end state is a plugin that suppresses AAAA only when the domain also has an A
record, so IPv6-only destinations keep working without manual whitelisting. No
in-tree CoreDNS plugin does this today.

## Custom image

Built from source with a minimal plugin set (`errors`, `log`, `health`,
`template`, `cache`, `forward`, `reload`) instead of the default ~40, producing
a ~6-8 MB image. The `dns64` plugin is no longer compiled in.

Source: [`mikrotik/coredns/`](../mikrotik/coredns/). Built by Woodpecker
([`.woodpecker/coredns-build.yaml`](../.woodpecker/coredns-build.yaml)) on pushes
touching `mikrotik/coredns/**`, pushed to `gitea.lumpiasty.xyz/lumpiasty/coredns-mikrotik`.

## RouterOS integration

- `/ip/dns servers=172.20.0.3` — RouterOS forwards client queries to CoreDNS
- RDNSS in RA (`/ipv6/nd dns=...` on vlan2/vlan5) advertises an IPv6 resolver
  (the router's per-VLAN address) to dual-stack clients; RouterOS DNS relays to
  CoreDNS
- No DHCP option 108, no PREF64 — those belonged to the removed IPv6-mostly setup

## Pitfalls learned (kept for reference)

These were hit during the NAT64 era and the migration; some still apply:

1. **RouterOS static FWD entries corrupt NXDOMAIN.** A `type=FWD match-subdomain=yes`
   entry returns NOERROR/empty instead of relaying NXDOMAIN. Combined with
   `ndots:5` and kubernetes pod search domains, `getaddrinfo` stops at the first
   search-suffixed NODATA candidate and never tries the absolute name — apps fail
   with `ENOTFOUND` for valid hostnames while `nslookup` (absolute query) works.
   Our own zone is therefore handled in the Corefile, not via a RouterOS FWD
   entry. RouterOS DNS does plain forwarding only (plus the Tailscale `ts.net`
   FWD, which is acceptable as its subdomains genuinely don't exist publicly).
2. **`advertise-dns=no` on new ND entries.** RouterOS creates per-interface
   `ipv6 nd` entries with `advertise-dns=no`, suppressing the RDNSS option even
   when a static `dns=` list is set. Must be enabled explicitly.
3. **Per-interface ND entries must be created, not modified.** Only the
   `interface=all` default ships out of the box; `api_find_and_modify` matching a
   specific interface silently matches nothing. Use `api_modify`.

Verification: `rdisc6` (NixOS package `ndisc6`) dumps RA contents. The CoreDNS
`log` plugin output is visible via `/log print` on the router (container
`logging=yes`) and shows the rcode CoreDNS returned — comparing it to what the
client received isolates which hop corrupts a response.
