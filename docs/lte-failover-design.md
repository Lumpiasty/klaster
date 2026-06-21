# LTE Failover Design

Reference documentation of the as-built LTE failover design. For day-to-day
network overview see [network.md](./network.md); for BM806C modem firmware
workarounds see [wwan-bm806c-qmi-workaround.md](./wwan-bm806c-qmi-workaround.md).

## Summary

| Property | Value |
|---|---|
| Failover signalling | Symmetric iBGP between D-Link (BIRD2) and CRS (RouterOS) |
| BGP AS | 65000 (iBGP; CRS acts as route reflector for D-Link) |
| LTE transit path | D-Link wwan ← VLAN 6 (192.168.6.0/24) ← CRS |
| D-Link default route source | Learned from CRS via BGP (no static default gateway) |
| CRS LTE route source | Learned from D-Link via BGP at distance 200 |
| Announcement trigger | wwan interface up/down tracked by BIRD2 device protocol |
| Scope | All internet-capable VLANs (vlan2, vlan4, vlan5, vlan6) |
| IPv4 NAT | CRS masquerades on `pppoe-gpon` only; D-Link masquerades on `wwan` |
| IPv6 NAT | D-Link masquerades IPv6 on `wwan` (no inbound on LTE; outbound only) |
| wwan bringup | Triggered by `/etc/init.d/wwan-bringup` after USB re-auth (BM806C wedge fix) |

## Route exchange

### CRS announces to D-Link

| Prefix | Source | Withdrawn when |
|---|---|---|
| `0.0.0.0/0` | `output.default-originate: if-installed` (active default in main table) | GPON drops or `pppoe-gpon` route inactive |
| `2000::/3` | `output.redistribute: static` (HE tunnel default) | `sit1` interface down / HE route inactive |
| VLAN subnets (`192.168.0.0/24`, `192.168.1.0/24`, etc.) | `output.redistribute: connected` | never (CRS always reachable on vlan6) |
| `100.64.0.0/10` (Tailscale) | `output.redistribute: static` | never |
| `172.17.0.0/16` (dockers bridge) | `output.redistribute: connected` | never |
| `10.42.0.0/16`, `10.43.0.0/16`, `10.44.0.0/16` (k8s) | reflected via iBGP RR | when k8s BGP session drops |
| pod/service/LB IPv6 ranges | reflected via iBGP RR | when k8s BGP session drops |

Internal prefixes are announced regardless of GPON state. They remain
reachable via `192.168.6.1` (directly connected on vlan6) even when GPON
fails, so D-Link-originated traffic to internal subnets always routes to
CRS rather than incorrectly exiting via wwan.

The CRS route reflector role (`local.role: ibgp-rr` on the `dlink-lte`
connection) allows it to reflect routes learned from the k8s peer (`bgp1`)
to D-Link without violating iBGP split-horizon. RFC 4456 `ORIGINATOR_ID`
loop prevention is handled automatically by RouterOS — no output filter
needed.

`nexthop-choice: force-self` ensures CRS advertises `192.168.6.1` as the
next-hop for all prefixes, rather than the original route's next-hop
(which may be unreachable from D-Link, e.g. k8s peer `2001:470:61a3:100::3`).

### D-Link announces to CRS

| Prefix | Source | Withdrawn when |
|---|---|---|
| `0.0.0.0/0` | BIRD2 static `lte_default` via `wwan0` | wwan0 down (device protocol detects) |
| `2000::/3` | BIRD2 static `lte_default6` via `wwan0` | wwan0 down |

BIRD2's `protocol device` tracks wwan0 via netlink in real time; when the
interface goes down the static routes become unreachable and BGP withdraws
the announcements immediately.

The BIRD2 static routes use `preference 50` (below the BGP default of 100)
so the BGP-learned routes from CRS are preferred for kernel installation
on D-Link itself — D-Link's own outbound traffic uses the CRS path when
GPON is up. The static routes only exist as triggers for BGP export.

### D-Link kernel routing table

| Destination | Source | Kernel metric | Active when |
|---|---|---|---|
| Internal prefixes (VLANs, k8s, Tailscale) | BGP from CRS, via `192.168.6.1` | 10 (IPv4) / 32 (IPv6) | always (CRS reachable) |
| `0.0.0.0/0` | BGP from CRS | 10 | GPON up |
| `0.0.0.0/0` | wwan QMI-assigned (qmi.sh) | 100 | wwan up |
| `default via wwan IPv6 GW` (non-source-specific) | wwan-bringup script | 1024 | wwan up |
| `default from <wwan prefix>/64 via wwan IPv6 GW` (source-specific) | qmi.sh | 100 | wwan up |

D-Link's own outbound traffic prefers the BGP route (metric 10) over wwan
(metric 100). The non-source-specific IPv6 default at metric 1024 exists
because qmi.sh only installs a source-specific IPv6 default (constrained
to the wwan-assigned `/64` prefix); forwarded traffic from internal
subnets would fail routing lookup with "net unreachable" without it.

### CRS routing table

| Destination | Source | Distance | Active when |
|---|---|---|---|
| `1.0.0.1/32`, `8.8.4.4/32` | static via `pppoe-gpon` | 1 | always |
| `0.0.0.0/0` | static via `1.0.0.1`, `8.8.4.4` (recursive) | 1, 2 | GPON ping check succeeds |
| `0.0.0.0/0` | BGP from D-Link via `192.168.6.2` | 200 | wwan up on D-Link |
| `2000::/3` | static via `2001:470:70:dd::1` (HE tunnel) | 1 | HE tunnel ping check succeeds |
| `2000::/3` | BGP from D-Link via `2001:470:61a3:600::2` | 200 | wwan up on D-Link |

RouterOS distance comparison is straightforward: distance 1 always wins
over distance 200. BGP-learned routes activate automatically when the
static route becomes inactive (e.g. GPON down → `pppoe-gpon` route
inactive → BGP route at distance 200 becomes active).

## Traffic paths

### Normal (GPON up)

```
LAN/SRV/IoT  →  CRS  →  pppoe-gpon  →  ISP
D-Link own   →  uplink  →  CRS  →  pppoe-gpon  →  ISP
                (via BGP-learned default at kernel metric 10)
```

wwan is connected and D-Link announces the LTE default to CRS, but CRS
ignores it (distance 200 loses to distance 1). D-Link uses the
CRS-announced default (metric 10) for its own traffic, not wwan
(metric 100).

### Failover (GPON down)

```
LAN/SRV/IoT  →  CRS  →  vlan6 (→192.168.6.2)  →  D-Link  →  wwan  →  Orange LTE
D-Link own   →  wwan  →  Orange LTE
```

CRS distance-1 routes go inactive → distance-200 BGP routes from D-Link
activate. D-Link receives forwarded traffic on uplink, routes it via the
non-source-specific wwan default (metric 1024), fw4 masquerades the
source, packet exits via wwan. Return traffic reverses through masquerade
state and forwards back to CRS via the established connection-tracking
entry.

When CRS withdraws its BGP-announced default to D-Link (because GPON is
down and CRS has no default to announce), D-Link's kernel default at
metric 10 is removed, leaving the wwan default at metric 100 as the
preferred route for D-Link's own traffic.

### Failure detection

- **D-Link crashes / power loss** → BGP session drops after `hold-time: 30s`
  → CRS withdraws all D-Link-learned routes → internet unavailable if
  GPON also down (acceptable single-point-of-failure for home network)
- **wwan modem goes down** → BIRD2 device protocol detects wwan0 down →
  static `lte_default` / `lte_default6` become unreachable → BGP withdraws
  announcements → CRS removes BGP-learned default
- **GPON drops or blackholes** → recursive ping checks (1.0.0.1, 8.8.4.4) over `pppoe-gpon`
  fail (takes ~20s: 10s ping interval + 10s timeout) → CRS distance-1/2 default routes inactive → distance-200 BGP route
  activates → CRS withdraws its default-originate announcement to D-Link (loop
  prevention prevents reflecting D-Link's own route) → D-Link's kernel
  default-via-CRS is removed → D-Link uses wwan kernel default → traffic flows
  from CRS via vlan6 → D-Link → wwan

All transitions are automatic and driven by interface state. No active
probing (Netwatch / mwan3), no scripts toggling routes.

## NAT rules

NAT rules are always active, matched by output interface. No
failover-triggered toggling needed.

### CRS (RouterOS)

- IPv4 `masquerade` on `srcnat` chain with `out-interface: pppoe-gpon`.
  Only the GPON public interface gets masqueraded — `vlan6` is internal
  and never natted, `sit1` (IPv6) has its own dedicated src-nat for the
  Tailscale prefix.
- IPv6 `src-nat tailnet to internet` on `srcnat` chain for Tailscale
  prefix (`fd7a:115c:a1e0::/48`) to `2001:470:61a3:600::/64`, applied
  on `out-interface-list: wan`. Fires regardless of whether the
  egress is `sit1` or `vlan6`.

### D-Link (OpenWrt fw4)

- `wwan` zone has `option masq '1'` and `option masq6 '1'`. All traffic
  exiting via wwan (own outbound + forwarded from `uplink`) is
  source-NAT'd, IPv4 to the wwan-assigned CG-NAT IP, IPv6 to the
  wwan-assigned `/128` from the Orange-assigned `/64` prefix.
- Forwarding rule `uplink → wwan` allows MikroTik-routed traffic to
  egress via wwan during failover. Default forward policy on the wwan
  zone stays REJECT.

## BGP / route reflection details

### CRS connection config

```
/routing/bgp/connection set dlink-lte \
  remote.address=192.168.6.2/32 \
  local.role=ibgp-rr \
  nexthop-choice=force-self \
  output.redistribute=connected,static \
  output.default-originate=if-installed \
  hold-time=30s keepalive-time=10s
```

`output.default-originate=if-installed` is required for the `0.0.0.0/0`
advertisement because RouterOS does not advertise interface-gateway
static routes (gateway=`pppoe-gpon`) via plain `output.redistribute=static`.
`default-originate` advertises a synthetic default whenever any active
default exists in the routing table, regardless of how it was installed.

### IPv6 Extended Next Hop workaround

RouterOS uses BGP Extended Next Hop Encoding (RFC 5549 / RFC 8950) for
IPv6 routes on this iBGP session, advertising them with an IPv4-mapped
next-hop (`::ffff:192.168.6.1`). The Linux kernel does not support
installing IPv6 routes with IPv4 next-hops, so BIRD2 cannot push them
directly to the kernel.

There is no way to disable ENHE on RouterOS — `local.address`,
`nexthop-choice: force-self`, and output `set gw` filters all fail to
override it. The workaround is on the BIRD2 side: an import filter on
the BGP IPv6 channel rewrites `gw` to CRS's native IPv6 address
(`2001:470:61a3:600::1`) before the route is exported to the kernel.

```
ipv6 {
  extended next hop yes;
  import filter {
    gw = 2001:470:61a3:600::1;
    accept;
  };
  ...
};
```

The reverse direction (D-Link → CRS) was solved cleanly via BIRD2 export
filter setting `bgp_next_hop = 2001:470:61a3:600::2`, since BGP-level
attribute manipulation isn't constrained by kernel limitations.

### Direct protocol on D-Link

BIRD2 needs to know about the directly connected `192.168.6.0/24` and
`2001:470:61a3:600::/64` subnets on `eth0.6` to resolve BGP next-hops.
The `protocol direct { interface "eth0.6"; }` declaration provides this;
without it BIRD2 marks all CRS-learned routes as unreachable.

## BM806C modem cold-boot wedge

The BM806C firmware enters a permanently broken state on cold boot:
`/dev/cdc-wdm0` exists, kernel driver attaches, but uqmi commands return
`"Failed to connect to service"` indefinitely. UIM (SIM) QMI service
specifically never comes up.

Recovery requires a USB device re-enumeration. The `/etc/init.d/wwan-bringup`
service writes `0` then `1` to `/sys/bus/usb/devices/1-1/authorized` on
boot, then triggers `ifup wwan`. After re-auth the modem completes its
QMI initialization within ~1 second.

Full investigation: see [wwan-bm806c-qmi-workaround.md](./wwan-bm806c-qmi-workaround.md).

## Multi-WAN Stale Connection Tracking

When the routing table fails over from GPON to LTE (or vice versa), RouterOS does not automatically clear existing connection tracking entries. If an established TCP/UDP connection is routed out the new WAN interface, it retains the NAT translation state (source IP) of the old WAN interface. The packet is sent to the ISP with the wrong source IP and is silently dropped, causing clients (like Tailscale) to hang for minutes until their internal sockets time out.

To solve this purely declaratively without scripts or blanket connection flushes, the `forward` chain is configured to "fast-fail" these shifted connections:

1. Connections are marked with their egress WAN upon establishment (`wan-gpon` or `wan-lte`) via the `mangle` table.
2. If an established connection with a `wan-gpon` mark attempts to route out `vlan6` (LTE), or a `wan-lte` mark routes out `pppoe-gpon`, it is explicitly rejected (`tcp-reset` for TCP, `icmp-network-unreachable` for UDP) before reaching the NAT table.
3. This rejection immediately signals the client OS that the route is dead, forcing the application (Tailscale, SIP clients, etc.) to instantly close the socket and establish a new one, which successfully binds to the new WAN interface and NAT state.

## Implementation files

| File | Role |
|---|---|
| `ansible/roles/routeros/tasks/base.yml` | `vlan6` in `wan` interface list |
| `ansible/roles/routeros/tasks/routing.yml` | BGP instance, template, `dlink-lte` connection |
| `ansible/roles/routeros/tasks/firewall.yml` | IPv4 masquerade narrowed to `pppoe-gpon`; BGP input rules for `vlan6` |
| `ansible/roles/openwrt/tasks/network.yml` | `wwan` interface (no auto bringup); `uplink` with no static gateway |
| `ansible/roles/openwrt/tasks/firewall.yml` | `wwan` zone with `masq '1'` / `masq6 '1'`; `uplink → wwan` forwarding |
| `ansible/roles/openwrt/tasks/bird.yml` | BIRD2 install + config |
| `ansible/roles/openwrt/tasks/wwan.yml` | qmi.sh patches, BM806C profiles, wwan-bringup init script |
| `ansible/roles/openwrt/defaults/main.yml` | `bird2` in `openwrt_packages` |
