# Smart TVs and streaming devices

Goal: snappier menus and less background chatter, **without breaking
streaming**. This page covers what's blocked, how to get your TVs using
Pi-hole, what to expect, and how to undo things fast if a device misbehaves.

## What gains to expect

| Gets better | Doesn't change |
|---|---|
| Home screens and menus load faster, because ad tiles and telemetry calls fail instantly instead of loading | Video quality and buffering, which depend on your ISP and Wi-Fi |
| Less background traffic from **ACR** ("automatic content recognition": the TV fingerprinting whatever is on screen, even HDMI inputs, and reporting it) | **YouTube ads.** They come from the same servers as the video, so no DNS blocker can remove them. Lists that claim to break YouTube. |
| Fewer tracking and malware domains reachable from anything on the LAN | Apps that bring their own DNS (see below) |

## What's blocked (`ansible/group_vars/gateway/pihole.yml`)

**On by default (low breakage):**
- **StevenBlack hosts**, Pi-hole's default list.
- **HaGeZi Multi PRO**, the main list. It already includes each TV brand's
  trackers at a "won't break features" level, and blocks the ACR services:
  Samsung (`samsungacr.com`), LG's Alphonso (`alphonso.tv`), Samba TV (used
  by Sony, Sharp and others), plus Roku logging and Amazon device metrics.
- **HaGeZi Threat Intelligence (medium)**, which covers malware, phishing and
  scam domains.

**Off by default (per-brand, more aggressive):** HaGeZi's *full* tracker
lists for Samsung, LG webOS, Roku, and Amazon Fire TV. HaGeZi warns these can
limit some features, such as ad-supported free channels or recommendations.

Before shipping this, I checked every list for the domains that YouTube,
YouTube TV, Netflix playback, and device connectivity checks depend on.
**None of the lists block them.** The only streaming-related entries are
Netflix *telemetry* domains, which are safe to block.

### Turning on a brand's full list

1. In `pihole.yml`, set `enabled: true` on **one** brand you own.
2. Run `make check TAGS=pihole_lists` and confirm the plan shows `update: ...native.<brand>...`.
3. Run `make deploy TAGS=pihole_lists`. Gravity rebuilds in 1–3 minutes, and DNS keeps working meanwhile.
4. Use that TV normally for a few days before enabling the next brand.

## Do this on the TVs too (bigger win than DNS)

Turn off ACR in each TV's settings. It stops the tracking at the source, and
the TV stops retrying blocked domains:

| Brand | Setting (menus move between models) |
|---|---|
| Samsung | Settings → Terms & Privacy → **Viewing Information Services** → off |
| LG | Settings → General → **Live Plus** → off |
| Vizio | Settings → Admin & Privacy → **Viewing Data** → off |
| Roku TV | Settings → Privacy → Smart TV experience → **Use info from TV inputs** → off |
| Sony / others with Samba TV | Settings → **Samba Interactive TV** → off |

## Getting the TVs to use Pi-hole

Nothing is filtered until a device actually asks the Pi for DNS. This repo
never touches your router, so the choice is yours.

**Option A — set DNS on each TV (recommended starting point).**
In the TV's network settings, switch DNS from automatic to manual and set it
to the Pi's LAN IP. Start with **one TV**, live with it for a few days, then
do the rest.
- Leave secondary DNS empty, or set it to the Pi as well. A public secondary
  such as 8.8.8.8 gets used at random and quietly skips Pi-hole.
- If the Pi is ever down, that TV loses DNS. Switch its DNS back to
  automatic until the Pi is back.

**Option B — the router hands out the Pi as DNS (whole house).**
Set your router's DHCP DNS server to the Pi's LAN IP. **Heads-up:** many
ISP-supplied gateways don't let you change the DHCP DNS server. If yours
doesn't, use A, or C below.

**Option C — Pi-hole becomes the DHCP server.** You turn off the router's
DHCP and Pi-hole hands out addresses instead. That's a router change and a
bigger blast radius, so it's a separate, deliberate step. Ask when you want it.

**Devices that bypass Pi-hole anyway.** Chromecast, Google TV, and some apps
have Google's DNS (8.8.8.8) hard-coded. Stopping that takes firewall rules on
the router, so for now those devices simply aren't filtered.

## Something broke: fastest fix first

1. **Unblock the exact domain.** Pi-hole web UI → *Query Log* → filter by
   the TV's IP → find the red "blocked" rows from the moment it failed →
   **Allow**. It takes effect immediately. Then copy that domain into
   `pihole_domains` in `pihole.yml` (the file has an example) so the next
   deploy keeps it.
2. **Take one device out of filtering.** *Groups* → add a group `unfiltered`
   → *Clients* → add the TV's IP → assign it **only** to `unfiltered`
   (remove `Default`). That device skips every list; everything else stays
   filtered.
3. **Pause all blocking.** *Dashboard* → *Disable blocking* → 5 minutes.
   If the problem goes away, it was a block; if not, it's something else.
4. **Undo a list change.** Set `enabled: false` (or revert the commit) and
   run `make deploy TAGS=pihole_lists`.

**"The TV's internet died completely"** usually means the TV tripped
Pi-hole's per-device rate limit while hammering blocked domains. It then gets
refused for *everything* until the window ends. This stack raises the limit
from Pi-hole's default of 1000 to 3000 queries per minute, and `make validate`
warns if any device still trips it. If one does, turn off that TV's ACR
(above), since that's usually what's hammering.

## Measuring it

- Pi-hole dashboard → *Top clients*: each TV's query count and % blocked.
  Expect TVs to show some of the highest block rates on the network.
- Before and after: time how long the TV's home screen takes to fully load
  after waking.
