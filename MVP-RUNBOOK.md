# MVP Runbook — Pi Gateway

What to run, when, what "good" looks like, and what to do when it isn't.
Commands marked **(Pi)** run over SSH on the Pi; everything else runs from
your workstation in the repo root.

---

## Quick reference

| Task | Command | Changes anything? |
|---|---|---|
| Health check | `make validate` | No |
| Preview a deploy | `make check` (or Actions → deploy → `check-only`) | No |
| Deploy | `make deploy` (or Actions → deploy → `check-then-apply`) | Yes |
| Redeploy only containers | `make check TAGS=stack` then `make deploy TAGS=stack` | Yes: containers only |
| Manual backup **(Pi)** | `sudo /usr/local/sbin/pi-gateway-backup` | Writes one archive |
| Container status **(Pi)** | `sudo docker compose --project-directory /opt/pi-gateway ps` | No |
| Container logs **(Pi)** | `sudo docker compose --project-directory /opt/pi-gateway logs --tail 100 pihole` | No |

---

## Validation after every deploy

`make validate` runs all of these; the table shows how to read the results.

| Check | Good | Bad → first thing to look at |
|---|---|---|
| Containers | all `running/healthy` (watchtower: `running/no-healthcheck`) | `docker compose logs <name>` |
| Unbound recursion | `dnssec.works` resolves | Unbound logs; is the Pi online? `ping -c3 1.1.1.1` |
| DNSSEC negative | `fail01.dnssec.works` → `SERVFAIL` | If it resolves, validation is broken: check `unbound.conf` |
| Pi-hole on LAN IP | `example.com` resolves via the Pi's LAN IP | `ss -lnup \| grep :53`; is anything else on 53? |
| Blocking | a gravity domain → `0.0.0.0` | Empty gravity on first boot is normal for a few minutes; otherwise Pi-hole UI → Adlists → update gravity |
| Tailscale | `Running`, exit node advertised **and approved** | WARN = approve in admin console |
| IP forwarding | both sysctls = 1 | `cat /etc/sysctl.d/99-pi-gateway-forwarding.conf` |
| fail2ban | active with `sshd` jail | `sudo journalctl -u fail2ban -n 50` |
| Unattended upgrades | timers enabled, periodic = 1 | `sudo unattended-upgrade --dry-run -d \| tail -30` |
| sshd | `passwordauthentication no` | `sudo sshd -T \| grep -i password` |
| Backups | newest archive < 26 h old | `sudo journalctl -t pi-gateway-backup -n 50` |

Manual end-to-end tests from a client device:

```bash
# On a LAN laptop (point it at the Pi explicitly; no router change needed):
dig @192.168.1.2 example.com +short          # an IP
dig @192.168.1.2 doubleclick.net +short      # 0.0.0.0 if it's on your lists

# On a phone/laptop OFF the home network, with Tailscale on and exit node = pi-gateway:
curl -s https://ifconfig.me                  # must print your HOME public IP
ping 192.168.1.1                             # your router, reached via subnet route
```

A second `make deploy` straight after the first should report **`changed=0`**.
Anything that changes on every run is an idempotency bug; fix it rather than
live with it.

---

## Monthly (≈15 min)

| # | Check | Command | Threshold / action |
|---|---|---|---|
| 1 | Overall health | `make validate` | 0 FAIL. Investigate every WARN. |
| 2 | Pending reboot | **(Pi)** `ls /var/run/reboot-required` | If present: reboot at a quiet time (below). |
| 3 | Disk | **(Pi)** `df -h /` | < 80 % used. Over that: `sudo docker image prune -a` (removes unused images only), check `/var/backups/pi-gateway`. |
| 4 | Temperature | **(Pi)** `vcgencmd measure_temp` | < 70 °C at idle. Above 80 °C the Pi throttles, so improve cooling. |
| 5 | Throttling history | **(Pi)** `vcgencmd get_throttled` | `throttled=0x0`. Anything else points at under-voltage or heat; check the PSU (use the official 5.1 V/3 A). |
| 6 | Docker + Tailscale packages | **(Pi)** `sudo apt update && apt list --upgradable 2>/dev/null \| grep -E 'docker\|containerd\|tailscale'` | If any are listed, upgrade in a quiet window: `sudo apt install --only-upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin tailscale`. DNS drops for ~30 s while dockerd restarts. |
| 7 | Image bumps | GitHub → Pull requests (Dependabot) | Read the release notes, merge, run deploy. |
| 8 | Pull a backup off the Pi | see *Backups* | At least monthly; weekly is better. |
| 9 | fail2ban activity | **(Pi)** `sudo fail2ban-client status sshd` | Bans are fine. Lots of them from LAN or tailnet IPs means something's misconfigured or compromised. |
| 10 | Tailscale machine page | admin console | Key expiry disabled; routes approved; no stray `tag:ci` nodes (they're ephemeral and should disappear). |

**Rebooting safely.** Every LAN device loses DNS for about 60–90 s. Do it
when nobody's on a video call.

```bash
ssh pi@192.168.1.2 'sudo systemctl reboot'
sleep 120 && make validate
```

---

## Rotate the Tailscale auth key

**What the auth key is for:** it's only used when the Pi *joins* the tailnet.
After that, the Pi authenticates with its own node key in `/var/lib/tailscale`.
"Rotating" therefore covers three different things:

**1. The one-off join key you used for the Pi.** If it was non-reusable
(recommended), it's already spent. Revoke it anyway: admin console →
*Settings → Keys* → revoke. Nothing breaks.

**2. Re-authenticating the Pi itself** (after a node-key expiry, moving
tailnets, or suspected compromise):

```bash
# Create a new one-off, non-reusable key in the admin console first.
ssh pi@192.168.1.2 'sudo tailscale logout'          # remote tailnet sessions drop now
export TS_AUTHKEY='tskey-auth-NEW...'
make check TAGS=tailscale && make deploy TAGS=tailscale   # role sees NeedsLogin and re-joins
```

Run this **from the LAN**, since the Pi is off the tailnet between logout and
re-join. Afterwards, re-approve the routes and disable key expiry on the new
machine entry, and delete the old entry. If the Pi's Tailscale IP changed,
also update the `PI_TAILSCALE_HOST` variable, `PI_SSH_KNOWN_HOSTS`, and the
`hosts` entry in your tailnet policy.

**3. The CI credentials** (OAuth client secret, SSH deploy key), yearly or
after any suspected leak:

- *OAuth client:* create a new one (same scope and tag), update
  `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`, run a `check-only` deploy to
  prove it works, then delete the old client.
- *Deploy SSH key:* generate a new key (README → CI/CD setup step 3), append
  it to the Pi's `authorized_keys`, update `DEPLOY_SSH_KEY`, run `check-only`,
  then **remove the old line** from `~/.ssh/authorized_keys` on the Pi.

**Pi-hole password:** update your local `PIHOLE_WEBPASSWORD` export and the
GitHub secret, then `make deploy TAGS=stack`. Pi-hole is recreated with the
new password, which means a few seconds without DNS.

---

## Backups

**What gets backed up nightly at 03:30** to `/var/backups/pi-gateway/`
(root-only, 14-day retention):

| File in archive | Contents |
|---|---|
| `pihole-teleporter.zip` | Pi-hole settings, adlists, groups, clients, allow/deny lists, local DNS |
| `uptime-kuma.tar.gz` | monitors and history (Kuma is stopped for a few seconds for a clean copy) |
| `stack-config.tar.gz` | deployed compose file, `.env` (**contains the Pi-hole password**), unbound.conf |

**Those backups sit on the same SD card they protect.** Pull them off the Pi:

```bash
mkdir -p ~/pi-gateway-backups
ssh pi@192.168.1.2 'sudo tar -C /var/backups/pi-gateway -cf - .' | tar -C ~/pi-gateway-backups -xf -
ls -lt ~/pi-gateway-backups | head
```

Keep the copy somewhere encrypted, since it holds secrets.

### Restore Pi-hole config

```bash
# (Pi) unpack the archive you want
sudo mkdir -p /tmp/restore && sudo tar -xzf /var/backups/pi-gateway/pi-gateway-YYYYMMDD-HHMMSS.tar.gz -C /tmp/restore
```

- **Preferred: web UI.** Copy `/tmp/restore/pihole-teleporter.zip` to your
  laptop (`scp`), open `http://192.168.1.2/admin` → *Settings → Teleporter* →
  *Import*.
- **CLI alternative (Pi):**
  ```bash
  sudo docker cp /tmp/restore/pihole-teleporter.zip pihole:/tmp/tp.zip
  sudo docker exec pihole pihole-FTL --teleporter /tmp/tp.zip
  sudo docker restart pihole
  ```

Settings managed by `FTLCONF_*` in `docker-compose.yml` always win over
imported values. That's intended, because the repo is the source of truth.

### Restore Uptime Kuma

```bash
# (Pi)
cd /opt/pi-gateway
sudo docker compose stop uptime-kuma
sudo tar -xzf /tmp/restore/uptime-kuma.tar.gz -C /tmp/restore
sudo rsync -a --delete /tmp/restore/uptime-kuma/ /opt/pi-gateway/data/uptime-kuma/
sudo docker compose start uptime-kuma
```

### Disaster recovery (dead SD card)

1. Flash 64-bit Raspberry Pi OS Lite with Raspberry Pi Imager. Set the same
   hostname and user, and **enable SSH with your public key** in the Imager
   settings.
2. Boot. The DHCP reservation gives it the same IP.
3. `ssh-keygen -R 192.168.1.2`, then `ssh pi@192.168.1.2` and verify the
   **new** host key fingerprint.
4. Remove the old `pi-gateway` machine in the Tailscale admin console.
5. `export PIHOLE_WEBPASSWORD=... TS_AUTHKEY=<new one-off key>`, then
   `make check && make deploy`.
6. Approve routes and disable key expiry (the admin-console clicks).
7. Restore Pi-hole and Uptime Kuma from your **off-Pi** backup copy (above).
8. Update the `PI_SSH_KNOWN_HOSTS` secret (new host key) and
   `PI_TAILSCALE_HOST` if the IP changed.
9. `make validate`.

---

## Rollback and teardown

Go from least to most drastic. Before any step that stops Pi-hole:
**if your router hands out the Pi as the LAN's DNS server, stopping Pi-hole
takes DNS down for the whole house.** Either change the router's DNS back
first (manual, your call), or accept the outage.

### A deploy failed partway

Ansible stops at the failing task. Everything before it was applied, and
every task is idempotent, so the normal fix is to **read the error, correct
it, and re-run**. Nothing needs undoing first.

- Failed in `stack` with an unhealthy container: `sudo docker compose
  --project-directory /opt/pi-gateway logs --tail 200 <name>`.
- Failed in `tailscale`: `sudo journalctl -u tailscaled -n 100`.

### A new image or config version is bad

```bash
git revert <bad-commit>          # or: git checkout <last-good-tag> -- docker/
git push                         # CI lints the revert
make check TAGS=stack && make deploy TAGS=stack   # or the deploy workflow
```

The previous pinned tag comes back. Watchtower won't "fix" it forward,
because it only follows the tag that's pinned.

### Stop the containers (keep everything on disk)

```bash
# (Pi)
sudo docker compose --project-directory /opt/pi-gateway down     # data in /opt/pi-gateway/data is kept
# bring back:
sudo docker compose --project-directory /opt/pi-gateway up -d --wait
```

### Take Tailscale offline

```bash
# (Pi)
sudo tailscale down      # stops advertising routes/exit node; stays logged in; `tailscale up` resumes
sudo tailscale logout    # fully leaves the tailnet (needs a new auth key to rejoin)
```

Do this **from the LAN**. Running it over a Tailscale SSH session cuts off
the session you're typing in.

### Restore previous Pi-hole config

See *Backups → Restore Pi-hole config*, using the archive from before the
change.

### Full teardown (return the Pi to roughly stock)

Nothing here is automated, on purpose. Run each line deliberately **(Pi)**:

```bash
sudo /usr/local/sbin/pi-gateway-backup                     # last backup first; copy it off the Pi
sudo docker compose --project-directory /opt/pi-gateway down
sudo tailscale logout
sudo rm /etc/cron.d/pi-gateway-backup /usr/local/sbin/pi-gateway-backup /etc/default/pi-gateway-backup
sudo rm /etc/sysctl.d/99-pi-gateway-forwarding.conf && sudo sysctl --system
sudo apt remove tailscale docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
sudo rm /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/tailscale.sources
sudo rm -f /etc/apt/keyrings/docker.* /etc/apt/keyrings/tailscale.*
# Leave the hardening (fail2ban, unattended-upgrades, key-only SSH) in place -- it's good hygiene.
# Only after confirming nothing else is needed:
#   sudo rm -rf /opt/pi-gateway /var/backups/pi-gateway
```
