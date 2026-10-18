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
valid_name(){ [[ $1 =~ ^(gre[0-9]{2,3}|sit[0-9]{2}|ipip[0-9]{2}|gtap[0-9]{2})$ && $1 != gre0858 ]]; }
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
 # Include configured but currently inactive IPIP tunnels.
 local f
 for f in "$BASE"/ipip[0-9][0-9].conf; do
  [[ -f "$f" ]] || continue
  grep -Fq "LOCAL_TUN=$p." "$f" && return 0
 done
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

# SIT (IPv6-in-IPv4, IP protocol 41) is a separate engine.
sit_state(){ printf '%s/%s.conf' "$BASE" "$1"; }
sit_names(){
 local f n
 shopt -s nullglob
 for f in "$BASE"/sit[0-9][0-9].conf; do
  n=${f##*/}; n=${n%.conf}; [[ $n =~ ^sit[0-9]{2}$ ]] && echo "$n"
 done
 shopt -u nullglob
}
sit_next(){
 local i n
 for ((i=1;i<=99;i++)); do
  printf -v n 'sit%02d' "$i"
  if [[ ! -e "$(sit_state "$n")" && ! -e "/etc/systemd/system/$(service "$n")" ]] &&
     ! ip link show dev "$n" &>/dev/null &&
     ! grep -RqlF "$n:" /etc/netplan /etc/systemd/network 2>/dev/null; then echo "$n"; return; fi
 done
 return 1
}
sit_load(){
 [[ -f "$(sit_state "$1")" ]] || return 1
 unset ROLE LOCAL_PUBLIC REMOTE_PUBLIC LOCAL_SIT REMOTE_SIT SIT_PREFIX SIT_MTU
 source "$(sit_state "$1")"
 [[ ${ROLE:-} =~ ^(iran|foreign)$ ]] &&
 valid_ip "$LOCAL_PUBLIC" && valid_ip "$REMOTE_PUBLIC" &&
 [[ ${SIT_PREFIX:-} =~ ^fd[0-9a-f]{2}(:[0-9a-f]{4}){3}$ ]] &&
 [[ ${LOCAL_SIT:-} == "$SIT_PREFIX::1" || ${LOCAL_SIT:-} == "$SIT_PREFIX::2" ]] &&
 [[ ${REMOTE_SIT:-} == "$SIT_PREFIX::1" || ${REMOTE_SIT:-} == "$SIT_PREFIX::2" ]] &&
 [[ $LOCAL_SIT != "$REMOTE_SIT" ]]
}
sit_prefix_busy(){
 local prefix=$1
 ip -o -6 addr show | grep -Fq "$prefix:" && return 0
 grep -RFiq "$prefix" "$BASE" /etc/netplan /etc/systemd/network 2>/dev/null && return 0
 return 1
}
sit_random_prefix(){
 local raw prefix i
 for ((i=0;i<100;i++)); do
  raw=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  prefix="fd${raw:0:2}:${raw:2:4}:${raw:6:4}:${raw:10:4}"
  sit_prefix_busy "$prefix" || { printf '%s\n' "$prefix"; return; }
 done
 return 1
}
sit_add(){
 local n role detected iran foreign lp rp prefix proposed addr peer sf unit mtu outer_mtu nic answer
 n=$(sit_next) || { log 'No free SIT names'; return 1; }
 log "${BLUE}CREATE SIT $n (IPv6 over IPv4)${NC}"
 read -r -p 'Role [1 Iran / 2 Foreign]: ' role
 [[ $role == 1 || $role == 2 ]] || { log 'Invalid role'; return 1; }
 detected=$(local_ip)
 if [[ $role == 1 ]]; then
  read -r -p "Iran public IPv4 [$detected]: " iran; iran=${iran:-$detected}
  read -r -p 'Foreign public IPv4: ' foreign
  lp=$iran; rp=$foreign
  proposed=$(sit_random_prefix) || return 1
  read -r -p "SIT IPv6 ULA prefix [$proposed]: " prefix; prefix=${prefix:-$proposed}
 else
  read -r -p 'Iran public IPv4: ' iran
  read -r -p "Foreign public IPv4 [$detected]: " foreign; foreign=${foreign:-$detected}
  lp=$foreign; rp=$iran
  read -r -p 'SIT IPv6 ULA prefix from Iran (fdxx:xxxx:xxxx:xxxx): ' prefix
 fi
 prefix=${prefix,,}
 [[ $prefix =~ ^fd[0-9a-f]{2}(:[0-9a-f]{4}){3}$ ]] || { log "${RED}Invalid IPv6 /64 prefix${NC}"; return 1; }
 sit_prefix_busy "$prefix" && { log "${RED}IPv6 prefix already used locally${NC}"; return 1; }
 preflight "$lp" "$rp" 10.255.255.1 10.255.255.2 || return 1
 # Subtract the 20-byte outer IPv4 header and select a conservative MTU.
 nic=$(ip -4 route get "$rp" from "$lp" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
 outer_mtu=$(ip -4 route get "$rp" from "$lp" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="mtu"){print $(i+1);exit}}')
 if [[ ! $outer_mtu =~ ^[0-9]+$ && -n $nic ]]; then
  outer_mtu=$(cat "/sys/class/net/$nic/mtu" 2>/dev/null || :)
 fi
 mtu=1400
 if [[ $outer_mtu =~ ^[0-9]+$ ]] && ((outer_mtu-20 < mtu)); then mtu=$((outer_mtu-20)); fi
 ((mtu>=1280)) || { log 'Underlay MTU too small for IPv6 SIT'; return 1; }
 read -r -p "SIT MTU [$mtu] (1280-1480): " answer
 mtu=${answer:-$mtu}
 [[ $mtu =~ ^[0-9]+$ ]] && ((10#$mtu>=1280 && 10#$mtu<=1480)) || { log 'Invalid MTU'; return 1; }
 if [[ $outer_mtu =~ ^[0-9]+$ ]] && ((10#$mtu > outer_mtu-20)); then
  log 'MTU exceeds physical-route MTU minus encapsulation overhead'; return 1
 fi
 if [[ $role == 1 ]]; then addr="$prefix::1"; peer="$prefix::2"
 else addr="$prefix::2"; peer="$prefix::1"; fi
 unit="/etc/systemd/system/$(service "$n")"
 cat > "$unit" <<EOF
[Unit]
Description=DVHOST Independent SIT ($n)
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/modprobe sit
ExecStart=/usr/bin/ip tunnel add $n mode sit local $lp remote $rp
ExecStart=/usr/bin/ip -6 addr add $addr/64 dev $n
ExecStart=/usr/bin/ip link set dev $n mtu $mtu up
ExecStop=-/usr/bin/ip tunnel del $n
ExecStopPost=-/usr/bin/ip tunnel del $n
TimeoutStartSec=20
[Install]
WantedBy=multi-user.target
EOF
 chmod 644 "$unit"
 systemctl daemon-reload
 if ! systemctl start "$(service "$n")" || ! systemctl enable "$(service "$n")" >/dev/null; then
  systemctl disable --now "$(service "$n")" >/dev/null 2>&1 || :
  ip tunnel del "$n" >/dev/null 2>&1 || :
  rm -f "$unit"; systemctl daemon-reload
  log "${RED}SIT setup failed; only $n rolled back${NC}"; return 1
 fi
 sf=$(sit_state "$n")
 printf 'ROLE=%s\nLOCAL_PUBLIC=%s\nREMOTE_PUBLIC=%s\nSIT_PREFIX=%s\nLOCAL_SIT=%s\nREMOTE_SIT=%s\nSIT_MTU=%s\n' \
  "$( [[ $role == 1 ]] && echo iran || echo foreign )" "$lp" "$rp" "$prefix" "$addr" "$peer" "$mtu" > "$sf"
 chmod 600 "$sf"
 log "${GREEN}Created $n: $addr -> $peer${NC}"
 log "Enter this same IPv6 prefix on the opposite server: $prefix"
 log "SIT MTU: $mtu"
 log 'SIT uses IPv4 protocol 41. Both endpoints must allow it.'
}
sit_list(){
 local n st
 printf '%-8s %-9s %-26s %-26s %-8s\n' NAME ROLE LOCAL_V6 REMOTE_V6 SERVICE
 while IFS= read -r n; do
  sit_load "$n" || continue
  st=inactive; systemctl is-active --quiet "$(service "$n")" && st=active
  printf '%-8s %-9s %-26s %-26s %-8s\n' "$n" "$ROLE" "$LOCAL_SIT" "$REMOTE_SIT" "$st"
 done < <(sit_names)
}
sit_status(){
 local n=$1
 sit_load "$n" || return
 ip -d link show dev "$n" || :
 systemctl --no-pager status "$(service "$n")" | head -n 12 || :
 ping -6 -n -I "$n" -c 4 -W 2 "$REMOTE_SIT" || :
 log "IPv6 minimum-MTU probe:"
 ping -6 -n -I "$n" -c 1 -W 2 -s 1232 "$REMOTE_SIT" || :
}
sit_remove(){
 local n=$1 confirmation
 read -r -p "Type DELETE-$n to confirm: " confirmation
 [[ "$confirmation" == "DELETE-$n" ]] || { log 'Cancelled'; return; }
 systemctl disable --now "$(service "$n")" || return 1
 rm -f "/etc/systemd/system/$(service "$n")" "$(sit_state "$n")"
 systemctl daemon-reload
 log "Removed only $n"
}

# Additional independent tunnel engines. GRETAP is L2-only: no bridge is modified.
extra_names(){
 local type=$1 f n
 shopt -s nullglob
 for f in "$BASE"/"$type"[0-9][0-9].conf; do
  n=${f##*/}; n=${n%.conf}; printf '%s\n' "$n"
 done
 shopt -u nullglob
}
extra_next(){
 local type=$1 n i
 for ((i=1;i<=99;i++)); do
  printf -v n '%s%02d' "$type" "$i"
  if [[ ! -e "$(state_file "$n")" && ! -e "/etc/systemd/system/$(service "$n")" ]] &&
     ! ip link show dev "$n" >/dev/null 2>&1; then
   echo "$n"; return
  fi
 done
 return 1
}
extra_load(){
 local n=$1
 [[ $n =~ ^(ipip|gtap)[0-9]{2}$ && -f $(state_file "$n") ]] || return 1
 unset TYPE ROLE LOCAL_PUBLIC REMOTE_PUBLIC LOCAL_TUN REMOTE_TUN MTU
 source "$(state_file "$n")"
 [[ $TYPE == ipip || $TYPE == gtap ]] &&
 valid_ip "$LOCAL_PUBLIC" && valid_ip "$REMOTE_PUBLIC" &&
 [[ $LOCAL_PUBLIC != "$REMOTE_PUBLIC" ]] &&
 [[ $MTU =~ ^[0-9]+$ ]] && ((10#$MTU>=1280 && 10#$MTU<=1480)) || return 1
 if [[ $TYPE == ipip ]]; then valid_ip "$LOCAL_TUN" && valid_ip "$REMOTE_TUN"; fi
}
extra_create(){
 local type=$1 n role detected iran foreign lp rp prefix a b mtu under nic answer mod ipbin unit state descriptor
 n=$(extra_next "$type") || { log 'No free interface name'; return 1; }
 log "${BLUE}CREATE ${type^^}: $n${NC}"
 read -r -p 'Role [1 Iran / 2 Foreign]: ' role
 [[ $role == 1 || $role == 2 ]] || { log 'Invalid role'; return 1; }
 detected=$(local_ip)
 if [[ $role == 1 ]]; then
  read -r -p "Iran public IPv4 [$detected]: " iran; iran=${iran:-$detected}
  read -r -p 'Foreign public IPv4: ' foreign
  lp=$iran; rp=$foreign
 else
  read -r -p 'Iran public IPv4: ' iran
  read -r -p "Foreign public IPv4 [$detected]: " foreign; foreign=${foreign:-$detected}
  lp=$foreign; rp=$iran
 fi
 valid_ip "$lp" && valid_ip "$rp" && [[ $lp != "$rp" ]] || { log 'Invalid endpoints'; return 1; }
 preflight "$lp" "$rp" 10.255.255.1 10.255.255.2 || return 1
 a= b=
 if [[ $type == ipip ]]; then
  if [[ $role == 1 ]]; then
   prefix=$(random_prefix) || return 1
   read -r -p "Private IPv4 prefix [$prefix]: " answer; prefix=${answer:-$prefix}
  else
   read -r -p 'Private IPv4 prefix from Iran (10.x.y): ' prefix
  fi
  prefix=${prefix%/30}
  [[ $prefix =~ ^([0-9]{1,3}[.]){3}0$ ]] && prefix=${prefix%.0}
  prefix_valid "$prefix" || { log 'Invalid private prefix'; return 1; }
  prefix_busy "$prefix" && { log 'IPv4 subnet already in use'; return 1; }
  if [[ $role == 1 ]]; then a="$prefix.1"; b="$prefix.2"; else a="$prefix.2"; b="$prefix.1"; fi
 else
  log 'GRETAP creates only an isolated Ethernet interface; bridge attachment is manual.'
 fi
 nic=$(ip -4 route get "$rp" from "$lp" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
 under=$(cat "/sys/class/net/$nic/mtu" 2>/dev/null || echo 1500)
 [[ $under =~ ^[0-9]+$ ]] || under=1500
 mtu=1400
 if [[ $type == ipip ]]; then ((under-20 < mtu)) && mtu=$((under-20))
 else ((under-42 < mtu)) && mtu=$((under-42)); fi
 ((mtu>=1280)) || { log 'Underlay MTU insufficient'; return 1; }
 read -r -p "Tunnel MTU [$mtu]: " answer; mtu=${answer:-$mtu}
 [[ $mtu =~ ^[0-9]+$ ]] && ((10#$mtu>=1280 && 10#$mtu<=1480)) || { log 'Invalid MTU'; return 1; }
 if [[ $type == ipip ]]; then
  ((10#$mtu<=under-20)) || { log 'MTU exceeds underlay'; return 1; }
  mod=ipip; descriptor='IPv4 in IPv4'
 else
  ((10#$mtu<=under-42)) || { log 'MTU exceeds underlay'; return 1; }
  mod=ip_gre; descriptor='Ethernet over GRE'
 fi
 ipbin=$(command -v ip)
 unit="/etc/systemd/system/$(service "$n")"
 state=$(state_file "$n")
 # Generate unique unit. No global network manager, bridge or route changes.
 {
  printf '[Unit]\nDescription=DVHOST %s (%s)\nWants=network-online.target\nAfter=network-online.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\n' "$descriptor" "$n"
  printf 'ExecStartPre=%s %s\n' "$(command -v modprobe)" "$mod"
  if [[ $type == ipip ]]; then
   printf 'ExecStart=%s tunnel add %s mode ipip local %s remote %s\n' "$ipbin" "$n" "$lp" "$rp"
   printf 'ExecStart=%s addr add %s/30 dev %s\n' "$ipbin" "$a" "$n"
  else
   printf 'ExecStart=%s link add %s type gretap local %s remote %s\n' "$ipbin" "$n" "$lp" "$rp"
  fi
  printf 'ExecStart=%s link set dev %s mtu %s up\n' "$ipbin" "$n" "$mtu"
  printf 'ExecStop=-%s link del dev %s\nExecStopPost=-%s link del dev %s\nTimeoutStartSec=20\n[Install]\nWantedBy=multi-user.target\n' "$ipbin" "$n" "$ipbin" "$n"
 } > "$unit"
 chmod 644 "$unit"; systemctl daemon-reload
 if ! systemctl start "$(service "$n")" || ! systemctl enable "$(service "$n")" >/dev/null; then
  systemctl disable --now "$(service "$n")" >/dev/null 2>&1 || :
  ip link del "$n" >/dev/null 2>&1 || :
  rm -f "$unit"; systemctl daemon-reload
  log "${RED}Setup failed; rolled back only $n${NC}"; return 1
 fi
 printf 'TYPE=%q\nROLE=%q\nLOCAL_PUBLIC=%q\nREMOTE_PUBLIC=%q\nLOCAL_TUN=%q\nREMOTE_TUN=%q\nMTU=%q\n' \
  "$type" "$( [[ $role == 1 ]] && echo iran || echo foreign )" "$lp" "$rp" "$a" "$b" "$mtu" > "$state"
 chmod 600 "$state"
 log "${GREEN}Created $n ($descriptor); MTU $mtu${NC}"
 [[ $type == ipip ]] && log "Tunnel peers: $a / $b. Both hosts must use the same prefix."
 log "Permit protocol $( [[ $type == ipip ]] && echo 4 || echo 47 ) at both ends."
}
extra_list(){
 local type n st
 for type in ipip gtap; do
  while IFS= read -r n; do
   extra_load "$n" || continue
   st=inactive; systemctl is-active --quiet "$(service "$n")" && st=active
   printf '%-8s %-7s %-17s %-17s %-9s\n' "$n" "$type" "$LOCAL_PUBLIC" "$REMOTE_PUBLIC" "$st"
  done < <(extra_names "$type")
 done
}
extra_status(){
 local n=$1
 extra_load "$n" || return
 ip -d link show dev "$n" || :
 systemctl --no-pager status "$(service "$n")" | head -n 12 || :
 if [[ $TYPE == ipip ]]; then ping -4 -n -I "$n" -c 4 -W 2 "$REMOTE_TUN" || :
 else log 'GRETAP is L2-only. Connectivity requires user-managed bridge/L2 endpoints.'; fi
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
 log '  Note: GRE/SIT cannot bypass a complete loss of international routing.'
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
 printf '  %-19s %s\n' 'SIT Tunnel       |' "$(sit_names | wc -l) configured"
 printf '  %-19s %s\n' 'IPIP Tunnel      |' "$(extra_names ipip | wc -l) configured"
 printf '  %-19s %s\n' 'GRETAP Tunnel    |' "$(extra_names gtap | wc -l) configured"
 log "${BLUE}  ╰────────────────────────────────────────────────────────────╯${NC}"
}
menu(){
 [[ -t 1 && ${TERM:-dumb} != dumb ]] && clear || :
 header
 ui_rule
 ui_section 'TUNNEL MANAGEMENT'
 ui_option 1 'Create tunnel (GRE / SIT / IPIP / GRETAP)'
 ui_option 2 'List all tunnels'
 ui_option 3 'Tunnel details & connectivity'
 ui_rule
 ui_section 'OPERATIONS'
 ui_option 4 'Restart selected tunnel'
 log "  ${RED}[ 5 ]${NC}  Remove selected tunnel"
 ui_rule
 ui_section 'CONNECTIVITY'
 ui_option 6 'Iran-access readiness / path diagnostics'
 ui_rule
 log "  ${DIM}[ 0 ]  Exit${NC}                        ${DIM}t.me/dvhost_cloud${NC}"
 log "  ${DIM}Existing v2 tunnels remain untouched.${NC}"
 printf '\n'
}
select_engine(){
 log "${BLUE}  TUNNEL ENGINE${NC}"
 log '  [ 1 ] GRE - IPv4 over GRE (protocol 47)'
 log '  [ 2 ] SIT - IPv6 over IPv4 (protocol 41)'
 log '  [ 3 ] IPIP - IPv4 over IPv4 (protocol 4)'
 log '  [ 4 ] GRETAP - Ethernet over GRE (protocol 47)'
 log '  [ 0 ] Back'
 local choice
 read -r -p '  Select: ' choice
 case "$choice" in 1) add;; 2) sit_add;; 3) extra_create ipip;; 4) extra_create gtap;; 0) return;; *) log 'Invalid choice';; esac
}
any_pick(){
 local n
 read -r -p 'Tunnel name (gre01 / sit01 / ipip01 / gtap01): ' n
 valid_name "$n" && [[ -f "$(state_file "$n")" ]] || { log 'Unknown managed tunnel' >&2; return 1; }
 echo "$n"
}
any_status(){
 local n
 n=$(any_pick) || return
 if [[ $n == sit* ]]; then sit_status "$n"
 elif [[ $n == ipip* || $n == gtap* ]]; then extra_status "$n"
 else
  load "$n" || return
  ip -d link show "$n" || :
  systemctl --no-pager status "$(service "$n")" | head -n 12 || :
  ping -n -4 -I "$n" -c 4 -W 2 "$REMOTE_GRE" || :
 fi
}
any_restart(){
 local n
 n=$(any_pick) || return
 systemctl restart "$(service "$n")" && log "Restarted only $n"
}
any_remove(){
 local n
 n=$(any_pick) || return
 if [[ $n == sit* ]]; then sit_remove "$n"
 elif [[ $n == ipip* || $n == gtap* ]]; then
  read -r -p "Type DELETE-$n to confirm: " confirm
  [[ $confirm == "DELETE-$n" ]] || return
  systemctl disable --now "$(service "$n")" || return 1
  rm -f "/etc/systemd/system/$(service "$n")" "$(state_file "$n")"
  systemctl daemon-reload
 else
  read -r -p "Type DELETE-$n to confirm: " confirm
  [[ "$confirm" == "DELETE-$n" ]] || return
  systemctl disable --now "$(service "$n")" || return 1
  rm -f "/etc/systemd/system/$(service "$n")" "$(state_file "$n")"
  systemctl daemon-reload
 fi
}
main(){
 for c in ip systemctl modprobe; do command -v "$c" >/dev/null || { echo "Missing $c"; exit 1; }; done
 while true; do
  menu
  printf '%b' "  ${BLUE}›${NC}  "; read -r choice || break
  case "$choice" in
   1) select_engine || :;; 2) list; sit_list; extra_list;; 3) any_status;; 4) any_restart;; 5) any_remove;; 6) network_readiness;; 0) return;; *) log 'Invalid choice';;
  esac
  pause
 done
}
main "$@"
