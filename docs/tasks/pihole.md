# pihole - network-wide ad blocker

Installs [Pi-hole](https://pi-hole.net/) so every device that uses the Pi as
its DNS server gets ads and trackers blocked. Installs without Pi-hole's
dialogs, using the settings below.

```bash
sudo bash setup.sh pihole
```

The official installer from `https://install.pi-hole.net` runs as root, like
`curl ... | bash`, but saved to a file first (so a cut-off download never runs)
and with its SHA-256 in the log. The task prints a warning first and asks no
question; leave `pihole` out of the run, or use `PIHOLE_DOCKER=yes`, if you
do not want the installer to run.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `PIHOLE_PASSWORD` | empty: generated | Web admin password. Empty: generated on the first install, printed once and saved. Set it later to change the password on the next run. |
| `PIHOLE_INTERFACE` | the default route's | Interface Pi-hole answers on, e.g. `eth0` or `wlan0`. Install only. |
| `PIHOLE_DNS` | `1.1.1.1,1.0.0.1` | Upstream DNS servers, comma separated: IPv4 or IPv6 addresses, each with an optional `#port` (e.g. `1.1.1.1#5353`). Install only. |
| `PIHOLE_QUERY_LOGGING` | `yes` | Log DNS queries. Install only. |
| `PIHOLE_WEB_PORT` | `80`, or `8080` if port 80 is taken | HTTP port of the web admin. Re-runs move it when you change it; Pi-hole's HTTPS listener on 443 stays as it is. The `web` task moves the admin page from 80 to this port (`8080` when empty), so set `80` only to keep the start page off port 80. |
| `PIHOLE_LISTEN_ALL` | empty: leave as it is | `yes`: answer DNS queries from any network, e.g. your tailnet (only safe behind a firewall). `no`: only from local subnets. Applied on every run. |
| `PIHOLE_DB_INTERVAL` | `300` | Seconds between Pi-hole's writes of new queries to its database, from 60 to 3600 (Pi-hole's own default is 60). Fewer writes spare the SD card; the web UI still shows the newest queries from memory, and a power cut loses at most this much of the query log. Applied on every run. |
| `PIHOLE_DOCKER` | `no` | `yes` runs Pi-hole in its own Docker container instead of the installer ([below](#run-it-in-docker)). |
| `PIHOLE_IMAGE` | `pihole/pihole:latest` | Docker image for `PIHOLE_DOCKER=yes`. |

"Install only" settings are written to `/etc/pihole/pihole.toml` before the
first install; afterwards change them in Pi-hole's web UI. In Docker they
apply on every run instead.

## Reach it

- Web admin: `http://<pi>/admin`, or `http://<pi>:8080/admin` together with
  the `web` task, whose start page takes port 80. The task prints the address.
- Generated password: printed once and kept in
  `/var/lib/rpi-setup/secrets/pihole.env` (root only). The native install
  sets it with `pihole setpassword <password>`, so it is on that command's
  line for a moment (visible in `ps` to other local users; Pi-hole's own
  script passes it on the same way). Change it later with `pihole
  setpassword` without an argument, which asks for it.
- To use it, set your router's DNS server (DHCP option) to the Pi's address.
  A fixed address helps: see the [network](network.md) task.

## Run it in Docker

With `PIHOLE_DOCKER=yes` the task runs Pi-hole's official image
(`PIHOLE_IMAGE`) in a container named `pihole` on the host network, so it
gets port 53 and sees the real client addresses. Docker is installed first if
it is missing, and the `curl | bash` installer is not used.

- Pi-hole's data (`/etc/pihole`) lives in `/opt/pihole/etc-pihole`.
- All `PIHOLE_*` settings are passed to the container and apply on every run;
  Pi-hole's web UI shows them read-only.
- A native Pi-hole is stopped and its lists, settings and password are copied
  over once (after the image was pulled and with FTL stopped, so the
  databases are copied whole). If the container does not stay up, the native
  Pi-hole is started again. `PIHOLE_DOCKER=no` switches back.
- Update with `sudo bash update.sh` (pulls the new image); `pihole -up` is for
  the native install only.
- The `firewall` task (DNS, admin port, DHCP), `check.sh` and the `backup`
  task recognise the container.

## Good to know

- Pi-hole and nginx (`web`) can run together: the start page gets port 80
  and Pi-hole's admin page moves to `PIHOLE_WEB_PORT` (default `8080`),
  whichever task runs first.
- Pi-hole needs port 53 and does not install inside a container (CI skips it).
- Update with `sudo bash update.sh` (runs `pihole -up`). Debug with
  `pihole -d`. Remove with `pihole uninstall`.
- With the `firewall` task, DNS (53) is open to everyone and the admin UI only
  to `FIREWALL_ALLOW_FROM`; DHCP ports are opened when Pi-hole's DHCP server is on.
