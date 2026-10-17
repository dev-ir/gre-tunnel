# DVHOST GRE Tunnel v2.0.0

Multi-tunnel GRE manager for Ubuntu with Netplan and systemd.

## Features
- Multiple independent GRE tunnels (gre01, gre02, ...)
- Separate Netplan and keepalive service for each tunnel
- List, check, restart, edit public IPs, and delete an individual tunnel
- Existing legacy gre0858 configuration remains untouched

## Install

Run on **both** Iran and foreign servers:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dev-ir/gre-tunnel/v2.0.0/main.sh)
```

Choose **Add GRE Tunnel**. Set the Iran and foreign public IPv4 addresses identically on both hosts, selecting the corresponding role (Iran/Foreign). Use the **same unique private GRE subnet prefix** (for example, `10.50.1`) on both hosts. For a second foreign server, create another tunnel on the Iran server with a **different subnet**, for example `10.50.2`.

Open **IP protocol 47 (GRE)** on both servers and any provider firewalls. GRE is not encrypted. Avoid running Netplan changes over SSH without console recovery access.

## Examples

| Node | Interface | Local tunnel IPv4 | Peer tunnel IPv4 |
| --- | --- | --- | --- |
| Iran → Germany | gre01 | 10.50.1.1/30 | 10.50.1.2 |
| Germany → Iran | gre01 | 10.50.1.2/30 | 10.50.1.1 |
| Iran → Finland | gre02 | 10.50.2.1/30 | 10.50.2.2 |
| Finland → Iran | gre01 | 10.50.2.2/30 | 10.50.2.1 |

Interface names are **local to each server** and may differ. Keep the corresponding subnet and public endpoint pair consistent.

## Compatibility

v2.0.0 stores configs under `/etc/dvhost-gre/`, Netplan definitions in `/etc/netplan/90-dvhost-greXX.yaml`, and keepalive units as `dvhost-gre-greXX.service`. It does not migrate or modify the old `gre0858` tunnel.

## Support

Telegram: https://t.me/dvhost_cloud
