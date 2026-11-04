# denwatcher - Den-Watcher website

Runs [Den-Watcher](https://github.com/Programmer-Den/den-watcher), a website
that shows the Pi's CPU and memory usage, temperatures and uptime, from its
published Docker image (arm64 and amd64). It was the `usagecontrol` task
before Den-Watcher's rename; see [Renamed from usagecontrol](#renamed-from-usagecontrol).

```bash
sudo bash setup.sh denwatcher
```

Needs Docker (the task runs the `docker` task first when it is missing) and a
**64-bit** OS. If the container does not stay up, its last log lines are
shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `DENWATCHER_PORT` | `9393` | Port of the website on the Pi (TCP). The task stops if another program already uses it. |
| `DENWATCHER_IMAGE` | `ghcr.io/programmer-den/den-watcher:main` | Docker image. `:main` follows Den-Watcher's main branch; a release such as `:1.2.3` stays fixed. |
| `DENWATCHER_ROUTERS` | empty | Routers to show as devices of their own (Den-Watcher 2.0 and later), as `name=protocol:address`, comma-separated, such as `Router=upnp:192.168.1.1`. The protocol is `upnp` (no login), `asus`, `fritzbox` or `snmpv3` (with the user before the address, such as `Box=fritzbox:user@192.168.178.1`) or `snmp` (v2c). Becomes Den-Watcher's `HUB_ROUTERS`. |
| `DENWATCHER_CONTAINERS` | `yes` | Show the CPU and memory of every other Docker container on the Pi, with Den-Watcher's containers add-on (see [Containers on the page](#containers-on-the-page), also for what it can read). `no` leaves it out. |
| `DENWATCHER_ADDONS` | `all` | Den-Watcher's other add-ons, each in a container of its own (see [Add-ons](#add-ons)): `all`, `none`, or a comma-separated list of `power`, `pressure`, `kernel`, `wifi`, `bluetooth`, `memory`, `ports` and `processes`. |
| `DENWATCHER_RETENTION_DAYS` | empty: Den-Watcher's own, 30 | Days of history to keep, 1 to 3650; older values are deleted. A longer history takes more room on the SD card. |
| `DENWATCHER_STATUS_PORT` | empty: no status page | Port of Den-Watcher's status page for outside the local network (TCP), such as `9443`; see [Status from anywhere](#status-from-anywhere). The task stops if it is `DENWATCHER_PORT` or another program already uses it. |
| `DENWATCHER_WIFI_RADIO` | `yes` | With the `wifi` add-on, switch the Wi-Fi radio on where Raspberry Pi OS keeps it off only because no Wi-Fi country is set, so a Pi on cable hears the networks nearby too (see [Add-ons](#add-ons)). A radio switched off while a country is set stays off. `no` leaves the radio as it is. |
| `DENWATCHER_WIFI_COUNTRY` | `DE` | The Wi-Fi country code (regulatory domain) set for that, only when none is set yet; a country already set is never changed. A code from `/usr/share/zoneinfo/iso3166.tab`, as `raspi-config` offers them. Norway's is `NO` in upper case: lower-case `no` was the way to leave the radio as it is before `DENWATCHER_WIFI_RADIO`, and stops the task now. |
| `DENWATCHER_ROUTER_PASSWORD` | empty: the one kept from an earlier run | Passwords of the routers that log in, and an SNMP community other than `public`, as `name=password`, comma-separated for several; a password cannot hold a comma. Kept in `/var/lib/rpi-setup/secrets/denwatcher.env`, so it needs to be given only once (see below). |

## What it installs and changes

- `/opt/denwatcher/docker-compose.yml`.
- With the `wifi` add-on and `DENWATCHER_WIFI_RADIO=yes`, where the Wi-Fi
  radio is off and no Wi-Fi country is set: the Wi-Fi country
  (`DENWATCHER_WIFI_COUNTRY`, through `raspi-config`; without it with
  `iw reg set`, for this boot only, with a warning), each radio unblocked in
  `rfkill` and in `/var/lib/systemd/rfkill`, and Wi-Fi switched on in
  NetworkManager. This happens after the image was pulled, so a wrong image
  or no network changes nothing. A country already set is never changed,
  and a radio switched off while a country is set stays off.
- `/opt/denwatcher/router-secrets/router-passwords` with the router
  passwords, one `name=password` per line, readable only by root and the
  container's user (65532); removed when there are none. A changed file
  restarts the container.
- The Docker volume `denwatcher_data` with the history, kept when the
  container is updated or recreated.
- The `den-watcher` container, restarting on its own. It listens on 9393
  inside the container, published on `DENWATCHER_PORT` over IPv4 only. It
  reads the Pi's `/proc` and `/sys` read-only, runs as a non-root user with
  no capabilities and a read-only file system, and changes nothing on the Pi.
  Its labels give it a card with a description on the `web` task's start
  page, also when only this task was run since the page was set up.
- With `DENWATCHER_CONTAINERS=yes`, the `den-watcher-containers`
  container (Den-Watcher's containers add-on, from the same image) and the
  in-memory Docker volume `denwatcher_addons` it hands its values over in.
  It finds every running container on its own, also ones started later, and
  shows each by name with its CPU and memory and their history.

## Add-ons

Each add-on in `DENWATCHER_ADDONS` runs as the `den-watcher-<add-on>`
container from the same image, writes what it reads to the in-memory
`denwatcher_addons` volume, and shows on the page with its history:

| Add-on | What it adds |
|--------|--------------|
| `power` | Power the CPU and the kernel's hwmon sensors report. Runs as root, as only root may read the CPU's energy counters, but without any capability. A Pi 5's total power needs `vcgencmd` on the host, which a container does not reach. |
| `pressure` | How much of the time tasks waited for the CPU, memory and disks (`/proc/pressure`; Raspberry Pi OS's kernel has it switched off, so it may show nothing). |
| `kernel` | Context switches, interrupts, new processes, open files, sockets, TCP connections and retransmissions. |
| `wifi` | Link quality and signal of each connected Wi-Fi interface, and the Wi-Fi networks nearby from the scans NetworkManager makes on its own (it starts none), asked through the host's system D-Bus (`/run/dbus`; mounted read-only, which does not stop it from talking to the bus: what it may ask is up to the bus's own policy for its user); a hub compares them under *Compare devices*, *Wi-Fi nearby*. Left out with a warning where there is no system D-Bus; without NetworkManager (Raspberry Pi OS before bookworm) the networks nearby are left out. Raspberry Pi OS keeps the Wi-Fi radio switched off (`rfkill list` shows it *Soft blocked*, `iw reg get` says country `00`) until a Wi-Fi country is set, which a Pi on cable usually never gets, so it would hear no networks: with `DENWATCHER_WIFI_RADIO=yes` the task then sets `DENWATCHER_WIFI_COUNTRY` (with `raspi-config`), unblocks each radio, also for the next boots, and switches Wi-Fi on in NetworkManager, and says what it reached. A radio switched off while a country is set was switched off on purpose and stays off (the task says how to switch it on); a radio switched off by a hardware switch only warns, and the others are still unblocked. The radio only listens; the Pi joins no Wi-Fi network that is not saved on it. |
| `bluetooth` | Connected Bluetooth devices with their name, kind or battery, asked from BlueZ through the host's system D-Bus (`/run/dbus`; mounted read-only, which does not limit what it may ask the bus); left out with a warning where there is none. It only lists devices. |
| `memory` | Memory details such as dirty and slab memory, page faults and swapping. |
| `ports` | The TCP and UDP ports the Pi listens on. |
| `processes` | The processes using the most CPU and memory. |

All of them read the host's `/proc` or `/sys` read-only, without any
capability, network or writable file system; all but `power` run as the
image's non-root user. An add-on that does not stay up only warns, with its
last log lines. Den-Watcher's `gpu`, `inodes` and `smart` add-ons have no
container, so this task does not run them.

## Containers on the page

The containers add-on reads each container's CPU and memory from the kernel's
cgroups (`/sys/fs/cgroup`) and their names from the `containers` folder in
Docker's data folder (as `docker info` shows it under *Docker Root Dir*,
usually `/var/lib/docker`), both mounted read-only. It never gets the Docker
socket: whoever can talk to that socket can start a container with the whole
Pi mounted, so it is as good as root on the Pi. Instead the add-on runs as
root inside its container only because the container names are in files only
root may read, but without any capability, without network and with a
read-only file system, so it can only read.

What it can read is more than the names, though: Docker keeps each
container's record in that folder, and the record holds the container's
whole configuration, with its environment and the values from its
`env_file` (such as Pi-hole's web password), and its log file. Docker has no
narrower folder to mount, so the add-on can read every container's settings,
passwords and logs; the one the task runs does not send anything (no
network), but it runs whatever the image holds. With the moving `:main` tag
a new build gets that access at the next update; for a Pi with other
containers, a release tag such as `:1.2.3` in `DENWATCHER_IMAGE`, updated by
hand, is the safer choice, or `DENWATCHER_CONTAINERS=no`.

Raspberry Pi OS's kernel counts no memory per container unless
`cgroup_enable=memory` is added to the line in `/boot/firmware/cmdline.txt`
(and the Pi rebooted); without it the page shows only the CPU of each
container, and the task says so.

## Reach it

Open `http://<pi>:9393` from a device on the local network. The website
answers only requests from private addresses (LAN, loopback, link-local).

## Status from anywhere

With `DENWATCHER_STATUS_PORT`, such as `9443`, Den-Watcher also serves its
status page on that port: a minimal page that tells only whether each device
is online, offline or switched off and how many alerts it has, with no values,
addresses or version. It is the only part of Den-Watcher meant to be reached
from the internet, so it answers only HTTPS, with a certificate Den-Watcher
makes itself, and shows nothing but a sign-in form until its password is
given. The task publishes it as Den-Watcher's `STATUS_ADDR` (`:9443` inside
the container) and `STATUS_PUBLIC_PORT`. Docker publishes the port itself,
and the `firewall` task leaves it open to anyone, since it is meant for
outside (see [Good to know](#good-to-know)).

Then, once:

1. Open `http://<pi>:9393` on the local network, click *Devices* and set a
   password under *Remote status page* (it asks for the password for
   changing devices). Until it is set, the status page shows no devices.
   Choose a long one: it is the only thing between the internet and the list
   of your devices.
2. Forward the port on the router to the Pi, such as TCP 9443 to
   `192.168.1.20:9443`, and open `https://<your public address>:9443` from
   outside. With a public address that changes, a dynamic DNS name from the
   router helps.
3. The browser warns about the certificate the first time. Compare the
   fingerprint it shows with the one in the *Devices* dialog before you go on.

How the page limits guessing and keeps visitors signed in is in Den-Watcher's
[setup guide](https://github.com/Programmer-Den/den-watcher/blob/main/docs/setup.md#8-check-the-devices-from-outside).
Emptying the setting and running the task again takes the page down; close
the port on the router too.

## Good to know

- The Pi pulls the image without logging in, so the package on ghcr.io must
  be public (on GitHub: the package's *Package settings > Change
  visibility*). The source repository can stay private.
- A newer image comes with `sudo bash update.sh` (or *Update Pi* from your
  settings repository).
- The default port is 9393, the port Den-Watcher listens on inside its
  container, so the address is the same with or without Docker and stays
  clear of nginx (80 or 8080). An install from before used 8080 or 8090; the
  next run of the task moves it to 9393 unless `DENWATCHER_PORT` is set.
- Docker publishes the website's port and the status port itself, before
  the `firewall` task's `input` rules see them. The website has no login, so
  the `firewall` task limits its port to `FIREWALL_ALLOW_FROM` in its
  `forward` chain; the status page stays open to anyone (it has its own
  password). See [Ports of Docker containers](firewall.md#ports-of-docker-containers).
- A router's password does not belong in the settings file, which may be in
  git: set it once on the Pi with
  `sudo DENWATCHER_ROUTER_PASSWORD='Box=secret' bash setup.sh denwatcher`.
  Later runs, also from *Update Pi*, keep it until a new one is given. A
  `upnp` router needs none.
- Stop: `cd /opt/denwatcher && sudo docker compose down`.

## Renamed from usagecontrol

Before Den-Watcher's rename the task was called `usagecontrol`, with
`USAGECONTROL_*` settings, the folder `/opt/usagecontrol` and the volume
`usagecontrol_data`. On a Pi set up that way, the first run of `denwatcher`
(from *Update Pi* once the settings repository lists `denwatcher`) moves it
over once: it creates the new volume, stops the old containers, copies the
history into `denwatcher_data`, keeps the router passwords and only then
removes the old containers and `/opt/usagecontrol`, so a failure on the way
leaves the old install running (a failed copy starts it again). The port
stays. The old volume is kept as a backup; once the page shows the
history, remove it with `sudo docker volume rm usagecontrol_data`.

`USAGECONTROL_*` lines in the settings file still work, with a warning per
line; rename them to `DENWATCHER_*`. The old image name
`ghcr.io/chriszly/usage-control` stops the task: set `DENWATCHER_IMAGE` to
`ghcr.io/programmer-den/den-watcher:main` or a release published there.

Den-Watcher moved from Chriszly to the Programmer-Den organization. Its images
are now published as `ghcr.io/programmer-den/den-watcher`; the image under the
old owner, `ghcr.io/chriszly/den-watcher`, keeps its versions but gets no new
ones, and the task warns when `DENWATCHER_IMAGE` still names it. Version tags
and `:latest` exist under the new name from the first release after the move.
