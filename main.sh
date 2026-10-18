#!/usr/bin/env bash
# DVHOST GRE Tunnel v3.0.0 - independent per-tunnel engine
set -Eeuo pipefail
VERSION=3.0.0
BASE=/etc/dvhost-gre-v3
BOLD='\033[1m'; DIM='\033[2m'; BLUE='\033[1;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
mkdir -p "$BASE"; chmod 700 "$BASE"
log(){ printf '%b\n' "$*"; }
pause(){ read -r -p 'Press Enter to continue...' _ || :; }
valid_ip(){
 local x a b c d
 [[ $1 =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || return 1
 IFS=. read -r a b c d <<< "$1"
 for x in "$a" "$b" "$c" "$d"; do [[ $x =~ ^(0|[1-9][0-9]*)$ ]] || return 1; ((10#$x<=255)) || return 1; done
}
valid_name(){ [[ $1 =~ ^gre[0-9]{2,3}$ && $1 != gre0858 ]]; }
state_file(){ printf '%s/%s.conf' "$BASE" "$1"; }
service(){ printf 'dvhost-gre-v3-%s.service' "$1"; }
load(){
 [[ -f $(state_file "$1") ]] || return 1
 unset ROLE LOCAL_PUBLIC REMOTE_PUBLIC LOCAL_GRE REMOTE_GRE
 source "$(state_file "$1")"
 [[ ${ROLE:-} =~ ^(iran|foreign)$ ]] && valid_ip "$LOCAL_PUBLIC" && valid_ip "$REMOTE_PUBLIC" &&
 valid_ip "$LOCAL_GRE" && valid_ip "$REMOTE_GRE"
}
names(){
 local f n
 shopt -s nullglob
 for f in "$BASE"/gre[0-9][0-9].conf "$BASE"/gre[0-9][0-9][0-9].conf; do
  n=${f##*/}; n=${n%.conf}; valid_name "$n" && echo "$n"
 done
 shopt -u nullglob
}
next_name(){
 local n i
 for ((i=1;i<=99;i++)); do
  printf -v n 'gre%02d' "$i"
  if [[ ! -e $(state_file "$n") && ! -e "/etc/dvhost-gre/$n.conf" && ! -e /etc/systemd/system/$(service "$n") ]] &&
   ! ip link show dev "$n" &>/dev/null && ! grep -RqlE "(^|[[:space:]])$n:" /etc/netplan /etc/systemd/network 2>/dev/null; then
   echo "$n"; return
  fi
 done
 return 1
}
local_ip(){
 ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'
}
prefix_valid(){
 local a b c
 [[ $1 =~ ^([0-9]{1,3}[.]){2}[0-9]{1,3}$ ]] || return 1
 valid_ip "$1.1" || return 1
 IFS=. read -r a b c <<< "$1"
 ((a==10 || (a==172 && b>=16 && b<=31) || (a==192 && b==168)))
}
prefix_busy(){
 local p=$1 n prefix
 while IFS= read -r n; do
  load "$n" || continue
  [[ ${LOCAL_GRE%.*} == "$p" ]] && return 0
 done < <(names)
 # Inspect all currently configured IPv4 addresses, including unmanaged tunnels.
 ip -o -4 addr show | awk '{print $4}' | grep -Eq "^$p[.][12]/" && return 0
 # Avoid matching existing GRE /30 subnets elsewhere in system configuration.
 grep -RqE "$p[.][12]/30" /etc/netplan /etc/systemd/network /etc/dvhost-gre 2>/dev/null && return 0
 return 1
}
random_prefix(){
 local i a b p
 for ((i=0;i<200;i++)); do
  a=$(od -An -N1 -tu1 /dev/urandom); b=$(od -An -N1 -tu1 /dev/urandom)
  p="10.$a.$b"
  prefix_busy "$p" || { echo "$p"; return; }
 done
 return 1
}
preflight(){
 local local_pub=$1 remote_pub=$2 local_gre=$3 remote_gre=$4
 valid_ip "$local_pub" && valid_ip "$remote_pub" && valid_ip "$local_gre" && valid_ip "$remote_gre" || return 1
 [[ $local_pub != "$remote_pub" && $local_gre != "$remote_gre" ]] || return 1
 ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$local_pub" || {
  log "${RED}Local public IP is not assigned on this host.${NC}"; return 1;
 }
 ip -4 route get "$remote_pub" from "$local_pub" >/dev/null || {
  log "${RED}No route to remote public IP from selected local IP.${NC}"; return 1;
 }
}
write_service(){
 local n=$1 lp=$2 rp=$3 a=$4 b=$5 unit_file
 unit_file="/etc/systemd/system/$(service "$n")"
 cat > "$unit_file" <<EOF
[Unit]
Description=DVHOST Independent GRE ($n)
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/modprobe ip_gre
ExecStart=/usr/bin/ip tunnel add $n mode gre local $lp remote $rp
ExecStart=/usr/bin/ip addr add $a/30 dev $n
ExecStart=/usr/bin/ip link set dev $n mtu 1400 up
ExecStop=-/usr/bin/ip tunnel del $n
TimeoutStartSec=20
[Install]
WantedBy=multi-user.target
EOF
 chmod 644 "$unit_file"
 systemctl daemon-reload
}
add(){
 local n role detected iran foreign prefix lp rp a b file
 n=$(next_name) || { log 'No free GRE interface name.'; return 1; }
 log "${BLUE}CREATE $n${NC}"
 read -r -p 'Role [1 Iran / 2 Foreign]: ' role
 [[ $role == 1 || $role == 2 ]] || { log 'Invalid role'; return 1; }
 detected=$(local_ip)
 if [[ $role == 1 ]]; then
  read -r -p "Iran public IP [$detected]: " iran; iran=${iran:-$detected}
  read -r -p 'Foreign public IP: ' foreign
  lp=$iran; rp=$foreign
 else
  read -r -p 'Iran public IP: ' iran
  read -r -p "Foreign public IP [$detected]: " foreign; foreign=${foreign:-$detected}
  lp=$foreign; rp=$iran
 fi
 valid_ip "$iran" && valid_ip "$foreign" || { log 'Invalid IP'; return 1; }
 local suggested=""
 if [[ $role == 1 ]]; then suggested=$(random_prefix) || return 1; fi
 if [[ -n $suggested ]]; then
  read -r -p "Private GRE prefix [$suggested]: " prefix; prefix=${prefix:-$suggested}
 else
  read -r -p 'Private GRE prefix from Iran (e.g. 10.50.1 or 10.50.1.0/30): ' prefix
 fi
 prefix=${prefix%/30}
 [[ $prefix =~ ^([0-9]{1,3}[.]){3}0$ ]] && prefix=${prefix%.0}
 prefix_valid "$prefix" || { log 'Invalid private prefix'; return 1; }
 prefix_busy "$prefix" && { log 'Subnet already in use'; return 1; }
 if [[ $role == 1 ]]; then a="$prefix.1"; b="$prefix.2"; else a="$prefix.2"; b="$prefix.1"; fi
 preflight "$lp" "$rp" "$a" "$b" || return 1
 file=$(state_file "$n")
 write_service "$n" "$lp" "$rp" "$a" "$b"
 # No global netplan apply; rollback only this newly created unit.
 if ! systemctl start "$(service "$n")"; then
  systemctl stop "$(service "$n")" >/dev/null 2>&1 || :
  ip link del "$n" >/dev/null 2>&1 || :
  rm -f "/etc/systemd/system/$(service "$n")"
  systemctl daemon-reload
  log "${RED}Creation failed; only $n was rolled back.${NC}"; return 1
 fi
 if ! systemctl enable "$(service "$n")" >/dev/null; then
  systemctl stop "$(service "$n")" || :
  rm -f "/etc/systemd/system/$(service "$n")"
  systemctl daemon-reload
  log "${RED}Persistence failed; rolled back $n.${NC}"; return 1
 fi
 printf 'ROLE=%s\nLOCAL_PUBLIC=%s\nREMOTE_PUBLIC=%s\nLOCAL_GRE=%s\nREMOTE_GRE=%s\n' \
  "$( [[ $role == 1 ]] && echo iran || echo foreign )" "$lp" "$rp" "$a" "$b" > "$file"
 chmod 600 "$file"
 log "${GREEN}Created $n  $a -> $b${NC}"
 log "Peer subnet: $prefix.0/30"
 log 'Peer must use the reverse local/remote public IPs. Allow GRE protocol 47.'
}
list(){
 local n state health
 printf '%-8s %-9s %-17s %-17s %-9s\n' NAME ROLE LOCAL REMOTE SERVICE
 while IFS= read -r n; do
  load "$n" || continue
  state=inactive; systemctl is-active --quiet "$(service "$n")" && state=active
  printf '%-8s %-9s %-17s %-17s %-9s\n' "$n" "$ROLE" "$LOCAL_GRE" "$REMOTE_GRE" "$state"
 done < <(names)
}
pick(){
 local n
 read -r -p 'Tunnel name: ' n
 valid_name "$n" && [[ -f $(state_file "$n") ]] || { log 'Unknown tunnel' >&2; return 1; }
 echo "$n"
}
status(){
 local n
 n=$(pick) || return
 load "$n" || return
 ip -d link show "$n" || :
 systemctl --no-pager status "$(service "$n")" | head -n 12 || :
 ping -n -4 -I "$n" -c 4 -W 2 "$REMOTE_GRE" || :
}
restart(){
 local n
 n=$(pick) || return
 systemctl restart "$(service "$n")"
 log 'Only selected tunnel was restarted.'
}
remove_tunnel(){
 local n
 n=$(pick) || return
 read -r -p "Type DELETE-$n to confirm: " confirm
 [[ $confirm == "DELETE-$n" ]] || { log 'Cancelled'; return; }
 systemctl disable --now "$(service "$n")" || return 1
 rm -f "/etc/systemd/system/$(service "$n")" "$(state_file "$n")"
 systemctl daemon-reload
 log "Removed $n independently."
}
# Iran-access readiness diagnostics. Read-only: no routes, tunnels or firewall rules change.
network_readiness(){
 local n lp rp a b route src probe status count=0 ok=0
 log "${BLUE}  NETWORK REACHABILITY / IRAN-ACCESS READINESS${NC}"
 log '  Checks are best-effort. ICMP may be blocked even when GRE works.'
 ui_rule
 printf '%-8s %-13s %-16s %-15s\n' NAME OUTER_ROUTE GRE_PEER PUBLIC_PEER
 while IFS= read -r n; do
  load "$n" || continue
  ((count+=1))
  route=NO_ROUTE
  if ip -4 route get "$REMOTE_PUBLIC" from "$LOCAL_PUBLIC" >/dev/null 2>&1; then route=ROUTABLE; fi
  status=NO_REPLY
  if ip link show dev "$n" >/dev/null 2>&1 && ping -n -4 -I "$n" -c 2 -W 2 "$REMOTE_GRE" >/dev/null 2>&1; then
   status=REACHABLE; ((ok+=1))
  fi
  probe=NO_REPLY
  ping -n -4 -c 1 -W 2 "$REMOTE_PUBLIC" >/dev/null 2>&1 && probe=REACHABLE
  printf '%-8s %-13s %-16s %-15s\n' "$n" "$route" "$status" "$probe"
 done < <(names)
 ui_rule
 log "  GRE peers responding: $ok / $count"
 if (( count>0 && ok==0 )); then
  log "${RED}  WARNING: All managed GRE peers failed ICMP probing.${NC}"
  log '  Check outer-network filtering, peer firewalls, DNS and routing.'
 elif (( ok>0 && ok<count )); then
  log "${YELLOW}  Some paths are unresponsive; healthy paths may still carry traffic.${NC}"
 elif ((count>0)); then
  log "${GREEN}  Managed GRE peers answered; not proof of Internet access.${NC}"
 fi
 log '  DNS resolution:'
 if command -v getent >/dev/null 2>&1 && timeout 4 getent ahostsv4 example.com >/dev/null 2>&1; then
  log "${GREEN}  DNS: OK${NC}"
 else
  log "${YELLOW}  DNS: UNAVAILABLE or TIMEOUT${NC}"
 fi
 log '  External HTTPS probe (IPv4):'
 if command -v curl >/dev/null 2>&1; then
  if curl -4 -fsS -o /dev/null --connect-timeout 3 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace; then
   log "${GREEN}  HTTPS: REACHABLE${NC}"
  else
   log "${YELLOW}  HTTPS: NO RESPONSE (not conclusive)${NC}"
  fi
 else
  log '  HTTPS: SKIPPED (curl unavailable)'
 fi
 log '  Note: GRE cannot bypass a complete loss of international routing.'
 log '  Keep distinct upstreams and an independently reachable backup path.'
}
# Compact DVHOST terminal dashboard
ui_rule(){ log "${BLUE}  ────────────────────────────────────────────────────────────${NC}"; }
ui_section(){ log "${BLUE}  $1${NC}"; }
ui_option(){ log "  ${GREEN}[ $1 ]${NC}  $2"; }
server_meta(){
 local ip="$1" cache="$BASE/server-meta.cache" country=Unknown isp=Unknown json
 if [[ -f "$cache" ]] && [[ -n "$(find "$cache" -mmin -1440 -print 2>/dev/null)" ]]; then
  cat "$cache"; return
 fi
 if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [[ -n "$ip" ]]; then
  json=$(curl -4fsS --connect-timeout 2 --max-time 4 "https://ipwho.is/$ip" 2>/dev/null || :)
  if [[ -n "$json" ]]; then
   local result
   result=$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("country") or "Unknown").replace("|"," ")+"|"+((d.get("connection") or {}).get("isp") or "Unknown").replace("|"," "))' 2>/dev/null || :)
   [[ "$result" == *'|'* ]] && { printf '%s\n' "$result" > "$cache"; chmod 600 "$cache"; }
  fi
 fi
 if [[ -f "$cache" ]]; then cat "$cache"; else printf '%s|%s\n' "$country" "$isp"; fi
}
header(){
 local ip info country isp total=0 active=0 n
 ip=$(local_ip)
 info=$(server_meta "$ip")
 IFS='|' read -r country isp <<< "$info"
 while IFS= read -r n; do
  ((total+=1))
  systemctl is-active --quiet "$(service "$n")" && ((active+=1))
 done < <(names)
 printf '\n'
 log "${BLUE}  ╭────────────────────────────────────────────────────────────╮${NC}"
 log "${BLUE}  │${NC}  ${GREEN}DVHOST${NC} / ${BOLD}GRE TUNNEL${NC}                     ${DIM}version $VERSION${NC}  ${BLUE}│${NC}"
 log "${BLUE}  ├────────────────────────────────────────────────────────────┤${NC}"
 printf '  %-19s %s\n' 'Server Country   |' "${country:-Unknown}"
 printf '  %-19s %s\n' 'Server ISP       |' "${isp:-Unknown}"
 printf '  %-19s %s\n' 'Server IP        |' "${ip:-Unknown}"
 printf '  %-19s %s\n' 'GRE Tunnel       |' "$active / $total active"
 log "${BLUE}  ╰────────────────────────────────────────────────────────────╯${NC}"
}
menu(){
 [[ -t 1 && ${TERM:-dumb} != dumb ]] && clear || :
 header
 ui_rule
 ui_section 'TUNNEL MANAGEMENT'
 ui_option 1 'Create independent GRE tunnel'
 ui_option 2 'List GRE tunnels'
 ui_option 3 'Tunnel details & connectivity'
 ui_rule
 ui_section 'OPERATIONS'
 ui_option 4 'Restart selected GRE'
 log "  ${RED}[ 5 ]${NC}  Remove selected GRE"
 ui_rule
 ui_section 'CONNECTIVITY'
 ui_option 6 'Iran-access readiness / path diagnostics'
 ui_rule
 log "  ${DIM}[ 0 ]  Exit${NC}                        ${DIM}t.me/dvhost_cloud${NC}"
 log "  ${DIM}Existing v2 tunnels remain untouched.${NC}"
 printf '\n'
}
main(){
 for c in ip systemctl modprobe; do command -v "$c" >/dev/null || { echo "Missing $c"; exit 1; }; done
 while true; do
  menu
  printf '%b' "  ${BLUE}›${NC}  "; read -r choice || break
  case "$choice" in
   1) add || :;; 2) list;; 3) status;; 4) restart;; 5) remove_tunnel;; 6) network_readiness;; 0) return;; *) log 'Invalid choice';;
  esac
  pause
 done
}
main "$@"
