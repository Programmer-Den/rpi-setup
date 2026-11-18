# gateway - HTTPS gateway to an app in the LAN

The only way in from the internet for one of your apps that runs on another
machine in your network (a VM, a NAS, a second computer). It runs
[Caddy](https://caddyserver.com) in Docker, which answers HTTPS on port 443
with a certificate from Let's Encrypt and passes every request on to the app,
encrypted again, trusting only the app's own (pinned) certificate.

```bash
sudo bash setup.sh gateway
```

Needs Docker (the task runs the `docker` task first when it is missing),
`GATEWAY_DOMAIN` and `GATEWAY_UPSTREAM`. The menu's `all` leaves it out; pick
it by number or by name. If the container does not stay up, its last log lines
are shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `GATEWAY_DOMAIN` | required | Public name of the Pi, such as `app.example.org` or the dynamic DNS name your router offers. It must point to the router's public address. |
| `GATEWAY_UPSTREAM` | required | Address of the machine the app runs on, such as `192.168.1.30`. |
| `GATEWAY_UPSTREAM_PORT` | `443` | The app's HTTPS port on that machine. |
| `GATEWAY_UPSTREAM_NAME` | empty: `GATEWAY_UPSTREAM` | Name in the app's certificate, when it is not the address itself, such as `app`. Sent to the app as the TLS server name and checked against its certificate. |
| `GATEWAY_UPSTREAM_FINGERPRINT` | empty: the first one seen | SHA-256 fingerprint of the app's certificate, with or without colons. Empty: the certificate the app shows on the first run is pinned and its fingerprint printed, to compare. A new value pins the app's new certificate (see below). |
| `GATEWAY_EMAIL` | empty | Email address Let's Encrypt writes to before a certificate expires (Caddy renews on its own, so this only matters when that fails). No account is made. |
| `GATEWAY_IMAGE` | `caddy:2` | Docker image of Caddy. |

## What it installs and changes

- `/opt/gateway/`: `docker-compose.yml`, `Caddyfile`, `upstream-cert.pem`
  (the app's certificate, which is public), and `data/` with the certificate
  from Let's Encrypt and its key.
- The `gateway` container: the host's network (so it sees the clients' real
  addresses and needs no published port), read-only file system, every
  capability dropped except binding port 443, restarts on its own, no admin
  API.
- With the `firewall` task: 443/tcp open to anyone.

## Before the first run

1. The app must answer HTTPS on its machine. A self-signed certificate is
   fine; it is pinned. Let the Pi through that machine's firewall, and give the
   Pi and the machine fixed addresses in the router.
2. In the router: forward TCP 443 to the Pi, and set up the name in
   `GATEWAY_DOMAIN`, such as the router's own dynamic DNS.
3. On the app's machine, print its certificate's fingerprint and put it into
   `GATEWAY_UPSTREAM_FINGERPRINT`:

   ```bash
   openssl x509 -noout -fingerprint -sha256 -in cert.pem
   ```

App-specific values (address, port, certificate name and fingerprint) belong
in your own settings file, not in this repository.

## How it works

- Let's Encrypt checks the name over port 443 itself (TLS-ALPN), so port 80
  stays free for the `web` task or Pi-hole, and nothing redirects from it.
  Until the name points to the router and 443 is forwarded, Caddy keeps
  trying; `docker logs gateway` says why. Caddy renews the certificate on its
  own.
- Requests go to `https://GATEWAY_UPSTREAM:GATEWAY_UPSTREAM_PORT` and are
  accepted only with the pinned certificate, for the name in
  `GATEWAY_UPSTREAM_NAME` (or the address). An app that shows another
  certificate gets no request.
- Caddy sets `X-Forwarded-For` to the client's address and ignores one the
  client sends, so an app that trusts the Pi as its proxy sees the real
  address (for example for a login limit).
- The task ends by asking the app for `/` through the pinned certificate and
  warns when it does not answer yet.

## Good to know

- New certificate on the app: put its fingerprint into
  `GATEWAY_UPSTREAM_FINGERPRINT` and run the task again. Without the setting,
  the pinned one stays until you delete `/opt/gateway/upstream-cert.pem`.
- Port 443 must be free. Pi-hole's admin page also listens there for HTTPS:
  the task keeps it on plain HTTP (on the host or in its container), and the
  `pihole` task leaves 443 alone from then on. Another program on 443 stops
  the task.
- Only HTTP/1.1 and HTTP/2: HTTP/3 would need UDP 443 open as well.
- One app per Pi: everything on `GATEWAY_DOMAIN` goes to it.
- A newer Caddy comes with `sudo bash update.sh`; a changed setting with a
  re-run of the task.
- `check.sh` reports the container, port 443 and whether the app answers
  through the pinned certificate.
- Logs: `docker logs gateway`. Stop: `cd /opt/gateway && sudo docker compose down`.
