# Pi Gateway

Infrastructure-as-code for a single Raspberry Pi 4 acting as a home network
gateway:

- **Pi-hole** blocks ads and trackers for every device on the LAN, using
  **Unbound** as its own recursive resolver (no Google or Cloudflare upstream).
- **Tailscale** runs as an **exit node** and **subnet router**, so your phone
  or laptop anywhere can browse from your home IP and reach LAN devices.
  Nothing is port-forwarded.
- **Watchtower** picks up rebuilt images; **Uptime Kuma** monitors it all.
- **fail2ban**, **unattended security upgrades**, and **nightly backups**
  keep maintenance low.

Everything is driven from Git: Ansible configures the host, Docker Compose
runs the services, and GitHub Actions lints every change and deploys when you
ask it to.

Guides:
- [MVP-RUNBOOK.md](MVP-RUNBOOK.md): day-2 operations (monthly checks, key
  rotation, restore, rollback)
- [docs/SMART-TVS.md](docs/SMART-TVS.md): blocklists, getting TVs onto
  Pi-hole, and quick fixes when a device misbehaves
- [docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md): using the homelab and your
  home connection from your phone

---

## Architecture

```
                         ┌──────────────────── Raspberry Pi 4 ─────────────────────┐
                         │  HOST (Ansible)                                          │
 LAN clients ──DNS:53──▶ │   tailscaled ◀── exit node + subnet router (IP fwd on)   │
                         │   fail2ban · unattended-upgrades · backup cron · sshd    │
 Tailnet clients ──────▶ │                                                          │
  (phone on LTE)         │  DOCKER (Compose)                                        │
                         │   ┌───────────────┐ 127.0.0.1:5335 ┌──────────────┐      │
                         │   │ pihole (host  │ ─────────────▶ │ unbound      │ ──▶ root/TLD/
                         │   │ network) :53  │                │ (bridge)     │     authoritative
                         │   │ :80 web UI    │                └──────────────┘     servers
                         │   └───────────────┘                                      │
                         │   uptime-kuma :3001        watchtower (docker.sock)      │
                         └──────────────────────────────────────────────────────────┘
```

### Why the split between Ansible and Compose

| Layer | Runs as | Why |
|---|---|---|
| Docker Engine, Tailscale, fail2ban, unattended-upgrades, IP forwarding, backup cron | Host packages via **Ansible** | They need the kernel, the host routing table, iptables, or the journal. Putting them in containers adds workarounds and gains nothing. |
| Pi-hole, Unbound, Watchtower, Uptime Kuma | Containers via **Compose** | Official images; upgrading is a tag bump and rolling back is a revert. |

### Pi-hole networking

Pi-hole uses `network_mode: host`. With bridge networking and `-p 53:53`,
Docker NATs every client, so Pi-hole sees them all as `172.17.0.1`. Per-device
stats and group rules then stop working, and some clients misbehave.

**Documented alternative (not implemented): macvlan.** A macvlan network gives
the Pi-hole container its own LAN IP (a spare address outside the DHCP range). You'd use it if
something else on the Pi needs ports 53/80/443. Trade-offs: the host can't
talk to a macvlan container without an extra shim interface, you have to
reserve the IP outside your router's DHCP range, and Tailscale subnet routing
to it needs care. For a dedicated Pi, host mode is simpler.

Unbound stays on a bridge network published **only on `127.0.0.1:5335`**. Pi-hole
can reach it from the host; LAN clients can't, so they can't get around the
blocking.

---

## Assumptions

Check these against your setup. `make discover` (below) confirms most of them.

| # | Assumption | Where to change it |
|---|---|---|
| 1 | Raspberry Pi 4, 4–8 GB RAM, **64-bit** Raspberry Pi OS Lite (Debian 12 Bookworm or 13 Trixie). Ubuntu arm64 should also work but hasn't been tested. 32-bit OS is refused. | `ansible/playbook.yml` preflight |
| 2 | LAN subnet is `192.168.1.0/24`. The Pi's address is **not in the repo**; you set it per shell with `export PI_HOST=...`. | `ansible/group_vars/gateway/main.yml` (subnet) |
| 3 | The Pi keeps its IP through a **DHCP reservation on your router** (a manual step on your side). This repo does not set a static IP. | — |
| 4 | Login user is `pi` with **passwordless sudo** (the Raspberry Pi Imager default). If sudo asks for a password, add `-K` to local runs. CI needs passwordless sudo. | `inventory.ini` |
| 5 | Fresh or near-fresh OS: no Docker yet, no bare-metal Pi-hole. If there is one, the playbook **stops** and tells you rather than removing anything. | — |
| 6 | Timezone `Etc/UTC`. | `group_vars/gateway/main.yml` |
| 7 | GitHub repo may be **public**. No secret is ever committed; all of them go in GitHub Secrets or local env vars. | — |
| 8 | Nothing is port-forwarded to the Pi, now or later. Pi-hole answers DNS on every interface so tailnet clients work, and that's only safe behind NAT. | — |

---

## Step 0: SSH key access (skip if `ssh pi@$PI_HOST` already works without a password)

On your workstation:

```bash
export PI_HOST=<Pi's LAN IP>                  # every shell; never committed
ssh-keygen -t ed25519 -C "you@workstation"   # accept defaults, set a passphrase
ssh-copy-id pi@$PI_HOST                    # last time you type the Pi's password
```

The playbook **disables SSH password login**, which is why this comes first.

---

## First deploy (from your workstation, on the home LAN)

```bash
export PI_HOST=<Pi's LAN IP>     # never committed; put it in your shell profile if you like
make setup                       # local venv: pinned ansible-core, ansible-lint, collections
make discover | tee discovery-$(date +%F).txt   # READ-ONLY; review the output

export PIHOLE_WEBPASSWORD='choose-a-strong-password'   # no single quotes in it
export TS_AUTHKEY='tskey-auth-...'   # one-off, NON-reusable key: admin console > Settings > Keys

make check                       # dry run -- read the diff; nothing changes
make deploy                      # apply
make validate                    # read-only health check on the Pi
```

Then do the two steps that can't be automated:

1. **Approve routes.** Go to <https://login.tailscale.com/admin/machines>, open
   `pi-gateway`, choose *Edit route settings*, and enable **Use as exit node**
   and the **192.168.1.0/24** subnet.
2. **Disable key expiry** on the same machine page. Otherwise the Pi drops off
   the tailnet after 180 days.

`make validate` shows `WARN` until both are done.

**Expected `--check` behaviour on a brand-new Pi:** tasks that need Docker or
Tailscale installed show as *skipped*, not *changed*. Check mode can't install
a package and then inspect it. This is expected; the real run installs them.

### After it works: point your network at it (manual, your call)

This repo **never touches your router**. When `make validate` is green:

- **LAN-wide blocking:** set your router's DHCP DNS server to the Pi's LAN IP.
  Keep your router's own DNS as a fallback only if you accept that some
  queries will skip Pi-hole.
- **Remote blocking (optional):** in the Tailscale admin console under *DNS*,
  add the Pi's Tailscale IP as a nameserver and enable *Override local DNS*.
  The Pi itself runs with `--accept-dns=false`, so it won't loop through itself.

---

## CI/CD setup

### What runs when

| Workflow | Trigger | Touches the Pi? |
|---|---|---|
| `lint.yml` | every push and PR | No. yamllint, ansible-lint (production profile), playbook syntax check, shellcheck, `docker compose config`, a check that rejects unpinned image tags, hadolint (only once a Dockerfile exists) |
| `deploy.yml` | **manual only** (Actions → deploy → Run workflow) | Yes. lint, then `--check --diff`, then (only if you picked `check-then-apply`) an approval pause, then apply |

There's no auto-deploy on merge. There's one live host and no staging, so a
person decides when to deploy.

### How CI reaches the Pi, and the trade-off

The Pi has no public port, so any CI runner has to **join the tailnet**. A
Tailscale credential is needed either way. The real choice is how to
authenticate SSH once the runner is on the tailnet:

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A. Tailscale OAuth client + dedicated SSH deploy key** (implemented) | The runner joins as an ephemeral `tag:ci` node, then uses normal SSH with a key you authorized on the Pi | One SSH auth path for you and CI, so sshd hardening and fail2ban cover both. Works the same locally. The OAuth client never expires (auth keys expire after at most 90 days). Ephemeral nodes clean themselves up. | Two secrets to manage (OAuth client and SSH key) |
| B. Tailscale SSH | The tailnet policy allows `tag:ci` to SSH as `pi`, with no SSH key at all | One fewer secret | A second SSH auth system that bypasses sshd config and fail2ban. You have to learn the SSH policy syntax. Works differently from your laptop. |
| C. Plain auth key instead of OAuth | Same as A, using a reusable auth key | Fewest clicks | The key expires, so CI breaks every ≤90 days. A reusable key is more valuable if it leaks. |

Option A is the easiest to get right and the most like a real team setup.
Later upgrade: Tailscale **workload identity federation** (GitHub OIDC, the
action's `audience` input) removes the OAuth secret entirely.

### One-time setup

1. **Tailnet policy** (admin console → *Access controls*). Editing the policy
   changes access for your whole tailnet, so review before saving. Minimal
   additions:

   ```jsonc
   "tagOwners": { "tag:ci": ["autogroup:admin"] },
   "hosts":     { "pi-gateway": "100.x.y.z" },   // the Pi's Tailscale IP
   "grants": [
     // keep whatever you have for your own devices, e.g. the default:
     { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] },
     { "src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"] },
     // CI runners may reach ONLY the Pi, ONLY on SSH:
     { "src": ["tag:ci"], "dst": ["pi-gateway"], "ip": ["tcp:22"] },
   ],
   ```

   If your policy is still the default allow-all, `tag:ci` can reach
   everything until you add something like the rule above.

2. **OAuth client** (admin console → *Settings → OAuth clients*): scope
   **Auth Keys (write)**, tag `tag:ci`.

3. **Deploy SSH key.** Generate it on your workstation and never reuse your
   personal key:

   ```bash
   ssh-keygen -t ed25519 -f pi-gateway-deploy -C github-actions-deploy -N ''
   # Authorize it on the Pi, restricted to tailnet source addresses:
   echo "from=\"100.64.0.0/10\" $(cat pi-gateway-deploy.pub)" | ssh pi@$PI_HOST 'cat >> ~/.ssh/authorized_keys'
   ```

4. **Pin the Pi's host key.** Take the fingerprint from the Pi directly, then
   compare it with what the network returns:

   ```bash
   ssh pi@$PI_HOST 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
   ssh-keyscan -t ed25519 100.x.y.z | tee known_hosts.ci | ssh-keygen -lf -   # must match
   ```

5. **GitHub → Settings → Secrets and variables → Actions.**

   | Kind | Name | Value |
   |---|---|---|
   | Secret | `TS_OAUTH_CLIENT_ID` | from step 2 |
   | Secret | `TS_OAUTH_SECRET` | from step 2 |
   | Secret | `DEPLOY_SSH_KEY` | contents of `pi-gateway-deploy` (the private key) |
   | Secret | `PI_SSH_KNOWN_HOSTS` | contents of `known_hosts.ci` |
   | Secret | `PIHOLE_WEBPASSWORD` | same as your local export |
   | Secret | `PI_TAILSCALE_HOST` | the Pi's Tailscale IP (a secret so it's masked in public logs) |

   Then delete `pi-gateway-deploy` and `known_hosts.ci` from your workstation
   (or put them in your password manager). `.gitignore` covers them, but don't
   rely on that.

6. **Approval gate** (Settings → Environments → New environment `production`):
   add yourself as a *Required reviewer*. Required reviewers are free on
   public repos. On a private repo they need GitHub Pro or Team; without them
   `apply` runs straight after `check`, and the only gate left is choosing
   `check-then-apply` when you trigger the workflow.

`TS_AUTHKEY` is **not** a CI secret. It's only used for the Pi's first join,
which happens from your workstation. If CI can reach the Pi at all, the Pi is
already logged in.

### Public-repo safety notes

This repo is public, so **nothing site-specific is committed**:

- The Pi's LAN address comes from `PI_HOST` in your shell, and its Tailscale
  address from a GitHub secret. Neither is written in any file.
- Passwords and keys are only ever environment variables or GitHub Secrets.
  `.gitignore` covers `.env`, deploy keys, and `discovery-*.txt`.
- **GitHub Actions logs are world-readable on public repos.** Secrets are
  masked in them, and the task that renders `.env` runs with `no_log`. Don't
  add `-v` to the deploy workflow, because it prints task arguments.
- `apply` only runs from `main`. `check-only` can run from any branch, so you
  can preview a change before merging it.
- Don't paste `make discover` or `make validate` output into issues or PRs.
  It contains your addresses and service list.

- Pull requests from forks run `lint` with **no access to secrets**, which is
  GitHub's default. `deploy.yml` has no `pull_request` trigger, and only users
  with write access can run `workflow_dispatch`.
- Third-party actions are pinned to a **commit SHA**, not a movable tag.
  Dependabot proposes updates.

---

## Upgrades

- **Container images** are pinned to exact versions. Dependabot opens a PR
  for each bump; CI lints it; you merge it and run `deploy`. Watchtower only
  refreshes **the same tag** if it's republished (e.g. a security rebuild),
  checking Sundays at 04:00. It never jumps versions.
- **OS updates** (Debian security and stable point releases, plus the
  Raspberry Pi archive) install automatically; the Pi **does not reboot
  itself** (see the runbook).
- **Docker and Tailscale packages** are left out of unattended-upgrades on
  purpose, because upgrading them restarts DNS or drops remote sessions. Update
  them on your schedule (runbook, *Monthly*).

---

## Repository layout

```
ansible/
  ansible.cfg, inventory.ini, requirements.yml, playbook.yml
  group_vars/gateway/
    main.yml                 # the settings you edit
    pihole.yml               # blocklists + allow/deny domains (synced via Pi-hole API)
  roles/
    hardening/   sshd key-only, fail2ban, unattended-upgrades
    docker/      Docker Engine + compose plugin (official repo), log rotation
    tailscale/   exit node + subnet router, IP forwarding, idempotent prefs, UDP GRO tuning
    stack/       deploys docker/ to /opt/pi-gateway, `compose up --wait`, syncs Pi-hole lists
    backup/      nightly teleporter + data backup, 14-day retention
docs/
  SMART-TVS.md, REMOTE-ACCESS.md
docker/
  docker-compose.yml, .env.example
  pihole/README.md           # config-as-code via FTLCONF_* env vars
  unbound/unbound.conf
scripts/
  discover.sh                # read-only pre-flight facts
  validate.sh                # read-only post-deploy checks
.github/
  workflows/lint.yml, workflows/deploy.yml
  actions/ansible-runner/    # shared setup for deploy jobs
  dependabot.yml
```

`stack` is a fifth role beyond the original four. Deploying the Compose
project is a different job from installing Docker, and keeping them separate
means `--tags stack` redeploys the services without touching the engine.

## Not automated (on purpose)

- Router DHCP, DNS, and port forwarding: always manual, always your call.
- Tailscale route approval and key-expiry toggle: admin-console clicks (or
  `autoApprovers` in your tailnet policy if you tag the Pi).
- Uptime Kuma monitors: it has no declarative config. Suggested monitors:
  DNS `example.com` via `host.docker.internal:53`, HTTP
  `http://host.docker.internal/admin/`, and TCP `host.docker.internal:5335`.
- Off-Pi backup copies: see the runbook.
