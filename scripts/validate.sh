#!/usr/bin/env bash
# validate.sh -- READ-ONLY post-deploy health check, run ON the Pi as root.
#
#   ssh pi@<pi> 'sudo bash -s' < scripts/validate.sh
#
# Prints PASS / WARN / FAIL per check and exits non-zero if anything FAILed.
# WARN = works but needs a human (e.g. routes awaiting approval in the
# Tailscale admin console). Changes nothing.
set -uo pipefail

pass=0; warn=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
wn()   { printf '  WARN  %s\n' "$1"; warn=$((warn + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
hdr()  { printf '\n[%s]\n' "$1"; }

[[ $EUID -eq 0 ]] || { echo "run as root: ssh pi 'sudo bash -s' < scripts/validate.sh" >&2; exit 2; }

# dig runs inside the pihole container (which shares the host network), so
# the Pi doesn't need dnsutils installed.
pdig() { docker exec pihole dig +time=3 +tries=1 "$@" 2>/dev/null; }
lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"

hdr "Containers"
for c in pihole unbound watchtower uptime-kuma; do
  st="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null)"
  case "$st" in
    running/healthy|running/no-healthcheck) ok "$c $st" ;;
    running/starting) wn "$c $st (re-run in a minute)" ;;
    *) bad "$c ${st:-missing}" ;;
  esac
done

hdr "DNS"
ans="$(pdig @127.0.0.1 -p 5335 dnssec.works +short | head -1)"
if [[ -n $ans ]]; then ok "Unbound resolves recursively (dnssec.works -> $ans)"; else bad "Unbound did not answer on 127.0.0.1:5335"; fi

rc="$(pdig @127.0.0.1 -p 5335 fail01.dnssec.works | awk '/status:/{gsub(",","",$6); print $6}')"
if [[ $rc == SERVFAIL ]]; then ok "Unbound rejects bad DNSSEC (fail01.dnssec.works -> SERVFAIL)"; else wn "DNSSEC negative test returned '${rc:-nothing}' (expected SERVFAIL)"; fi

ans="$(pdig @"${lan_ip:-127.0.0.1}" example.com +short | head -1)"
if [[ -n $ans ]]; then ok "Pi-hole answers on LAN IP ${lan_ip:-?} (example.com -> $ans)"; else bad "Pi-hole did not answer on ${lan_ip:-LAN IP}"; fi

# Test blocking with a domain taken from gravity itself, so this works
# whatever adlists you've configured.
gcount="$(docker exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;' 2>/dev/null)"
gdom="$(docker exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT domain FROM gravity LIMIT 1;' 2>/dev/null)"
if [[ -z $gdom ]]; then
  wn "gravity is empty (first boot still downloading lists? check Pi-hole UI > Adlists)"
else
  ans="$(pdig @127.0.0.1 "$gdom" +short | head -1)"
  if [[ $ans == 0.0.0.0 ]]; then ok "Pi-hole blocks ads ($gdom -> 0.0.0.0; ${gcount:-?} domains in gravity)"
  else bad "blocked domain $gdom returned '${ans:-nothing}' (expected 0.0.0.0)"; fi
fi

hdr "Tailscale"
if command -v tailscale >/dev/null; then
  ts_json="$(tailscale status --json 2>/dev/null)"
  state="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' <<<"$ts_json" 2>/dev/null)"
  if [[ $state == Running ]]; then ok "tailscaled logged in (Running)"; else bad "tailscaled state: ${state:-unknown}"; fi

  prefs="$(tailscale debug prefs 2>/dev/null)"
  adv="$(python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin).get("AdvertiseRoutes") or []))' <<<"$prefs" 2>/dev/null)"
  if [[ $adv == *0.0.0.0/0* ]]; then ok "exit node advertised"; else bad "exit node NOT advertised (routes: ${adv:-none})"; fi

  # AllowedIPs only include routes an admin has APPROVED.
  allowed="$(python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin).get("Self",{}).get("AllowedIPs") or []))' <<<"$ts_json" 2>/dev/null)"
  if [[ $allowed == *0.0.0.0/0* ]]; then ok "exit node approved in admin console"; else wn "exit node awaiting approval in the Tailscale admin console"; fi
  for r in $adv; do
    [[ $r == 0.0.0.0/0 || $r == ::/0 ]] && continue
    if [[ " $allowed " == *" $r "* ]]; then ok "subnet route $r approved"; else wn "subnet route $r awaiting approval in the Tailscale admin console"; fi
  done
else
  bad "tailscale not installed"
fi

for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
  if [[ "$(sysctl -n "$k" 2>/dev/null)" == 1 ]]; then ok "$k = 1"; else bad "$k is not 1"; fi
done

hdr "Hardening"
if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then ok "fail2ban active with sshd jail"; else bad "fail2ban or its sshd jail is not running"; fi
for t in apt-daily.timer apt-daily-upgrade.timer; do
  if systemctl is-enabled --quiet "$t"; then ok "$t enabled"; else bad "$t not enabled"; fi
done
if apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then ok "unattended-upgrades enabled"; else bad "unattended-upgrades not enabled"; fi
if [[ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')" == no ]]; then ok "sshd password auth disabled"; else bad "sshd still allows passwords"; fi
if [[ -f /var/run/reboot-required ]]; then wn "reboot pending (kernel/security update) -- schedule one"; else ok "no reboot pending"; fi

hdr "Backups"
if [[ -f /etc/cron.d/pi-gateway-backup ]]; then ok "backup cron installed"; else bad "backup cron missing"; fi
latest="$(find /var/backups/pi-gateway -maxdepth 1 -name 'pi-gateway-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
if [[ -z $latest ]]; then wn "no backup yet (first runs tonight; or run: sudo /usr/local/sbin/pi-gateway-backup)"
elif [[ -n "$(find "$latest" -mmin -1560)" ]]; then ok "latest backup < 26h old: $latest"
else bad "latest backup is stale: $latest"; fi

printf '\nSummary: %d pass, %d warn, %d fail\n' "$pass" "$warn" "$fail"
[[ $fail -eq 0 ]]
