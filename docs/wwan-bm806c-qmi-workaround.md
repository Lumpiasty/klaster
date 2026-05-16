# LTE failover (BroadMobi BM806C / D-Link DWR-921 C1) — QMI data-plane workaround

Last verified: 2026-05-16, OpenWrt 25.12.2 r32802-f505120278, netifd 2026.02.26~cbb83a18-r1.

## TL;DR

The embedded BroadMobi BM806C modem in the D-Link DWR-921 attaches to
LTE, gets assigned IP addresses through QMI, reports `"connected"` —
but **no downlink data passes**. Every TCP SYN we send out is dropped
somewhere between the modem and the host kernel, and we never see a
SYN-ACK. After several hours of layered diagnostics we identified two
independent issues, both of which must be fixed for QMI to work on this
device:

1. **`qmi.sh` requests `802.3` framing** from the modem.
   The BM806C's `802.3` firmware path is buggy on this generation of
   Qualcomm silicon; raw-ip framing works correctly. The same kernel
   maintainer who added raw-ip support to `qmi_wwan` documents
   "buggy 802.3 firmware implementation" as a known issue for the
   MDM9x25 family this modem is built on.

2. **`qmi.sh` calls `uqmi --start-network --apn <foo>`** to bring up
   the bearer. On BM806C this triggers a known firmware bug
   ([OpenWrt FS#1363](https://github.com/openwrt/openwrt/issues/6295))
   that establishes a *phantom* bearer: kernel and modem agree there is
   a session, IP addresses are assigned, `--get-data-status` returns
   `"connected"` — but the bearer is not bound to a real PDN at the
   GGSN, so packets are blackholed. Invoking `--start-network --profile
   <N>` against a pre-configured NVRAM profile **with the same APN**
   works perfectly.

Our workaround patches `qmi.sh` in two places (raw-ip + a kernel
`-EBUSY` fix), creates a second NVRAM profile in the modem for the
IPv6 APN, and adds `option profile`/`option v6profile` to the UCI
`wwan` interface so `qmi.sh` uses the working code path. After the
workaround, `ifup wwan` produces a fully working dual-stack IPv4 +
IPv6 LTE uplink — verified end-to-end at HTTPS layer to multiple
upstreams.

## Symptoms

When QMI is broken on this modem, all of the following are true at the
same time:

- `ifup wwan` succeeds, `ifstatus wwan` reports `"up": true`
- `wwan0` has a valid CG-NAT IPv4 (`10.x.x.x/30`) and IPv6
  (`2a00:f41:.../128` for Orange Poland)
- `uqmi --get-data-status` returns `"connected"`
- `ip route` shows default routes via `wwan0`
- `tcpdump -i wwan0` shows outbound TCP SYNs leaving normally with
  the wwan source IP
- **No reply ever comes back**: `RX bytes` on `wwan0` stays near zero
  while `TX bytes` climbs with each connection attempt
- `ping -I wwan0` to any destination shows 100% loss
- `curl --interface wwan0` times out on every TCP connect
- After a while, `+CEER` on an AT port shows
  `Regular deactivation` or `EMM detached` (the network gives up on
  the broken session and drops it)

If your symptoms include `Network registration failed, registration
timeout reached` instead of the silent "everything looks fine but no
data flows", you are probably hitting
[OpenWrt forum issue: BM806U-E1/DWR-921 C3](https://forum.openwrt.org/t/problem-with-bm806u-e1-dwr-921-c3/130094)
which is the same root cause manifesting on a slightly different
firmware revision. The fix is the same.

## What the issue is NOT

We ruled all of these out during diagnosis. If you're tempted by any of
them, read the corresponding "how we confirmed" section before going
down that path.

### Not a signal/RF problem

We initially had RSRP around `-113 dBm` and SNR around 0 dB and
suspected weak coverage. Adding external antennas brought RSRP to
`-94 dBm` and SNR to `+15..+17 dB` — well into the "good LTE" range —
and the data-plane bug remained unchanged. Both poor-signal and
good-signal sessions showed identical TX-only behaviour.

### Not a SIM / subscription / APN-name problem

The same SIM card was confirmed to work in a different LTE router
on the same Orange Poland subscription. The modem also registered
correctly (`+CEREG: 0,1`, `+COPS: 0,0,"Orange",7`), and `AT+CGCONTRDP`
showed valid IPs being assigned by the GGSN. APN strings `internet`
(IPv4v6) and `internetipv6` (IPv6) are Orange Poland's documented
APNs.

### Not a SIM-PIN / SIM-power / EMM detach problem

PIN is disabled and verified disabled (`+CPIN: READY`). EMM detaches
we observed in `+CEER` were *consequences* of the broken bearer,
not the cause: a session with no return traffic eventually gets
torn down by the network.

### Not a firewall / NAT / masquerade problem

We tested with the wwan firewall zone in every combination (REJECT/
ACCEPT, with and without masquerade, with and without explicit
forwarding rules) and the symptom was identical. Inspection of the
nftables byte counters showed packets *leaving* `wwan0` reaching the
forward chain on egress; the problem is that no packets ever arrive
in the other direction. The firewall could not be the cause —
nothing was inbound to be filtered.

### Not an ARP/NDP / asymmetric-routing problem

Initial captures showed unanswered ARP requests for the cellular
gateway on `wwan0`, which is a known issue with `qmi_wwan` in 802.3
mode (the kernel does ARP on what is really a point-to-point
cellular link; the gateway never answers because there is no L2).
We installed permanent neighbour entries to bypass ARP entirely —
traffic still failed. Switching to raw-ip mode (where the kernel
sets `NOARP` on the interface and ARP is never attempted) fixed the
ARP weirdness but did NOT fix the data-plane problem. Both fixes
are needed and they are independent.

### Not an MBIM-vs-QMI problem

The BM806C does not expose an MBIM USB composition. Switching
protocols isn't an option without re-flashing the modem firmware,
which has no public images.

### Not a modem-firmware-update problem

`M1.2.0_E1.0.1_A1.1.8` is the only BM806C firmware that has ever
shipped. BroadMobi (Shanghai Mobile) only releases firmware to
OEM partners; D-Link's last DWR-921 router firmware
(`1.01.3.006 Generic`, no date) bundles the same modem image.
Extracting and re-flashing it would change nothing.

### Not "QMI is fundamentally broken on this modem"

This was our working hypothesis for a long time. The decisive
counter-test was running PPP over `/dev/ttyUSB2` with
`ATD*99***1#` while QMI was idle: data flowed instantly,
HTTPS in 0.7 s, ping 25 ms, 0% loss. Same SIM, same cell,
same antennas, same APN — just a different host-side dial-up
mechanism. That proved the modem, the RAN, and the operator
were all fine. Whatever was breaking QMI had to live in the
QMI control path itself (uqmi / qmi.sh / `qmi_wwan`) and/or in
how the modem handles specific QMI message shapes.

The forum thread and FS#1363 then nailed it down to
`--start-network --apn`.

## How we confirmed it IS the QMI control-path bug

The minimal repro is just two `uqmi` invocations:

```sh
DEV=/dev/cdc-wdm0

# Configure profile 1 in the modem's NVRAM with the v4 APN.
uqmi -d $DEV --modify-profile "3gpp,1" --apn internet --pdp-type ipv4v6

# Switch to raw-ip framing (the other fix).
uqmi -d $DEV --wda-set-data-format raw-ip
ip link set wwan0 down
echo Y > /sys/class/net/wwan0/qmi/raw_ip
ip link set wwan0 up

# Start the bearer.  --profile 1 instead of --apn internet.
cid=$(uqmi -d $DEV --get-client-id wds)
uqmi -d $DEV --set-client-id wds,$cid --set-ip-family ipv4 > /dev/null
uqmi -d $DEV --set-client-id wds,$cid --start-network --profile 1
```

Followed by manual addressing/routing of `wwan0` from
`--get-current-settings`, this **just works** — `curl -4 --interface
wwan0 https://1.1.1.1/` returns `301` in under a second, RX bytes climb.

If you replace `--start-network --profile 1` with `--start-network
--apn internet` (everything else identical), the bearer comes up,
addresses are assigned, `--get-data-status` says `"connected"`, and
no downlink traffic ever arrives. This is the smoking-gun isolation
of the firmware bug.

## Are you affected?

You are affected if all of these hold:

1. Your modem reports `Manufacturer: BroadMobi`, `Model: BM806C` (or
   `BM806U`), `Revision: M1.2.0_E1.0.1_A1.1.8`. Check via any AT port:
   `printf 'ATI\r' | picocom -qrx 3000 /dev/ttyUSB2`.
2. Your USB IDs (after `usb-modeswitch` runs) are
   `2020:2033`. Check `/sys/bus/usb/devices/<port>/idVendor` /
   `idProduct`.
3. `qmi.sh` (`/lib/netifd/proto/qmi.sh`) is the unmodified upstream
   netifd handler. Grep for `--wda-set-data-format 802.3` —
   if present, you have the unpatched script.

The quick functional test is the minimal repro above: if you can get
data flowing with `--start-network --profile 1` but not with
`--start-network --apn internet`, you have this bug.

## Involved components & versions

| Component                | Version                                    |
| ------------------------ | ------------------------------------------ |
| Router                   | D-Link DWR-921 C1 (`dlink,dwr-921-c1`)     |
| SoC                      | MediaTek MT7620N ver:2 eco:6               |
| OpenWrt                  | 25.12.2 (r32802-f505120278)                |
| Kernel                   | Linux 6.12.74                              |
| netifd                   | 2026.02.26~cbb83a18-r1                     |
| uqmi                     | 2025.07.30~7914da43-r2                     |
| libqmi / qmi-utils       | 1.36.0-r1                                  |
| luci-proto-qmi           | 26.133.20346~e9ebca7                       |
| qmi_wwan kernel driver   | in-tree, kernel 6.12.74                    |
| LTE modem                | BroadMobi BM806C (Qualcomm MDM9225)        |
| Modem firmware           | `M1.2.0_E1.0.1_A1.1.8`                     |
| Modem USB id (data mode) | `2020:2033`                                |
| Modem USB id (EDL mode)  | `05c6:9008` (before `usb-modeswitch`)      |
| Mobile network           | Orange Poland (MCC 260 / MNC 03)           |
| APN (IPv4 / dual-stack)  | `internet` (auth: PAP, user/pass `internet`/`internet`) |
| APN (IPv6)               | `internetipv6` (same auth)                 |

## References

- OpenWrt forum thread (same model, same symptoms):
  <https://forum.openwrt.org/t/problem-with-bm806u-e1-dwr-921-c3/130094>
- OpenWrt issue #6295 / FS#1363 — "QMI does not use correct APN":
  <https://github.com/openwrt/openwrt/issues/6295>
- Kernel commit "net: qmi_wwan: support 'raw IP' mode" (Bjørn Mork):
  documents the 802.3-firmware-is-buggy reality across this generation.
  Search the mainline kernel for `QMI_WWAN_FLAG_RAWIP`.
- Kernel commit "net: qmi_wwan: add BroadMobi BM806U 2020:2033"
  (Pawel Dembicki, 2018): adds the `qmi_wwan` entry for our exact USB
  id `2020:2033`. The BM806C and BM806U share the device id and
  qmi_wwan driver path.
- D-Link DWR-921 support page (firmware images, region-specific):
  hardware revision C3 on the Polish site lists firmware
  `1.01.3.006 Generic`, `1.00B07 T-Mobile`, `1.00B06 Plus/Cyfrowy Polsat
  Rev C3` — all of which bundle the same modem firmware build.

## Limitations

### Can this be configured via LuCI / UCI alone?

**Partly.** The UCI side of the workaround is fully achievable through
LuCI or `uci set`:

```sh
uci set network.wwan.profile='1'
uci set network.wwan.v6profile='2'
uci commit network
```

`luci-proto-qmi` already exposes `profile` and `v6profile` as fields in
the LTE wizard. The wwan interface config alone, however, is **not
sufficient** — `qmi.sh` and the modem NVRAM both need attention before
`ifup wwan` will work end-to-end. Specifically:

- The `qmi.sh` patches (raw-ip + `ip link down/up` around the sysfs
  write) are filesystem edits that survive package upgrades only if
  re-applied. They cannot be expressed as UCI.
- Creating modem-NVRAM profile 2 with `internetipv6` is a one-shot QMI
  call (`uqmi --create-profile 3gpp ...`). It is not part of OpenWrt's
  configuration model; the profile lives in the modem itself.

So in practice: configurable via UCI/LuCI as far as the *router* is
concerned, but the fixed router config will only do anything once the
manual modem profile creation and qmi.sh patches are in place.

### `auto '0'` on the wwan interface

We intentionally keep `option auto '0'`: the wwan interface does not
auto-start at boot. This is a deliberate failover-only setup —
`uplink` (the wired VLAN to the MikroTik) is the primary path, and a
human (or future failover script, e.g. `mwan3`) decides when to
bring up wwan.

This also sidesteps a fragile boot ordering question: the modem takes
30–90 s after boot before its QMI service is responsive, and netifd
would otherwise repeatedly fail and back off during that window.

### IPv6 is via a second NVRAM profile, not a single dual-stack PDP

Orange Poland uses two distinct APN strings (`internet` for v4,
`internetipv6` for v6). The BM806C firmware lets us configure profile 1
as `IPV4V6` with `internet`, but the IPv6 leg of that profile cannot be
made to use the dedicated `internetipv6` APN. Our config uses two
independent profiles (profile 1 = IPv4 from `internet`, profile 2 =
IPv6 from `internetipv6`) and `qmi.sh` happily fires both
`--start-network --profile 1` and `--start-network --profile 2`
in sequence (one per address family).

### qmi.sh patches survive package upgrades only if re-applied

`/lib/netifd/proto/qmi.sh` is owned by the `netifd` package. When
netifd is upgraded, the file is replaced. Our patches are *not*
listed in `/etc/sysupgrade.conf` and would not normally be preserved
across a sysupgrade-style image flash either. The Ansible role
re-applies them idempotently on every play; outside Ansible, you
would need a wrapper (e.g. a postinst hook or a manual re-patch
step in your upgrade runbook).

### No automatic failover yet

Bringing wwan up requires explicit `ifup wwan`. There is no monitor
that detects loss of `uplink` and switches over. `mwan3` is the
obvious candidate.

## Implementation (manual, no Ansible)

Everything below assumes you have already SSH'd into the OpenWrt
router as root, the modem is enumerated as `/dev/cdc-wdm0` /
`wwan0`, and `uqmi` / `picocom` are installed.

### Step 1 — patch `qmi.sh`

Three single-line edits to `/lib/netifd/proto/qmi.sh`. Around line 233:

```sh
# Before
uqmi -s -d "$device" -t 1000 --set-data-format 802.3 > /dev/null 2>&1
uqmi -s -d "$device" -t 1000 --wda-set-data-format 802.3 > /dev/null 2>&1
...
echo "Y" > /sys/class/net/$ifname/qmi/raw_ip

# After
uqmi -s -d "$device" -t 1000 --set-data-format raw-ip > /dev/null 2>&1
uqmi -s -d "$device" -t 1000 --wda-set-data-format raw-ip > /dev/null 2>&1
...
ip link set $ifname down; echo "Y" > /sys/class/net/$ifname/qmi/raw_ip; ip link set $ifname up
```

The third edit is essential: writing `Y` to the `raw_ip` sysfs node
fails with `EBUSY` ("Cannot change a running device") if `wwan0` is
up at the moment of the write. The kernel only lets you change the
link-layer protocol while the interface is down. Without this bracket
the patched script logs `sh: write error: Resource busy`, the kernel
driver stays in Ethernet mode, and we are back to broken ARP/NDP.

In-place via `sed`:

```sh
sed -i 's|--set-data-format 802\.3|--set-data-format raw-ip|;
        s|--wda-set-data-format 802\.3|--wda-set-data-format raw-ip|;
        s|^\(\s*\)echo "Y" > /sys/class/net/$ifname/qmi/raw_ip$|\1ip link set $ifname down; echo "Y" > /sys/class/net/$ifname/qmi/raw_ip; ip link set $ifname up|' \
       /lib/netifd/proto/qmi.sh
```

### Step 2 — create modem-NVRAM profile 2 for the IPv6 APN

Profile 1 is managed by `qmi.sh` itself (it calls `--modify-profile
"3gpp,1"` with the UCI `apn` value on every ifup). Profile 2 has to be
bootstrapped once, then it persists in modem NVRAM:

```sh
uqmi -d /dev/cdc-wdm0 --create-profile 3gpp --apn internetipv6 --pdp-type ipv6
# returns {"created-profile": 2}

# Verify
uqmi -d /dev/cdc-wdm0 --get-profile-settings 3gpp,2
# {"apn":"internetipv6","pdp-type":"ipv6", ...}
```

If profile 2 already exists with wrong settings, use `--modify-profile`
instead:

```sh
uqmi -d /dev/cdc-wdm0 --modify-profile 3gpp,2 --apn internetipv6 --pdp-type ipv6
```

### Step 3 — UCI config for the wwan interface

```sh
uci batch <<'EOF'
set network.wwan=interface
set network.wwan.device='/dev/cdc-wdm0'
set network.wwan.proto='qmi'
set network.wwan.apn='internet'
set network.wwan.v6apn='internetipv6'
set network.wwan.profile='1'
set network.wwan.v6profile='2'
set network.wwan.auth='pap'
set network.wwan.username='internet'
set network.wwan.password='internet'
set network.wwan.pdptype='ipv4v6'
set network.wwan.dhcp='0'
set network.wwan.dhcpv6='0'
set network.wwan.metric='100'
set network.wwan.auto='0'
EOF
uci commit network
```

`apn` and `v6apn` are still set even though `profile` / `v6profile`
take precedence on the `--start-network` call: `qmi.sh` uses `apn`
when it runs `--modify-profile 3gpp,1 --apn $apn --pdp-type
$profile_pdptype` near the top of `proto_qmi_setup`, before
`--start-network`. Without it, `qmi.sh` would re-write profile 1 with
an empty APN on every ifup. `v6apn` is not strictly used by `qmi.sh`
in the current code path (the `--start-network --profile 2` invocation
ignores `--apn $v6apn`), but is kept for clarity and so an operator
reading the config sees what APN profile 2 is supposed to point at.

`dhcp '0'` / `dhcpv6 '0'` tell `qmi.sh` to apply the IP addresses
itself (via `proto_add_ipv4_address` / `proto_add_ipv6_address` from
`uqmi --get-current-settings`) instead of spawning `udhcpc` /
`odhcp6c` on `wwan0`. The modem hands out the addresses through QMI;
running DHCP on a point-to-point cellular link would fail anyway.

`metric '100'` keeps `uplink` (metric 0) preferred as the default
route when both are up.

### Step 4 — test

```sh
ifup wwan
sleep 10
ifstatus wwan | head -20
uqmi -d /dev/cdc-wdm0 --get-data-status         # "connected"
cat /sys/class/net/wwan0/qmi/raw_ip             # Y
ip -d link show wwan0 | head -2                 # POINTOPOINT,NOARP, link/none
ip addr show wwan0
```

Then, with `uplink` taken down or the wwan route preferred, verify
real traffic:

```sh
curl -4 --interface wwan0 -sS -o /dev/null -w "%{http_code}\n" https://1.1.1.1/
curl -6 --interface wwan0 -sS -o /dev/null -w "%{http_code}\n" https://[2606:4700:4700::1111]/
```

Both should return `301` within ~1 second. `ip -s link show wwan0`
should show RX bytes climbing.

### Step 5 — teardown / cleanup

```sh
ifdown wwan
```

That's it. The modem-NVRAM profiles persist across reboots and even
across `usb-modeswitch` cycles, so step 2 only ever needs to be run
once per physical SIM/modem.

## Related changes in our config

These accompany the wwan fix in the same time frame; they aren't part
of the wwan workaround per se but were made in the same series of work
and are worth pointing at if you're trying to retrace this end-to-end.

- **VLAN 6 ("uplink")** on the MikroTik CRS418 and on the OpenWrt AP:
  a tagged-only VLAN over ether3/WAN that carries the AP's wired
  uplink to the MikroTik. IPv4 `192.168.6.0/24`, IPv6
  `2001:470:61a3:600::/64` (point-to-point, no SLAAC, static `::1` and
  `::2`). The AP's "uplink" netifd interface is dual-stack on
  `eth0.6`. wwan failover is *to* this uplink, not the LAN.
- **Management policy-routing** on the AP. The management interface
  `mgmt` (192.168.255.11/24 on `eth0.1`) is reached through MikroTik
  from a non-directly-connected subnet, so replies from arbitrary
  src-subnets would have followed the default route out `eth0.6` and
  been blackholed by the MikroTik. We have two policy-routing rules
  (`priority 500` for same-subnet → main table, `priority 1000` for
  any other → table 100) and a `config route` in table 100 sending
  `0.0.0.0/0` back via the MikroTik. None of this interacts with wwan
  directly but it's mentioned so anyone reading `network.yml` does not
  trip over the rules wondering whose problem they are.
- **`community.openwrt.apk` module migration**. OpenWrt 25.12+ uses
  `apk` instead of `opkg`, and the upstream collection's `apk` module
  is only in `community.openwrt` git `main` at the time of writing.
  We pin to `git+main` in `ansible/requirements.yml` until a release
  ships it.
- **Manually-installed packages folded back into `openwrt_packages`**:
  `usb-modeswitch` (drives the modem out of EDL `05c6:9008` into QMI
  `2020:2033` at boot) and `luci-proto-qmi`.

## Future work

In rough priority order:

1. **Upstream a fix to `qmi.sh`** that does the `ip link down/up`
   bracket around the `raw_ip` sysfs write. This is a strict bug in
   the upstream script: as written, the write fails with `EBUSY`
   whenever the modem actually wants raw-ip, which is precisely the
   case `qmi.sh` claims to handle. Likely a 3-line patch. This is the
   easiest, least controversial upstream contribution.
2. **Upstream a fix or knob for the BM806C-style firmware quirk**.
   The cleanest path is probably an OpenWrt-level UCI option
   `prefer_raw_ip` (default off) on the `qmi` proto, similar to how
   `mbim.sh` is constructed. We don't want to change the default
   framing for all qmi devices — newer Qualcomm modems advertise 802.3
   correctly and `qmi.sh`'s readback logic does the right thing for
   them. A per-device opt-in keeps the existing autodetect intact.
3. **Document/upstream the `--profile` workaround for FS#1363**. The
   bug is 7+ years old and still hits real users. The right cleanup is
   probably to make `qmi.sh` prefer `--profile $N` whenever profile
   modification has just succeeded, falling back to `--apn $apn` only
   if no profile was written. This is a behavioural change and would
   need a discussion thread / PR description that walks the reviewer
   through the modem-firmware history.
4. **Replace the `qmi.sh` patches in our Ansible role with a wrapper**
   that does not edit `qmi.sh` directly. Options:
   - A custom proto `qmi-bm806c` that sources the original `qmi.sh`,
     overrides only `proto_qmi_setup`, and registers under a separate
     name. UCI would switch `option proto 'qmi'` → `'qmi-bm806c'`.
     Clean but harder to debug because there is now an extra layer of
     indirection.
   - A hotplug script in `/etc/hotplug.d/iface/` that intercepts
     pre-ifup events on wwan, sets WDA + sysfs raw-ip beforehand, and
     trusts the modem's `802.3` readback to fail naturally so `qmi.sh`
     never writes the sysfs node. Untested. Likely flaky.
   - The current "patch the file, reapply via Ansible" approach is the
     simplest and most direct. It is fine as long as the role is the
     source of truth.
5. **Implement actual failover.** `mwan3` is the conventional choice.
   Alternatively a tiny shell loop that pings a target via `uplink`
   and triggers `ifup wwan` / `ifdown wwan` on transitions. Either way
   the wwan side of the work is done; the failover orchestration is a
   separate problem.
6. **Periodic session keepalive / reconnect on detach.** Even after
   our fix, the modem can still get deactivated by the network
   (`+CEER: Regular deactivation`) after long idle periods. A simple
   `procd` service that polls `uqmi --get-data-status` and triggers
   `ifup wwan` on transition `connected → disconnected` would close
   this gap. Don't pre-emptively add it; wait until you have
   evidence the problem occurs in practice with the workaround in
   place.
7. **Investigate `mbim` mode**. The BM806C does not currently expose
   MBIM, but the modem chipset (MDM9225) supports it at the silicon
   level. Whether there exists a magic AT command, vendor QMI message,
   or firmware composition switch to enable MBIM is unknown — the AT
   command set we explored (`AT^USBMODE`, `AT^SETPORT`, `AT+QCFG`,
   `AT+BMSWITCH`, `AT$QCPDPP`, etc.) all returned `ERROR`. If MBIM
   could be enabled, `qmi.sh` becomes irrelevant and the upstream
   `mbim.sh` proto might just work. Significant payoff if it pans out;
   research-heavy if it doesn't.
8. **Periodic re-test on OpenWrt upgrades**. When OpenWrt's `netifd`
   gets a new release, re-check the qmi.sh patches still apply
   cleanly. Our role uses regex-based `lineinfile`, so it tolerates
   the surrounding code drifting somewhat, but if upstream restructures
   the data-format block significantly we'd need to revisit.

## Things worth noting if anyone picks this up again

- `qmi.sh`'s upstream "set IP format" block runs `--set-data-format`
  first (against the kernel/`qmi_wwan`) and `--wda-set-data-format`
  second (against the modem). Both must agree. We patch both.
- The readback `--wda-get-data-format` call is what `qmi.sh` uses to
  decide whether to write `Y` to sysfs. Our patches make this return
  `"raw-ip"`, which makes the existing branch fire — we don't add a
  branch, we just nudge the existing logic into the path that already
  exists for "device only supports raw-ip" modems.
- The kernel `qmi_wwan` sysfs node `/sys/class/net/wwan0/qmi/raw_ip`
  toggles the *kernel-side* framing. The QMI WDA call toggles the
  *modem-side* framing. They are independent. Both must agree, or
  the kernel will parse bytes that came in as raw-IP as if they were
  Ethernet frames (or vice versa). The result, depending on which
  side is wrong, ranges from "all packets dropped silently in
  `qmi_wwan_rx_fixup`" to "kernel ARPs at a phantom MAC".
- `uqmi --modify-profile 3gpp,1` does work on this modem — both
  the JSON `--get-profile-settings 3gpp,1` and the AT-side
  `AT+CGDCONT?` reflect the new value immediately. The bug is
  specifically with the `--start-network --apn` TLV, not with
  profile management.
- `uqmi --create-profile 3gpp` returns the new profile index in
  `{"created-profile": N}`. It auto-allocates the next free slot, so
  in a fresh modem you'll get `2`, but on an already-configured modem
  you might get `3` or higher. Always read the return value rather
  than assuming `2`. (Our Ansible task hardcodes 2 but checks
  `--get-profile-list` first to skip creation if 2 already exists.)
- `+CEER: Regular deactivation` and `+CEER: EMM detached` are *last
  error* codes; they persist until the modem clears them. Reading
  them tells you the last failure, not necessarily the current state.
  Always cross-reference with `+CEREG?` and `+CGACT?` to know if you
  are presently attached.
- `uqmi -t 5000 -d /dev/cdc-wdm0 --get-serving-system` returns
  `"Failed to connect to service"` for the first 30–90 s after
  boot. This is the QMI service inside the modem firmware not being
  up yet, not a host-side problem.
- The diagnostic scripts we accumulated live on the router at
  `/root/wwan-diag/` (created during debugging; not part of the
  Ansible role). The most useful ones are `at.sh` (run AT commands
  through `picocom`), `ppp-test.sh` (PPP-via-AT as a control test
  that bypasses QMI), and `qmi-dual-profile.sh` (manual
  reproduction of the working `--profile`-based dual-stack flow).
  Feel free to delete them once this is stable; they are not
  load-bearing.

## Acknowledgements

`gotgot04` on the OpenWrt forum did the original triage of FS#1363
against this exact device (DWR-921 C3 / BM806U-E1), and the comment
trail on that thread saved us probably another day of guessing.
