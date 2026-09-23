#!/usr/bin/env bash
# pi-gateway-backup -- nightly backup of the Pi gateway stack.
#
# Produces one archive: $BACKUP_DIR/pi-gateway-<timestamp>.tar.gz containing
#   pihole-teleporter.zip   Pi-hole's own export (settings, adlists, groups,
#                           clients, local DNS). Restore via web UI or CLI.
#   uptime-kuma.tar.gz      Uptime Kuma data dir (monitors, history)
#   stack-config.tar.gz     compose file, .env, unbound.conf as deployed
#
# Managed by Ansible (roles/backup). Run by hand any time:
#   sudo /usr/local/sbin/pi-gateway-backup
set -Eeuo pipefail

# Defaults; /etc/default/pi-gateway-backup (Ansible-managed) overrides them.
STACK_DIR="/opt/pi-gateway"
BACKUP_DIR="/var/backups/pi-gateway"
RETENTION_DAYS="14"
# shellcheck source=/dev/null
[[ -r /etc/default/pi-gateway-backup ]] && . /etc/default/pi-gateway-backup

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

umask 077
ts="$(date +%Y%m%d-%H%M%S)"
work="$(mktemp -d)"
kuma_stopped=0

cleanup() {
  # Never leave Uptime Kuma stopped, even if something above failed.
  if [[ $kuma_stopped -eq 1 ]]; then
    docker compose --project-directory "$STACK_DIR" start uptime-kuma >/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# 1) Pi-hole Teleporter export. It writes a zip with a generated name into
#    the current directory, so run it in a scratch dir and stream it out.
log "exporting Pi-hole teleporter archive"
docker exec pihole sh -c \
  'd=$(mktemp -d) && cd "$d" && pihole-FTL --teleporter >/dev/null && cat ./*.zip; rc=$?; rm -rf "$d"; exit $rc' \
  > "$work/pihole-teleporter.zip"
[[ -s "$work/pihole-teleporter.zip" ]] || { log "ERROR: teleporter export is empty"; exit 1; }

# 2) Uptime Kuma: stop briefly so the SQLite files are consistent on disk.
log "backing up Uptime Kuma data"
docker compose --project-directory "$STACK_DIR" stop uptime-kuma >/dev/null
kuma_stopped=1
tar -C "$STACK_DIR/data" -czf "$work/uptime-kuma.tar.gz" uptime-kuma
docker compose --project-directory "$STACK_DIR" start uptime-kuma >/dev/null
kuma_stopped=0

# 3) Deployed stack config (includes .env -> the archive is secret).
log "backing up stack config"
tar -C "$STACK_DIR" -czf "$work/stack-config.tar.gz" \
  docker-compose.yml .env unbound

# Bundle, then prune old archives.
out="$BACKUP_DIR/pi-gateway-$ts.tar.gz"
tar -C "$work" -czf "$out.partial" .
mv "$out.partial" "$out"
log "wrote $out ($(du -h "$out" | cut -f1))"

find "$BACKUP_DIR" -maxdepth 1 -name 'pi-gateway-*.tar.gz' -type f \
  -mtime +"$RETENTION_DAYS" -print -delete | sed 's/^/pruned /'

log "done"
