# Pi-hole configuration

Pi-hole v6 is configured **entirely through `FTLCONF_*` environment variables**
in `../docker-compose.yml`. There are no template files to maintain here,
and that's deliberate: environment variables are declarative, show up in
`git diff`, and anything set that way is locked in the web UI, so the UI
and the repo can't drift apart.

To manage another setting as code, find its dotted name in the web UI under
*Settings → All settings* (e.g. `dns.hosts`), then add it to the `pihole`
service's `environment:` with dots turned into underscores:

```yaml
      # Local DNS records ("IP hostname"; separate multiple with ;)
      FTLCONF_dns_hosts: "<pi-lan-ip> pi-gateway.lan"
```

**Blocklists and allow/deny domains are code too**, but they live in
Pi-hole's database rather than its config, so they're managed differently:
declared in `ansible/group_vars/gateway/pihole.yml` and synced through
Pi-hole's API by the `stack` role (`make deploy TAGS=pihole_lists`). Groups
and client assignments stay in the web UI. The nightly Teleporter backup
captures all of it.

Runtime data (`/etc/pihole` inside the container) lives on the Pi at
`/opt/pi-gateway/data/pihole` and is never committed.
