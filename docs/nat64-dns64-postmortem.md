# Postmortem: NAT64 / IPv6-mostly attempt

A record of an architecture that was built, run for ~2 days, and removed. Kept
so the reasoning isn't re-discovered the hard way. For the current DNS setup see
[coredns.md](./coredns.md); for network overview see [network.md](./network.md).

## The original problem

The ISP provides no native IPv6 — only a Hurricane Electric (HE) 6in4 tunnel
(`2001:470:61a3::/48`). HE address ranges are widely classified as
datacenter/hosting space, so some sites (Google, Cloudflare-fronted services,
various login flows) treat IPv6 traffic from them as bot/VPN traffic: endless
CAPTCHAs, "unusual traffic" interstitials, or outright blocks. IPv4 egress
(the ISP's residential PPPoE address) is unaffected.

The goal: keep using the network normally without IPv6 triggering these flags,
while still wanting some IPv6 (e.g. inbound to self-hosted services).

## What was built

An **IPv6-mostly** network (RFC 8925) with **DNS64 + NAT64**, intended to push
egress onto IPv4 while presenting IPv6 to clients:

- **CoreDNS container** with the `dns64` plugin (`translate_all`): synthesized
  `64:ff9b::/96` AAAA records from A records for *all* names, so even dual-stack
  destinations resolved to a NAT64 address.
- **Tayga container** (`ghcr.io/apalrd/tayga-nat64`): stateless NAT64 translator.
  IPv6 traffic to `64:ff9b::/96` was routed to it, translated to IPv4, and
  masqueraded out the GPON PPPoE interface. So all "IPv6" egress actually left
  as IPv4 on the residential address — bypassing the HE tunnel and its flagging.
- **RouterOS RA + DHCP**: DHCP option 108 (IPv6-only preferred) to make capable
  clients drop IPv4, PREF64 (RFC 8781) to advertise the NAT64 prefix for CLAT,
  RDNSS (RFC 8106) to hand IPv6-only clients a resolver.
- Dedicated `nat64` bridge, `fc64::/126` link, `192.168.240.0/20` Tayga pool,
  static routes, and firewall rules (including NAT64-mapped RFC1918 blocks to
  prevent the translator being used as a policy bypass).

## Why it was removed

### 1. Performance — the dealbreaker

Throughput collapsed from line rate (~1 Gbps) to **~200-300 Mbps**, saturating
the router CPU. Causes, all structural:

- Tayga is a **userspace** translator. Every translated packet leaves the kernel
  fastpath, is copied to userspace, translated, and re-injected.
- Translated traffic crosses RouterOS **twice** — once as IPv6 (LAN → Tayga),
  once as IPv4 (Tayga → WAN, with masquerade) — doubling firewall/conntrack work.
- No hardware offload or fasttrack applies to either leg.

With `translate_all`, *nearly all* internet traffic went through this path, so
the penalty hit everything, not just IPv4-only destinations.

### 2. Single point of failure

DNS (CoreDNS) and most of the datapath (Tayga) became two containers in the
critical path on a router whose built-in forwarder had been completely reliable.
Container restarts, image pulls, or a crash now took down connectivity.

### 3. Architectural inversion

NAT64 exists to let **IPv6-only** clients reach the **IPv4** internet. The actual
goal here was the opposite — *avoid* IPv6 egress entirely. Building an IPv6-only
client environment (option 108, CLAT, PREF64) and then translating all of it back
to IPv4 was solving the problem backwards. The complexity existed only to route
around a property of the HE tunnel.

### 4. Firewall complexity and a translation bypass hole

NAT64 punched a hole in the firewall model. RouterOS filters IPv4 and IPv6
independently, but NAT64 traffic enters as IPv6 and *leaves* as IPv4 after
translation — so the carefully-built IPv4 forward policy (inter-VLAN isolation,
RFC1918-to-WAN blocks) was simply bypassed for anything arriving via the
translator. A client could reach a private IPv4 range by encoding it in the
NAT64 prefix (`64:ff9b::c0a8:xxyy` = `192.168.x.y`), and the IPv4 rules would
never see it because the packet was IPv6 until Tayga rewrote it.

Plugging this required mirroring the IPv4 policy in the IPv6 chain: explicit
`reject` rules for every NAT64-mapped RFC1918 block (`64:ff9b::a00:0/104`,
`64:ff9b::ac10:0/108`, `64:ff9b::c0a8:0/112`), per-VLAN accept rules toward the
`nat64` interface, plus a separate masquerade and LB hairpin-accept for the
Tayga pool. That is a parallel, easy-to-get-wrong copy of the existing ruleset,
whose correctness depended on getting CIDR-to-prefix arithmetic right. Removing
NAT64 deleted all of it.

### 5. Operational fragility (see coredns.md for detail)

The setup had a long tail of subtle failure modes, each presenting identically
as "client can't connect":

- RouterOS static `FWD` entries return `NOERROR`/empty instead of relaying
  `NXDOMAIN`, which broke `getaddrinfo` search-domain handling in Kubernetes
  pods (`ENOTFOUND` for valid names).
- `translate_all` discarded real AAAA for IPv6-only internal services, and
  returned empty answers for names with no A record.
- Per-interface RouterOS `ipv6 nd` entries default to `advertise-dns=no` and must
  be *created* (not modified), so RDNSS/PREF64 silently never advertised.
- Dynamic `from-pool` VLAN addressing made advertised RDNSS addresses point at
  nonexistent router addresses.
- Option 108 honoured by clients before the NAT64 path was verified working left
  them stuck "obtaining IP address".

Each was individually fixable, but the aggregate was a brittle system whose
benefit didn't justify the surface area.

## What replaced it

Plain CoreDNS forwarder with **AAAA suppression by default** plus a whitelist for
domains that should keep IPv6 (our own zone over the HE prefix, and any explicitly
trusted domain). Clients prefer IPv4 because they simply don't receive AAAA for
most names — no translation, no extra datapath hop, packet forwarding stays on the
RouterOS fastpath at line rate. DNS is the only thing in the path. See
[coredns.md](./coredns.md).

Tradeoff accepted: a non-whitelisted IPv6-only destination (no A record) is
unreachable. In practice essentially everything on the public internet still has
an A record. The intended future refinement is a CoreDNS plugin that suppresses
AAAA only when an A record also exists, removing the need for the whitelist; no
in-tree plugin does this today.

## Lessons

- **Measure throughput before committing to an in-path translator on SOHO-class
  hardware.** Userspace NAT64 (Tayga/Jool-in-container) on a MikroTik CPU is
  fine for a few hundred Mbps, not for saturating a gigabit line.
- **Match the mechanism to the actual goal.** The goal was "prefer IPv4 egress",
  which is a one-line DNS policy, not a transition technology.
- **Prefer solutions that stay on the fastpath.** Anything that pulls bulk
  traffic into userspace or doubles the forwarding work will dominate the CPU.
- **Fewer moving parts in the critical path.** Two containers carrying all DNS
  and most traffic is a worse availability story than the stock forwarder, for a
  cosmetic benefit (avoiding CAPTCHAs on some sites).
- **Protocol translation breaks the firewall model.** When traffic changes L3
  protocol mid-path, the two firewall policies must be kept in sync by hand, and
  any gap is a silent bypass. A solution that doesn't translate keeps a single
  coherent policy.
