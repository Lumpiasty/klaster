# Mikrotik containers

RouterOS containers running on the CRS418 providing network services that RouterOS cannot handle natively.

## CoreDNS (DNS64)

Replaces the built-in RouterOS DNS forwarder. Implements DNS64 (RFC 6147): synthesizes AAAA records from A records for IPv4-only destinations, enabling IPv6-only clients to reach them via NAT64. Native dual-stack sites keep their real AAAA records.

Source: [`coredns/`](coredns/)  
Image built by Woodpecker CI, pushed to `gitea.lumpiasty.xyz/<owner>/coredns-mikrotik`.

### Why not the official coredns/coredns image?

The official image ships ~40 plugins and weighs ~20 MB compressed. A custom build with the 7 plugins we actually need fits in ~6-8 MB — important for the CRS internal flash.

### Corefile

The Corefile is baked into the image. To change DNS behaviour, edit [`coredns/Corefile`](coredns/Corefile) and push — the Woodpecker pipeline rebuilds and pushes a new image automatically.

## Tayga (NAT64)

Stateless NAT64 translator (RFC 7915). Receives IPv6 packets destined for `64:ff9b::/96`, rewrites them to IPv4, and returns translated responses. RouterOS does **not** implement NAT64 natively — the official docs state this explicitly.

Official image: `ghcr.io/apalrd/tayga` — no custom build needed.

---

## RouterOS setup

The commands below wire both containers into the network. Adapt interface names and IPv6 prefix to your actual allocation. The HE tunnel broker prefix in use is `2001:470:61a3::/48`; the examples below use a dedicated /64 from the management range for container interfaces.

### 1. Enable container mode (one-time, requires physical access)

```
/system/device-mode/update container=yes
```

### 2. Network interfaces

```
# CoreDNS — dedicated veth, no IPv6 needed (DNS listens on IPv4 of the veth)
/interface/veth/add name=veth-dns address=172.31.0.2/30 gateway=172.31.0.1
/interface/bridge/add name=br-dns
/interface/bridge/port/add bridge=br-dns interface=veth-dns
/ip/address/add address=172.31.0.1/30 interface=br-dns

# Tayga — needs both IPv4 (for its own address) and IPv6 (for the NAT64 traffic path)
/interface/veth/add name=veth-nat64 address=172.31.1.2/30 gateway=172.31.1.1
/interface/bridge/add name=br-nat64
/interface/bridge/port/add bridge=br-nat64 interface=veth-nat64
/ip/address/add address=172.31.1.1/30 interface=br-nat64
/ipv6/address/add address=2001:470:61a3:500::1/64 advertise=no interface=br-nat64
```

### 3. NAT for container internet access

```
/ip/firewall/nat/add chain=srcnat src-address=172.31.0.0/29 action=masquerade comment="container egress"
```

### 4. Tayga container

```
/container/config/set registry-url=https://ghcr.io tmpdir=flash/tmp

/container/envs/add list=ENV_TAYGA key=TAYGA_CONF_IPV4_ADDR    value=172.31.1.2
/container/envs/add list=ENV_TAYGA key=TAYGA_CONF_DYNAMIC_POOL value=192.0.0.0/24
/container/envs/add list=ENV_TAYGA key=TAYGA_CONF_PREFIX        value=64:ff9b::/96
/container/envs/add list=ENV_TAYGA key=TAYGA_IPV6_ADDR          value=2001:470:61a3:500::2

/container/add \
  remote-image=ghcr.io/apalrd/tayga:latest \
  interface=veth-nat64 \
  envlist=ENV_TAYGA \
  root-dir=flash/tayga \
  start-on-boot=yes \
  logging=yes \
  name=tayga
```

### 5. CoreDNS container

```
/container/config/set registry-url=https://gitea.lumpiasty.xyz

/container/add \
  remote-image=gitea.lumpiasty.xyz/<owner>/coredns-mikrotik:latest \
  interface=veth-dns \
  root-dir=flash/coredns \
  start-on-boot=yes \
  logging=yes \
  name=coredns
```

### 6. Routes

```
# IPv6 traffic for the NAT64 prefix goes to Tayga
/ipv6/route/add dst-address=64:ff9b::/96 gateway=2001:470:61a3:500::2 comment="NAT64 via Tayga"

# IPv4 return traffic from Tayga's dynamic pool back to LAN clients
/ip/route/add dst-address=192.0.0.0/24 gateway=172.31.1.2 comment="Tayga dynamic pool"

# Masquerade Tayga's IPv4 pool to WAN
/ip/firewall/nat/add chain=srcnat src-address=192.0.0.0/24 action=masquerade comment="Tayga pool egress"
```

### 7. Point the router's DNS resolver at CoreDNS

```
/ip/dns/set servers=172.31.0.2 allow-remote-requests=yes
```

### 8. PREF64 in Router Advertisements

Tells CLAT-capable clients (iOS, Android, macOS) the NAT64 prefix without requiring DNS64 prefix discovery.

```
/ipv6/nd/set [find] pref64=64:ff9b::/96
```

### 9. DHCP option 108 — IPv6-only preferred (RFC 8925)

Signals to capable clients that they may disable IPv4 and rely on CLAT/NAT64. Clients that don't understand option 108 ignore it and continue with dual-stack.

```
# 0x0000001c = 28 seconds — short for testing; use 0x00015180 (86400) in production
/ip/dhcp-server/option/add name=v6only-preferred code=108 value=0x0000001c
/ip/dhcp-server/option/sets/add name=v6only-set options=v6only-preferred
# Attach the option set to your DHCP server:
/ip/dhcp-server/set [find] dhcp-option-set=v6only-set
```

### Verification

From a client on the LAN (IPv6-only or dual-stack):

```bash
# Should return a synthesized 64:ff9b::/96 AAAA for an IPv4-only host
dig AAAA ipv4.google.com @172.31.0.2

# Should succeed — goes via NAT64
ping 64:ff9b::1.1.1.1

# Full path test from an IPv6-only client
curl -6 https://ipv4only.arpa/
```
