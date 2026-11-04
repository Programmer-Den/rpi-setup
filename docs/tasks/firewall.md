# firewall - nftables

An opt-in firewall that lets in SSH and the ports of the rpi-setup services
installed on this Pi, and drops everything else that comes in.

```bash
sudo bash setup.sh firewall
```

**Run it last**, and run it again after installing another task so that
task's ports are opened. It looks at what is installed when it runs.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `FIREWALL_SSH_PORT` | `22` | SSH port, always allowed. Every port of sshd's configuration (`sshd -T`), every port sshd listens on and the port of `ssh.socket` (a socket-activated sshd) are allowed too, so a wrong value cannot lock you out. |
| `FIREWALL_AUTO_PORTS` | `yes` | Open the ports of the installed rpi-setup services (table below). `no`: only SSH and `FIREWALL_EXTRA_PORTS`. |
| `FIREWALL_EXTRA_PORTS` | none | More ports open to anyone, as `port/proto` or `from-to/proto`, e.g. `8123/tcp 1900/udp`. |
| `FIREWALL_ALLOW_FROM` | empty: this Pi's own networks | Subnets allowed to reach the LAN services (table below), e.g. `192.168.1.0/24`; several separated by spaces. Empty: the subnets of the Pi's network interfaces (not Docker's), plus IPv6 link-local (`fe80::/10`) and unique local (`fc00::/7`) addresses; the task prints what it found. `any`: anyone. |

## What gets opened

Always allowed: SSH, ping, loopback, mDNS (`<host>.local`), the DHCP client
and replies to connections the Pi started. Containers on Docker's networks
may reach the Pi's DNS (port 53); anything else they send to the Pi is
handled like traffic from the LAN, so a container cannot reach a port the
firewall keeps closed. Everything over Tailscale (`tailscale0`) is allowed
only when Tailscale is installed (by hand).

| Service (when installed, natively or in its container) | Ports | Who may connect |
|--------------------------|-------|-----------------|
| Pi-hole DNS | 53/tcp, 53/udp | `FIREWALL_ALLOW_FROM` |
| Pi-hole DHCP (when its DHCP server is on) | 67/udp, 547/udp for IPv6 | anyone (a DHCP client has no address yet) |
| Pi-hole admin | its web port (80 or 8080) | `FIREWALL_ALLOW_FROM` |
| nginx (`web`) | its listen ports | `FIREWALL_ALLOW_FROM` |
| NetAlertX | `NETALERTX_PORT` and 20212 (its API) | `FIREWALL_ALLOW_FROM` |
| Samba | 445/tcp, 139/tcp, 137/udp, 138/udp | `FIREWALL_ALLOW_FROM` |
| TeamSpeak voice and file transfer | `TEAMSPEAK_VOICE_PORT`, `TEAMSPEAK_FILE_PORT` | anyone (published by Docker) |
| TeamSpeak web query (`TEAMSPEAK_QUERY_HTTP=yes`) | `TEAMSPEAK_QUERY_PORT` | `FIREWALL_ALLOW_FROM` (published by Docker) |
| Den-Watcher | `DENWATCHER_PORT` | `FIREWALL_ALLOW_FROM` (published by Docker) |
| Den-Watcher status page | `DENWATCHER_STATUS_PORT` | anyone (published by Docker; it is meant for outside) |
| apps | each app's port | `FIREWALL_ALLOW_FROM` (published by Docker) |
| Tailscale (installed by hand) | 41641/udp | anyone |

"Published by Docker" means the container publishes the port itself
(`ports:` in its compose file) and Docker forwards it to the container before
the `input` chain sees it. For those ports the task adds a `forward` chain to
its table, checked before Docker's own forward rules, that drops connections
from outside `FIREWALL_ALLOW_FROM`. See
[Ports of Docker containers](#ports-of-docker-containers).

## What it installs

- `nftables` (if `nft` is missing).
- `/etc/rpi-setup/firewall.nft`, the rules, in their own table
  `inet rpi_setup` (an `input` chain, and a `forward` chain for Docker's
  ports). Docker's and Tailscale's tables are left alone. The rules
  are checked with `nft -c` before anything is loaded.
- `rpi-setup-firewall.service`, which loads the table at boot.

## Using it

```bash
sudo nft list table inet rpi_setup                  # show the rules
sudo systemctl disable --now rpi-setup-firewall     # turn it off
```

## Ports of Docker containers

Ports a container publishes (`ports:` in its compose file) are forwarded by
Docker before the `input` chain sees them. The task knows the ports of
rpi-setup's own containers (TeamSpeak, Den-Watcher and the `apps`) and
limits the LAN ones in its `forward` chain, matched by the port on the Pi
(`ct original proto-dst`), so a remapped port such as an app's `8091:8080`
is caught too. It lists every published port when it runs. A container you
started by hand is not limited.

To close such a port instead:

- **Turn off what uses it.** `TEAMSPEAK_QUERY_HTTP=no` (the default) stops
  publishing the web query port. The voice and file ports are needed by every
  TeamSpeak client. An empty `DENWATCHER_STATUS_PORT` stops publishing the
  status page; an app left out of `APPS_LIST` is stopped.
- **Keep it inside your network.** A port is only reachable from the
  internet if your router forwards it to the Pi, or the Pi has a public IPv6
  address that the router lets through.
- **Do not edit `/opt/<task>/docker-compose.yml` by hand**: the task
  rewrites it on its next run.

## Good to know

- Services running in their own container (`<TASK>_DOCKER=yes`) are
  detected like native ones; they use the host network, so these rules apply
  to them.
- Inside a container or CI the rules are generated and checked but not loaded.
- Changing the network (another router, a VPN you reach the Pi through)
  changes what an empty `FIREWALL_ALLOW_FROM` means: re-run the task, or set
  the subnets yourself.
- `FIREWALL_ALLOW_FROM` entries need a prefix length after the `/`
  (`192.168.1.0/24`), or none at all for a single address (`10.0.0.5`).
- A re-run loads the rules again when the table is gone although the unit
  is still active, which happens after `nft flush ruleset` or a restart of
  `nftables.service` with Debian's stock `/etc/nftables.conf` (it flushes
  everything). Until then the Pi is open; `sudo systemctl reload
  rpi-setup-firewall` also brings the table back.
