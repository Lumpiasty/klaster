# Ansible

Idempotent configuration management for the home-lab network devices.

## Devices

| Host | Group | IP | Playbook |
|---|---|---|---|
| crs418 (MikroTik CRS418) | `mikrotik` | 192.168.255.10 | `playbooks/routeros.yml` |
| dlink (OpenWrt AP) | `openwrt` | 192.168.255.11 | `playbooks/openwrt.yml` |

Both devices are reachable on the MGMT network (192.168.255.0/24) once fully set up.

## Dependencies

```bash
ansible-galaxy collection install -r requirements.yml
pip install librouteros hvac
```

Collections used:

- `community.routeros >= 3.16.0` — MikroTik API modules
- `community.hashi_vault >= 7.1.0` — OpenBao/Vault secret lookup
- `community.openwrt >= 1.0.0` — OpenWrt UCI and shell modules

## MikroTik (routeros)

Secrets are fetched at runtime from OpenBao. No credentials are stored in files.

```bash
export VAULT_TOKEN=...   # or OPENBAO_TOKEN
ansible-playbook playbooks/routeros.yml
```

Secret layout expected in OpenBao (KVv2, mount `secret`):

| Path | Fields |
|---|---|
| `routeros_api` | `username`, `password` |
| `wan_pppoe` | `username`, `password` |
| `router_tailscale` | `container_password` |

## OpenWrt dlink AP

The dlink needs a one-time initialisation before it can be managed through MikroTik.
There are two playbooks:

### Step 1 — `dlink-init.yml` (once, PC directly connected)

Run this while your PC is plugged into one of the dlink **LAN ports** with the
device still on its factory IP (192.168.1.1). MikroTik must **not** be in the
picture yet.

What it does:
- Reconfigures switch0 so the **WAN port** becomes a VLAN trunk:
  - untagged → VLAN 1 (MGMT, 192.168.255.0/24)
  - tagged → VLAN 2 (LAN, 192.168.0.0/24)
- Adds `mgmt` interface: static 192.168.255.11/24, gateway 192.168.255.10
- Reconfigures `lan` to a bridge on eth0.2 with no IP (AP mode)
- Removes routed `wan`/`wan6` interfaces
- Commits and reloads network in the background

After the reload the device is no longer reachable at 192.168.1.1.

```bash
ansible-playbook playbooks/dlink-init.yml
```

### Step 2 — connect dlink WAN port to MikroTik ether3

Plug the **dlink WAN port** into **MikroTik ether3**.

If the MikroTik config hasn't been applied yet, do it now:

```bash
export VAULT_TOKEN=...
ansible-playbook playbooks/routeros.yml
```

MikroTik ether3 is configured to send MGMT traffic untagged and VLAN 2 (LAN)
tagged, which matches what dlink expects on its WAN port.

### Step 3 — `openwrt.yml` (ongoing, via MikroTik)

All subsequent runs connect to 192.168.255.11 through MikroTik:

```bash
ansible-playbook playbooks/openwrt.yml
```

This is the idempotent main playbook. Run it any time to converge configuration.
