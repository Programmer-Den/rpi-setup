# dataden - DATA-DEN gateway

The Pi's part of [DATA-DEN](https://github.com/Programmer-Den/DATA-DEN), the
NAS whose storage runs in a VM on another machine: the only way in from the
internet. It runs [Caddy](https://caddyserver.com) in Docker, which answers
HTTPS on port 443 with a certificate from Let's Encrypt and passes every
request on to DATA-DEN in the VM, encrypted again.

```bash
sudo bash setup.sh dataden
```

Needs Docker (the task runs the `docker` task first when it is missing),
`DATADEN_DOMAIN` and `DATADEN_VM`. The menu's `all` leaves it out; pick it by
number or by name. If the container does not stay up, its last log lines are
shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `DATADEN_DOMAIN` | required | Public name of the Pi, such as `nas.example.org` or the dynamic DNS name your router offers. It must point to the router's public address. |
| `DATADEN_VM` | required | Address of the storage VM, such as `192.168.1.30`. |
| `DATADEN_VM_PORT` | `8443` | DATA-DEN's HTTPS port in the VM. |
| `DATADEN_VM_FINGERPRINT` | empty: the first one seen | SHA-256 fingerprint of the VM's certificate, with or without colons. Empty: the certificate the VM shows on the first run is pinned and its fingerprint printed, to compare. A new value pins the VM's new certificate (see below). |
| `DATADEN_EMAIL` | empty | Email address Let's Encrypt writes to before a certificate expires (Caddy renews on its own, so this only matters when that fails). No account is made. |
| `DATADEN_IMAGE` | `caddy:2` | Docker image of Caddy. |

## What it installs and changes

- `/opt/dataden/`: `docker-compose.yml`, `Caddyfile`, `vm-cert.pem` (the
  VM's certificate, which is public), and `data/` with the certificate from
  Let's Encrypt and its key.
- The `dataden` container: the host's network (so it sees the clients' real
  addresses and needs no published port), read-only file system, every
  capability dropped except binding port 443, restarts on its own, no admin
  API.
- With the `firewall` task: 443/tcp open to anyone.

## Before the first run

1. Set up the storage VM and DATA-DEN in it (DATA-DEN's `vm/README.md` and
   `deploy/README.md`), with this Pi's address in its firewall and in
   `DATA_DEN_TRUSTED_PROXY`. Give the Pi and the VM fixed addresses in the
   router.
2. In the router: forward TCP 443 to the Pi, and set up the name in
   `DATADEN_DOMAIN`, such as the router's own dynamic DNS.
3. In the VM's DATA-DEN folder, print the certificate's fingerprint and put it
   into `DATADEN_VM_FINGERPRINT`:

   ```bash
   openssl x509 -noout -fingerprint -sha256 -in tls/cert.pem
   ```

## How it works

- Let's Encrypt checks the name over port 443 itself (TLS-ALPN), so port 80
  stays free for the `web` task or Pi-hole, and nothing redirects from it.
  Until the name points to the router and 443 is forwarded, Caddy keeps
  trying; `docker logs dataden` says why. Caddy renews the certificate on its
  own.
- Requests go to `https://DATADEN_VM:DATADEN_VM_PORT` and are accepted only
  with the pinned certificate (name `data-den`, as DATA-DEN's guide makes
  it). A VM that shows another certificate gets no request.
- Caddy sets `X-Forwarded-For` to the client's address and ignores one the
  client sends, so DATA-DEN's login limit sees the real address
  (`DATA_DEN_TRUSTED_PROXY` must be the Pi's address).
- The task ends by asking DATA-DEN's `/api/health` through the pinned
  certificate and warns when the VM does not answer yet.

## Good to know

- New certificate in the VM: put its fingerprint into
  `DATADEN_VM_FINGERPRINT` and run the task again. Without the setting, the
  pinned one stays until you delete `/opt/dataden/vm-cert.pem`.
- Port 443 must be free. Pi-hole's admin page also listens there for HTTPS;
  the task stops with the command that keeps it on plain HTTP.
- A newer Caddy comes with `sudo bash update.sh`; a changed setting with a
  re-run of the task.
- `check.sh` reports the container, port 443 and whether DATA-DEN in the VM
  answers through the pinned certificate.
- Logs: `docker logs dataden`. Stop: `cd /opt/dataden && sudo docker compose down`.
