# DVHOST GRE Tunnel v3.0.0 (Experimental)

**New architecture**: one Iran server can maintain independent GRE tunnels to multiple foreign servers. This is a development branch; use a staging VM before production.

## What's changed

- New per-tunnel systemd oneshot units (`dvhost-gre-v3-greXX.service`)
- Runtime operations via `ip tunnel`; **no global `netplan apply`**
- Each new tunnel gets its own private /30 and unit
- Preflight verifies selected public IPv4 belongs to this server and can route to the foreign endpoint
- Detects names already used by v2, and checks selected local subnet
- Rolls back only a new tunnel when creation/persistence fails
- Existing v2 files and units are not altered

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dev-ir/gre-tunnel/v3.0.0/main.sh)
```

Requirements: Linux, root, systemd, `iproute2`, `modprobe`. Protocol 47 (GRE) must be permitted.

To add the same GRE on both ends, use the identical subnet prefix, set Iran/Foreign roles respectively, and reverse the endpoints. Interface names may differ across hosts.

## Important limitations

- New v3 tunnels persist as dedicated systemd units and are started after network-online at boot. Their unit definitions are not managed by Netplan.
- The v3 UI does **not** import or delete v2 tunnels. Upgrade/migration remains a separate, future action.
- Adding new GRE may still impact host routing if existing manual routes or external software conflict; test before deployment.
- The initial v3 engine is not yet validated on the user's production servers. Monitoring, log history, controlled recovery, and ISP/country detection are follow-up development items.
- GRE is **not encrypted**. Confirm security requirements and firewall configuration.
- The systemd unit uses `/usr/sbin/ip`; confirm the binary path on the distribution before production rollout.

Telegram: https://t.me/dvhost_cloud
