#!/usr/bin/env bash
set -u
name="$1"; peer="$2"
[[ "$name" =~ ^gre[0-9][0-9]?[0-9]?$ && "$peer" =~ ^[0-9.]+$ ]] || exit 2
mkdir -p /run/dvhost-gre
failed=0
while true; do
 stamp=$(date +%s)
 output=$(LC_ALL=C ping -n -4 -I "$name" -c 5 -i 0.3 -W 2 "$peer" 2>&1) || true
 loss=$(sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' <<< "$output" | head -1)
 avg=$(sed -nE 's/^(rtt|round-trip) [^=]+= [0-9.]+\/([0-9.]+)\/.*/\2/p' <<< "$output" | head -1)
 [[ -n "$loss" ]] || loss=100
 [[ -n "$avg" ]] || avg=-
 if [[ "$loss" == 100 || "$loss" == 100.0 ]]; then ((failed+=1)); else failed=0; fi
 state=UP
 if ! ip link show "$name" >/dev/null 2>&1; then state=DOWN
 elif ((failed>=3)); then state=DOWN
 elif ((failed>0)) || [[ "$loss" != 0 && "$loss" != 0.0 ]]; then state=DEGRADED; fi
 tmp=$(mktemp "/run/dvhost-gre/.$name.XXXXXX") || exit 1
 printf 'timestamp=%s\nstate=%s\nloss=%s\nlatency=%s\nfailures=%s\n' "$stamp" "$state" "$loss" "$avg" "$failed" > "$tmp"
 mv -f "$tmp" "/run/dvhost-gre/$name.status"
 sleep 15
done
