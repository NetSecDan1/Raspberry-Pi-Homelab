# Using the home network from your phone

Tailscale on the Pi gives you two separate things. You can use either one or
both:

| Feature | What it does | Phone setting |
|---|---|---|
| **Subnet route** | Reach devices at home by their LAN IP: Pi-hole admin, Uptime Kuma, a NAS, a printer, homelab services | Just be connected to Tailscale |
| **Exit node** | Send *all* your phone's internet traffic through home, so you browse from your home IP | Exit node → `pi-gateway` |

Nothing is port-forwarded. Your phone reaches the Pi over an encrypted
WireGuard tunnel that Tailscale sets up.

## One-time setup

1. Finish the admin-console steps from the README: approve the exit node and
   the subnet route, and disable key expiry for `pi-gateway`.
2. Install the **Tailscale** app on the phone and sign in with the **same
   account** as the tailnet.
3. The phone shows up in the admin console's machine list. That's it.

## Reach the homelab (no exit node needed)

With Tailscale connected, these work from anywhere as if you were at home:

- Pi-hole admin: `http://<pi-lan-ip>/admin`, or `http://pi-gateway/admin` via
  MagicDNS
- Uptime Kuma: `http://<pi-lan-ip>:3001`
- Anything else on your LAN, by its LAN IP

It's plain `http://`, but the traffic is inside the WireGuard tunnel, so it's
encrypted end to end between your phone and home.

## Browse from home (exit node)

In the app: **Exit node → pi-gateway**. All traffic now leaves from your home
connection.

- Turn on **Allow local network access** if you still need the network
  you're physically on, such as a hotel login page or a printer.
- Good for untrusted Wi-Fi, and for services that check only your IP address.
- Costs: some battery, and you're limited by your **home upload speed**
  (next section).

## Streaming through home: what to expect

**Speed ceiling = your home upload speed.** Everything you watch is
downloaded by the Pi, then *uploaded* from home to your phone. YouTube
suggests roughly 7 Mbps for one HD stream. Run a speed test at home: fiber
with symmetric upload is plenty; a connection with a few Mbps of upload will
buffer.

**Direct vs relayed.** In the Tailscale app, tap `pi-gateway`. A **direct**
connection is fast. **Relayed (DERP)** means NAT on one side prevented a
direct path, and throughput drops a lot. Most home gateways allow direct
connections. If yours is always relayed, the fix involves router settings,
so we'd discuss it first. The Pi is already tuned for exit-node throughput
(UDP GRO forwarding, see `make validate`).

**YouTube TV specifics:**
- Nationwide channels and your DVR library play anywhere in the US either way.
- For **local channels on mobile**, YouTube TV uses your **phone's
  location** as well as your IP address. So on the exit node you may still
  see local channels for where you physically are, not your home market.
  That's expected.
- Your **home area** is anchored by periodically using YouTube TV at home on
  a living-room device, and you can only change it a limited number of times
  a year. Don't burn changes experimenting.
- Tricks to fake the phone's location are against YouTube TV's terms and
  risk the account. This setup doesn't go there.

## Ad blocking on the phone, anywhere (optional)

Admin console → **DNS** → *Add nameserver* → the Pi's **Tailscale IP** →
enable **Override local DNS**. Every device on your tailnet then uses Pi-hole
whenever Tailscale is connected, with or without the exit node. The Pi itself
runs with `--accept-dns=false`, so it never loops through itself.

If Pi-hole is down, tailnet devices lose DNS while Tailscale is connected.
Disconnect Tailscale, or remove the override, to get back online.

## If the phone is lost

Admin console → *Machines* → the phone → **Remove**. Its access ends
immediately; nothing on the Pi needs to change.
