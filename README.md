# DVHOST GRE Tunnel v3.0.0 (Experimental)

**🌐 Language:** **English** | [فارسی](README.fa.md) | [Русский](README.ru.md)

![DVHOST GRE Tunnel terminal interface preview](assets/terminal-preview.svg)

*Illustrative terminal UI preview; server details use example data.*

**New architecture**: one Iran server can maintain independent GRE tunnels to multiple foreign servers. This is a development branch; use a staging VM before production.

## Iran-access resilience and path diagnostics

Menu **6 — Iran-access readiness / path diagnostics** checks the public route toward each peer, GRE peer ICMP reachability, direct public-peer ICMP, DNS resolution, and an external HTTPS probe. It is **read-only**: it does not restart interfaces or modify routing or firewall rules. This helps differentiate local failures from multi-path external reachability problems, but cannot conclusively classify an outage. ICMP can be blocked independently of data traffic.

**Recommended deployment:** use at least two foreign endpoints on independent providers/networks, maintain a separately reachable management channel, and make the application layer capable of choosing a healthy tunnel. **GRE alone cannot prevent domestic-only connectivity or restore international paths when all outbound routes are blocked.** Automatic failover of application traffic is not implemented in this version.

## Tunnel engine selector: GRE and SIT

Menu **1 — Create tunnel** now offers **GRE (IPv4 over GRE, IP protocol 47)** or **SIT (IPv6 over IPv4, IP protocol 41)**. SIT creates independent `sit01`, `sit02`, etc. devices with a randomly suggested ULA `/64` prefix on the Iran side; enter that **same prefix** on the foreign side. GRE uses separate `greXX` devices. Both engines have individual systemd units and can be listed, inspected, restarted, and removed independently.

SIT sample: Iran `fd12:3456:789a:bcde::1/64` ⇄ Foreign `fd12:3456:789a:bcde::2/64`. Allow IP protocol **41**, not UDP/TCP port 41. It carries IPv6 only and does **not** provide IPv4 tunnel addresses, encryption, or guaranteed reachability under filtering. No GRE-to-SIT application failover is implemented.

**SIT tuning:** The setup now suggests an MTU (normally 1400) capped by the local underlay interface/route MTU minus the 20-byte IPv4 encapsulation header; choose 1280–1480. Different providers may still need a smaller value, and local route MTU is not proof of end-to-end PMTU. The tunnel detail view runs an IPv6 minimum-MTU ping probe. SIT service cleanup was hardened after a failed startup. These changes apply to newly created SIT tunnels; existing units are not silently rewritten.

## Additional engines: IPIP and GRETAP

The tunnel selector now includes **IPIP** (IPv4 encapsulated in IPv4, IP protocol 4) and **GRETAP** (layer-2 Ethernet over GRE, IP protocol 47). They use distinct interface names (`ipip01`, `gtap01`) and per-interface systemd services, with no global Netplan changes. IPIP requests a private IPv4 prefix shared with its opposite endpoint; GRETAP deliberately creates **only an isolated Ethernet device** and never auto-attaches it to an existing bridge, avoiding accidental L2 loops or disruption. Bridge, VLAN and forwarding configuration, when required, must be made separately and carefully. GRETAP does not bypass GRE protocol-47 filtering. Neither engine encrypts traffic. Validate with `bash -n` and test on staging before use; these additions have not been field-tested.

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
- Country and ISP in the terminal header are best-effort, fetched from an external IP information service and cached for 24 hours. The header's IP is derived from the local route.
- The initial v3 engine is not yet validated on the user's production servers. Monitoring, log history, controlled recovery, and ISP/country detection are follow-up development items.
- GRE is **not encrypted**. Confirm security requirements and firewall configuration.
- The systemd unit currently uses `/usr/bin/ip`; confirm the binary path on the distribution before production rollout.

Telegram: https://t.me/dvhost_cloud
