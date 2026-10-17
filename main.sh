#!/usr/bin/env bash
# DVHOST GRE Tunnel - Multi Tunnel Manager
set -Eeuo pipefail
VERSION="2.0.1"
BASE="/etc/dvhost-gre"
BOLD='\033[1m'; DIM='\033[2m'; BLUE='\033[1;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
mkdir -p "$BASE"; chmod 700 "$BASE"
msg(){ printf '%b\n' "$*"; }
pause(){ read -r -p 'Press Enter to continue...' _ || true; }
valid_ip(){
 local ip=$1 x
 [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
 local -a parts
 IFS=. read -ra parts <<< "$ip"
 for x in "${parts[@]}"; do [[ ${#x} -le 3 && $x =~ ^(0|[1-9][0-9]*)$ ]] || return 1; ((10#$x <= 255)) || return 1; done
}
valid_name(){ [[ $1 =~ ^gre[0-9]{2,3}$ ]] && [[ $1 != gre0858 ]]; }
conf(){ echo "$BASE/$1.conf"; }
np(){ echo "/etc/netplan/90-dvhost-$1.yaml"; }
svc(){ echo "dvhost-gre-$1.service"; }
names(){
 local f n
 shopt -s nullglob
 for f in "$BASE"/gre[0-9][0-9].conf "$BASE"/gre[0-9][0-9][0-9].conf; do
  n=${f##*/}; n=${n%.conf}; valid_name "$n" && echo "$n"
 done
 shopt -u nullglob
}
load(){
 [[ -f $(conf "$1") ]] || return 1
 unset ROLE LOCAL_PUBLIC REMOTE_PUBLIC LOCAL_TUNNEL REMOTE_TUNNEL
 source "$(conf "$1")"
 [[ -n ${LOCAL_TUNNEL:-} && -n ${REMOTE_TUNNEL:-} ]]
}
choose(){
 local n
 read -r -p 'Tunnel name (gre01): ' n
 valid_name "$n" && [[ -f $(conf "$n") ]] || { msg "${RED}Unknown tunnel${NC}" >&2; return 1; }
 echo "$n"
}
next_name(){
 local i n
 for ((i=1;i<100;i++)); do
  printf -v n 'gre%02d' "$i"
  if [[ ! -e $(conf "$n") && ! -e $(np "$n") ]] && ! ip link show "$n" &>/dev/null; then echo "$n"; return; fi
 done
 return 1
}
apply(){ netplan generate && netplan apply; }
healthy(){ local n=$1 peer=$2; ip link show dev "$n" >/dev/null 2>&1 && ping -n -4 -I "$n" -c 2 -W 2 "$peer" >/dev/null 2>&1; }
setup_deps(){
 local c missing=0
 for c in ip netplan ping systemctl python3 curl; do command -v "$c" &>/dev/null || missing=1; done
 if ((missing)); then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 iputils-ping netplan.io python3 curl; fi
 modprobe ip_gre 2>/dev/null || true
}
conflict(){
 local a=$1 prefix=$2 n
 while IFS= read -r n; do
  load "$n" || continue
  [[ ${LOCAL_TUNNEL%.*} == "$prefix" ]] && return 0
 done < <(names)
 ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$a" && return 0
 [[ -f /etc/netplan/gre-tunnel.yaml ]] && grep -Eq "${prefix//./\\.}\.[12]/30" /etc/netplan/gre-tunnel.yaml && return 0
 return 1
}
install_monitor(){
 mkdir -p /usr/local/libexec /run/dvhost-gre
 local tmp
 tmp=$(mktemp) || return 1
 if ! curl -fsSL --retry 3 --connect-timeout 10 "https://raw.githubusercontent.com/dev-ir/gre-tunnel/v2.0.1/monitor.sh" -o "$tmp"; then
  rm -f "$tmp"; msg "Failed downloading monitoring component"; return 1
 fi
 bash -n "$tmp" || { rm -f "$tmp"; return 1; }
 install -m 755 "$tmp" /usr/local/libexec/dvhost-gre-monitor
 rm -f "$tmp"
}
write_unit(){
 local n=$1 remote=$2
 [[ -x /usr/local/libexec/dvhost-gre-monitor ]] || install_monitor || return 1
 cat > "/etc/systemd/system/$(svc "$n")" <<EOF
[Unit]
Description=DVHOST GRE Health Monitor ($n)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/libexec/dvhost-gre-monitor $n $remote
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
 systemctl daemon-reload
 systemctl enable --now "$(svc "$n")" >/dev/null
 systemctl restart "$(svc "$n")"
}
monitor_status(){
 local n file timestamp state loss latency age now
 printf '%-8s %-11s %-10s %-12s %-8s\n' NAME HEALTH LOSS LATENCY AGE
 while IFS= read -r n; do
  file="/run/dvhost-gre/$n.status"
  if [[ ! -f "$file" ]]; then printf '%-8s %-11s %-10s %-12s %-8s\n' "$n" UNKNOWN - - -; continue; fi
  timestamp=$(sed -n 's/^timestamp=//p' "$file")
  state=$(sed -n 's/^state=//p' "$file")
  loss=$(sed -n 's/^loss=//p' "$file")
  latency=$(sed -n 's/^latency=//p' "$file")
  if [[ ! "$timestamp" =~ ^[0-9]+$ ]]; then state=UNKNOWN; age=-; else
   now=$(date +%s); age=$((now-timestamp))
   if ((age>60 || age<0)); then state=STALE; fi
   age="$age""s"
  fi
  printf '%-8s %-11s %-10s %-12s %-8s\n' "$n" "$state" "$loss%" "$latency ms" "$age"
 done < <(names)
}
upgrade_monitors(){
 local n
 install_monitor || return 1
 while IFS= read -r n; do
  load "$n" || continue
  write_unit "$n" "$REMOTE_TUNNEL" || msg "Failed: $n"
 done < <(names)
 msg "Monitor services updated."
}
add(){
 local n role iran foreign prefix o1 o2 o3 lp rp a b file cfile
 n=$(next_name) || { msg 'No free GRE names'; return 1; }
 msg "${BLUE}New tunnel: $n${NC}"
 read -r -p 'Role (1=Iran, 2=Foreign): ' role
 [[ $role == 1 || $role == 2 ]] || { msg 'Invalid role'; return 1; }
 local detected_ip suggested_prefix attempt random_a random_b
 detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
 if ! valid_ip "${detected_ip:-}"; then detected_ip=$(curl -4fsS --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || true); fi
 valid_ip "${detected_ip:-}" || detected_ip=""
 if [[ $role == 1 ]]; then
  read -r -p "Iran public IPv4 [${detected_ip:-required}]: " iran
  iran=${iran:-$detected_ip}
  read -r -p 'Foreign public IPv4: ' foreign
 else
  read -r -p 'Iran public IPv4: ' iran
  read -r -p "Foreign public IPv4 [${detected_ip:-required}]: " foreign
  foreign=${foreign:-$detected_ip}
 fi
 valid_ip "$iran" && valid_ip "$foreign" && [[ $iran != "$foreign" ]] || { msg "${RED}Invalid public IPs${NC}"; return 1; }
 if [[ $role == 1 ]]; then lp=$iran; rp=$foreign; else lp=$foreign; rp=$iran; fi
 suggested_prefix=""
 if [[ $role == 1 ]]; then
  for ((attempt=0;attempt<100;attempt++)); do
   random_a=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
   random_b=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
   suggested_prefix="10.$((random_a%256)).$((random_b%256))"
   if ! conflict "$suggested_prefix.1" "$suggested_prefix"; then break; fi
   suggested_prefix=""
  done
 fi
 if [[ -n "$suggested_prefix" ]]; then
  read -r -p "GRE subnet prefix [${suggested_prefix}] (press Enter for auto): " prefix
  prefix=${prefix:-$suggested_prefix}
 else
  read -r -p 'GRE subnet prefix from Iran server (e.g. 10.50.1): ' prefix
 fi
 prefix=${prefix%/30}
 [[ $prefix =~ ^([0-9]{1,3}[.]){3}0$ ]] && prefix=${prefix%.0}
 [[ $prefix =~ ^([0-9]{1,3}[.]){2}[0-9]{1,3}$ ]] && valid_ip "$prefix.1" || { msg "${RED}Invalid subnet${NC}"; return 1; }
 IFS=. read -r o1 o2 o3 <<< "$prefix"
 if ! { ((10#$o1 == 10)) || ((10#$o1 == 172 && 10#$o2 >= 16 && 10#$o2 <= 31)) || ((10#$o1 == 192 && 10#$o2 == 168)); }; then
  msg "${RED}Use a private subnet${NC}"; return 1
 fi
 if [[ $role == 1 ]]; then a="$prefix.1"; b="$prefix.2"; else a="$prefix.2"; b="$prefix.1"; fi
 if conflict "$a" "$prefix"; then msg "${RED}Subnet already in use on this server${NC}"; return 1; fi
 file=$(np "$n"); cfile=$(conf "$n")
 cat > "$file" <<EOF
network:
  version: 2
  renderer: networkd
  tunnels:
    $n:
      mode: gre
      local: $lp
      remote: $rp
      addresses: [$a/30]
      mtu: 1400
EOF
 chmod 600 "$file"
 if ! apply; then rm -f "$file"; apply || true; msg "${RED}Netplan failed; new config removed${NC}"; return 1; fi
 cat > "$cfile" <<EOF
ROLE=$( [[ $role == 1 ]] && echo iran || echo foreign )
LOCAL_PUBLIC=$lp
REMOTE_PUBLIC=$rp
LOCAL_TUNNEL=$a
REMOTE_TUNNEL=$b
EOF
 chmod 600 "$cfile"
 write_unit "$n" "$b" || msg "${YELLOW}Keepalive service failed; check systemctl${NC}"
 msg "${GREEN}Configured $n: $a -> $b${NC}"
 if healthy "$n" "$b"; then msg "${GREEN}Peer reachable${NC}"; else msg "${YELLOW}Peer not responding yet; configure the other side first${NC}"; fi
 msg 'Configure the other side with the same subnet. Allow IP protocol 47.'
}
list(){
 local n state service
 printf '%-8s %-9s %-16s %-16s %-8s %-9s\n' NAME ROLE LOCAL REMOTE LINK SERVICE
 while IFS= read -r n; do
  load "$n" || continue
  state=DOWN; ip link show "$n" &>/dev/null && state=UP; healthy "$n" "$REMOTE_TUNNEL" && state=HEALTHY
  service=inactive; systemctl is-active --quiet "$(svc "$n")" && service=active
  printf '%-8s %-9s %-16s %-16s %-8s %-9s\n' "$n" "$ROLE" "$LOCAL_TUNNEL" "$REMOTE_TUNNEL" "$state" "$service"
 done < <(names)
 [[ ! -f /etc/netplan/gre-tunnel.yaml ]] || msg "${YELLOW}Legacy gre0858 preserved (not managed here)${NC}"
}
status(){
 local n
 n=$(choose) || return
 load "$n"
 ip -d link show "$n" || true
 ip -4 addr show dev "$n" || true
 systemctl --no-pager --full status "$(svc "$n")" | head -n 14 || true
 ping -4 -I "$n" -c 3 -W 2 "$REMOTE_TUNNEL" || msg "${YELLOW}Peer is not responding (check GRE protocol 47 and routing)${NC}"
}
restart(){
 local n
 n=$(choose) || return
 load "$n" || return 1
 if ip link show "$n" &>/dev/null; then
  ip link set dev "$n" down && ip link set dev "$n" up || true
 else
  msg "${YELLOW}Interface missing; applying Netplan${NC}"
  apply || return 1
 fi
 systemctl restart "$(svc "$n")"
 if healthy "$n" "$REMOTE_TUNNEL"; then msg "${GREEN}$n peer reachable${NC}"; else msg "${YELLOW}$n restarted, but peer did not answer ping${NC}"; fi
}
edit_ips(){
 local n lp rp file backup
 n=$(choose) || return
 load "$n"
 read -r -p "New local public IPv4 [$LOCAL_PUBLIC]: " lp
 read -r -p "New remote public IPv4 [$REMOTE_PUBLIC]: " rp
 lp=${lp:-$LOCAL_PUBLIC}; rp=${rp:-$REMOTE_PUBLIC}
 valid_ip "$lp" && valid_ip "$rp" && [[ $lp != "$rp" ]] || { msg 'Invalid IPs'; return 1; }
 file=$(np "$n")
 backup=$(mktemp); cp "$file" "$backup"
 python3 - "$file" "$LOCAL_PUBLIC" "$REMOTE_PUBLIC" "$lp" "$rp" <<'PYCODE'
import sys
from pathlib import Path
p=Path(sys.argv[1])
a,b,c,d=sys.argv[2:]
s=p.read_text()
s=s.replace('local: '+a, 'local: '+c).replace('remote: '+b, 'remote: '+d)
p.write_text(s)
PYCODE
 if ! apply; then cp "$backup" "$file"; apply || true; rm -f "$backup"; msg "${RED}Restored previous config${NC}"; return 1; fi
 rm -f "$backup"
 sed -i "s/^LOCAL_PUBLIC=.*/LOCAL_PUBLIC=$lp/;s/^REMOTE_PUBLIC=.*/REMOTE_PUBLIC=$rp/" "$(conf "$n")"
 msg "${GREEN}Updated $n${NC}"
}
remove_tunnel(){
 local n file backup
 n=$(choose) || return
 read -r -p "Type DELETE-$n to confirm: " answer
 [[ $answer == "DELETE-$n" ]] || { msg 'Cancelled'; return; }
 file=$(np "$n"); backup=$(mktemp)
 cp "$file" "$backup"
 mv "$file" "$file.disabled"
 if ! apply; then mv "$file.disabled" "$file"; apply || true; rm -f "$backup"; msg "${RED}Restored previous config${NC}"; return 1; fi
 systemctl disable --now "$(svc "$n")" &>/dev/null || true
 rm -f "/etc/systemd/system/$(svc "$n")" "$file.disabled" "$(conf "$n")" "$backup"
 systemctl daemon-reload
 rm -f "/run/dvhost-gre/$n.status"
 ip link del "$n" 2>/dev/null || true
 msg "${GREEN}Removed $n only${NC}"
}
# Minimal terminal dashboard; no external UI dependencies.
server_info(){
 local cache="$BASE/server-info.cache" public="" country="Unknown" isp="Unknown" body=""
 if [[ -f "$cache" && -n "$(find "$cache" -mmin -1440 -print 2>/dev/null)" ]]; then
  IFS="|" read -r CACHE_IP CACHE_COUNTRY CACHE_ISP < "$cache" || true
  if [[ -n "${CACHE_IP:-}" ]]; then
   printf "%s|%s|%s\n" "$CACHE_IP" "${CACHE_COUNTRY:-Unknown}" "${CACHE_ISP:-Unknown}"
   return
  fi
 fi
 public=$(curl -4fsS --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || true)
 if [[ -z "$public" ]]; then
  public=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
 fi
 [[ -n "$public" ]] || public=Unknown
 if [[ "$public" != Unknown ]]; then
  body=$(curl -4fsS --connect-timeout 2 --max-time 5 "https://ipwho.is/$public" 2>/dev/null || true)
  if [[ -n "$body" ]]; then
   local parsed
   parsed=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("country") or "Unknown").replace("|"," "), "|", ((d.get("connection") or {}).get("isp") or "Unknown").replace("|"," "))' 2>/dev/null || true)
   if [[ "$parsed" == *' | '* ]]; then country=${parsed% | *}; isp=${parsed#* | }; fi
  fi
 fi
 printf '%s|%s|%s\n' "$public" "$country" "$isp" > "$cache"
 chmod 600 "$cache"
 printf '%s|%s|%s\n' "$public" "$country" "$isp"
}
ui_line(){ printf '%b\n' "${BLUE}  ───────────────────────────────────────────────────${NC}"; }
ui_item(){ printf '%b  %s\n' "  ${GREEN}[ $1 ]${NC}" "$2"; }
ui_title(){ msg "  ${BLUE}$1${NC}"; }
menu(){
 local server_ip server_country server_isp server_data total active=0 n health_file healthy_count=0
 server_data=$(server_info)
 IFS="|" read -r server_ip server_country server_isp <<< "$server_data"
 total=$(names | wc -l)
 while IFS= read -r n; do
  if ip link show "$n" &>/dev/null; then ((active+=1)); fi
  health_file="/run/dvhost-gre/$n.status"
  if [[ -f "$health_file" ]] && grep -qx 'state=UP' "$health_file"; then ((healthy_count+=1)); fi
 done < <(names)
 [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != dumb ]] && clear || true
 printf '\n'
 msg "${BLUE}  ╭────────────────────────────────────────────────────────────╮${NC}"
 msg "${BLUE}  │${NC}  ${BOLD}GRE TUNNEL${NC}                                ${DIM}version $VERSION${NC}  ${BLUE}│${NC}"
 msg "${BLUE}  ├────────────────────────────────────────────────────────────┤${NC}"
 printf '  %-19s %s\n' 'Server Country   |' "$server_country"
 printf '  %-19s %s\n' 'Server ISP       |' "$server_isp"
 printf '  %-19s %s\n' 'Server IP        |' "$server_ip"
 printf '  %-19s %s\n' 'GRE Tunnel       |' "$active / $total active ($healthy_count healthy)"
 msg "${BLUE}  ╰────────────────────────────────────────────────────────────╯${NC}"
 msg "  ${DIM}Copy the IP directly from the Server IP line above.${NC}"
 ui_line
 ui_title 'TUNNEL MANAGEMENT'
 ui_item 1 'Create new GRE tunnel'
 ui_item 2 'View all tunnels'
 ui_item 3 'Tunnel details & diagnostics'
 ui_line
 ui_title 'OPERATIONS'
 ui_item 4 'Restart selected tunnel'
 ui_item 5 'Update public endpoints'
 ui_item 6 'Remove a tunnel'
 ui_line
 ui_title 'MONITORING'
 ui_item 7 'Live quality / health'
 ui_item 8 'Install or upgrade monitors'
 ui_line
 msg "  ${DIM}[ 0 ]  Exit${NC}                       ${DIM}t.me/dvhost_cloud${NC}"
 printf '\n'
}
setup_deps
while true; do
 menu
 printf '%b' "  ${BLUE}›${NC}  "; read -r choice || break
 case $choice in
  1) add || true;; 2) list;; 3) status;; 4) restart;; 5) edit_ips;; 6) remove_tunnel;; 7) monitor_status;; 8) upgrade_monitors;; 0) exit 0;; *) msg 'Invalid choice';;
 esac
 pause
done
