# CoreDNS DNS64 + NAT64 — design and implementation

## Goal

Replace the RouterOS built-in DNS forwarder with CoreDNS and implement IPv6-mostly networking (RFC 8925) using DNS64 + NAT64, allowing clients to phase out IPv4 while maintaining full connectivity to IPv4-only destinations.

## Background

The network uses Hurricane Electric as an IPv6 tunnel broker (`2001:470:61a3::/48`). HE assigns addresses from datacenter IP ranges, causing some websites to serve endless CAPTCHAs or flag connections as bot traffic. IPv6-mostly solves this differently: capable clients prefer IPv6 natively, and IPv4-only destinations are reached through NAT64 — using our own IPv4 WAN address rather than HE's, avoiding the datacenter flagging problem for those destinations.

## How it works

```
IPv6-only client                  CoreDNS (DNS64)             NAT64 (Tayga)
      │                                │                            │
      │── AAAA? example.com ──────────▶│                            │
      │                                │── A? example.com ─────────▶ upstream
      │                                │◀── 93.184.216.34 ──────────│
      │◀── 64:ff9b::5db8:d822 ─────────│  (synthesized AAAA)        │
      │                                │                            │
      │── TCP SYN to 64:ff9b::5db8:d822 ──────────────────────────▶│
      │                                │       (RouterOS routes     │
      │                                │        64:ff9b::/96        │
      │                                │        to Tayga)           │
      │                                │                            │── TCP SYN to 93.184.216.34
      │                                │                            │◀─ TCP SYN-ACK
      │◀── TCP SYN-ACK (translated) ───────────────────────────────│
```

For all destinations — including sites with real AAAA records — DNS64 overrides the response with a synthesized `64:ff9b::/96` address. All traffic routes through Tayga and exits on our own IPv4 WAN address, bypassing the HE tunnel broker. This eliminates the datacenter IP flagging and CAPTCHA loops that HE addresses trigger on some sites.

## Components

### CoreDNS (custom build)

Built from source with 7 plugins instead of the default ~40, reducing the compressed image from ~20 MB to ~6-8 MB. This matters for fitting on the CRS internal flash.

Plugin set: `errors`, `log`, `health`, `cache`, `dns64`, `forward`, `reload`.

Plugin order in `plugin.cfg` determines execution order. `dns64` must come before `forward` so it can intercept AAAA responses from upstream rather than letting `forward` return them directly to the client.

Source: [`mikrotik/coredns/`](../mikrotik/coredns/)

The `dns64` plugin is built into CoreDNS — no external plugin needed. It performs the A→AAAA synthesis using the well-known prefix `64:ff9b::/96` (RFC 6052).

`translate_all` and `allow_ipv4` are both set. Without `allow_ipv4`, the plugin only intercepts queries arriving over IPv6 — dual-stack clients querying CoreDNS over IPv4 (the common case, since the router forwards DNS via IPv4) would receive real AAAA records and use the HE tunnel instead of NAT64.

| Client type | AAAA query handling | A query handling |
|---|---|---|
| IPv6-only (CLAT) | synthesized `64:ff9b::` → NAT64 path | not asked; client has no IPv4 stack |
| Dual-stack (no CLAT) | synthesized `64:ff9b::` → NAT64 path | `forward` returns real A → client uses IPv4 directly |
| IPv4-only (no IPv6) | synthesized `64:ff9b::` → client ignores it (no IPv6 stack), uses A record | `forward` returns real A → client uses IPv4 directly |

IPv4-only clients receive synthesized AAAA records but their stack cannot use them — they fall back to A records normally. No breakage.

### Tayga (NAT64)

Stateless IP/ICMP translation (SIIT, RFC 7915). Receives IPv6 packets for `64:ff9b::/96`, strips the prefix to get the IPv4 destination, rewrites the packet headers, and routes it out as IPv4. Return traffic gets the inverse translation.

RouterOS does not implement NAT64 natively (confirmed in official docs). The approach described in some blog posts of writing per-destination `/ipv6 firewall nat dst-nat` rules is not real NAT64 — it is static port forwarding and requires manually enumerating every destination.

Official image: `ghcr.io/apalrd/tayga` — no custom build needed.

### RouterOS

Provides:
- Static IPv6 route `64:ff9b::/96 → Tayga`
- Masquerade of Tayga's IPv4 pool to WAN
- PREF64 option in Router Advertisements (`/ipv6/nd pref64`)
- DHCP option 108 to signal IPv6-only preference to capable clients

## Client behaviour with DHCPv4 option 108

| Client OS | Behaviour |
|---|---|
| iOS 16+, macOS 13+ | Activates CLAT, drops IPv4, uses NAT64 for IPv4 literals |
| Android 10+ | Activates CLAT via PREF64, drops IPv4 |
| Windows 11 (preview) | Partial — CLAT support in preview as of 2026 |
| Linux (NetworkManager) | DHCP option 108 honoured; CLAT via NM requires PREF64 |
| Legacy/unaware devices | Ignore option 108, receive IPv4 lease normally, continue dual-stack |

Option 108 value is a 32-bit seconds timer. Set to 28 (0x1c) for testing, 86400 for production.

## CI/CD

The Woodpecker pipeline at [`.woodpecker/coredns-build.yaml`](../.woodpecker/coredns-build.yaml) triggers on any push that touches `mikrotik/coredns/**`. It:

1. Authenticates to OpenBao using the shared Renovate AppRole (`renovate_role_id` / `renovate_secret_id` Woodpecker secrets)
2. Fetches registry credentials from the `container-registry` KV secret (`REGISTRY_USERNAME` / `REGISTRY_PASSWORD`)
3. Builds the `linux/arm64` image using `docker buildx`
4. Pushes `latest` and a short-SHA tag to `gitea.lumpiasty.xyz/<owner>/coredns-mikrotik`
5. Revokes the OpenBao token

To update the CoreDNS version: change the `--branch` argument in the Dockerfile `git clone` line.

## RouterOS deployment

See [`mikrotik/README.md`](../mikrotik/README.md) for the full set of RouterOS commands.

## Known limitations

- **DNSSEC**: The `dns64` plugin does not validate DNSSEC on synthesized responses (upstream bug noted in the plugin docs). If DNSSEC is required, run a validating resolver upstream and disable synthesis for signed zones.
- **IPv4 literals**: Applications using hardcoded IPv4 addresses (e.g. `connect("1.2.3.4")`) cannot use DNS64. CLAT on the client handles this for capable OSes; legacy apps on non-CLAT clients will fail on IPv6-only VLANs.
- **Native IPv6 bypassed**: `translate_all` means no traffic uses native IPv6 directly — everything goes through Tayga. This is intentional; it trades native IPv6 performance for a consistent exit IP. If native IPv6 is ever desired for specific destinations, remove `translate_all` and handle the HE captcha problem differently (e.g. per-domain exceptions).
- **IPv6-only destinations (no A record)**: With `translate_all`, the plugin still attempts an A lookup for every AAAA query. If no A record exists, `Synthesize` produces a NOERROR with an empty answer — the real AAAA is discarded. Confirmed by reading the source: `responseShouldDNS64` returns `true` unconditionally when `TranslateAll` is set (except NXDOMAIN), and `Synthesize` only converts A records — anything without an A record yields an empty answer. In practice this only affects genuinely IPv6-only destinations with no A record, which is rare on the public internet today.
