#!/usr/bin/env bash
# discover.sh -- READ-ONLY fact gathering on the Pi before any deploy.
#
# Changes nothing: no installs, no writes outside stdout. Run it from your
# workstation over SSH and save the output for your own reference:
#
#   ssh pi@$PI_HOST 'bash -s' < scripts/discover.sh | tee discovery-$(date +%F).txt
#
# Uses `sudo -n` (non-interactive) for the listening-socket owners only; if
# passwordless sudo isn't available, that section shows ports without
# process names instead of prompting.
set -uo pipefail   # no -e: one failing probe shouldn't hide the rest

section() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

section "Host"
hostname
uname -srm
[[ -r /etc/os-release ]] && grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release
[[ -r /proc/device-tree/model ]] && { tr -d '\0' < /proc/device-tree/model; echo; }
uptime

section "Architecture check (need aarch64)"
arch="$(uname -m)"
if [[ $arch == aarch64 ]]; then echo "OK: $arch"; else echo "WARN: $arch -- this repo expects 64-bit (aarch64)"; fi

section "Memory / disk"
free -h
df -h / /var 2>/dev/null

section "Network interfaces and addresses"
ip -brief address
section "Default route"
ip route show default
section "Host DNS resolvers (/etc/resolv.conf)"
grep -vE '^\s*(#|$)' /etc/resolv.conf 2>/dev/null

section "Listening sockets (looking for conflicts on 53, 80, 443, 3001, 5335)"
if sudo -n true 2>/dev/null; then
  sudo -n ss -Hlntup | grep -E ':(53|80|443|3001|5335)\s' || echo "none on those ports"
else
  ss -Hlntu | grep -E ':(53|80|443|3001|5335)\s' || echo "none on those ports"
  echo "(no passwordless sudo: process names not shown)"
fi

section "Relevant services"
for svc in ssh systemd-resolved dnsmasq lighttpd pihole-FTL docker containerd tailscaled fail2ban unattended-upgrades NetworkManager dhcpcd; do
  state="$(systemctl is-active "$svc" 2>/dev/null)"; enabled="$(systemctl is-enabled "$svc" 2>/dev/null)"
  printf '%-22s active=%-10s enabled=%s\n' "$svc" "${state:-n/a}" "${enabled:-n/a}"
done

section "Existing Docker"
if have docker; then
  docker --version
  docker compose version 2>/dev/null || echo "compose plugin: not found"
  dpkg-query -W -f='${Package} ${Version}\n' docker-ce docker.io podman-docker 2>/dev/null
  sudo -n docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || echo "(docker ps needs sudo)"
else
  echo "docker: not installed"
fi

section "Existing Tailscale"
if have tailscale; then tailscale version | head -1; tailscale status 2>&1 | head -5; else echo "tailscale: not installed"; fi

section "Existing Pi-hole (bare metal)"
if have pihole; then pihole -v 2>/dev/null; else echo "pihole CLI: not found"; fi

section "IP forwarding"
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding 2>/dev/null

section "SSH auth settings (effective)"
if sudo -n true 2>/dev/null; then
  sudo -n sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication) '
else
  echo "(needs sudo)"
fi

section "Pending reboot"
if [[ -f /var/run/reboot-required ]]; then echo "YES: reboot required"; else echo "no"; fi

echo
echo "Discovery complete. Nothing was changed."
