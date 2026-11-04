# teamspeak - TeamSpeak 6 server

Runs a [TeamSpeak 6](https://teamspeak.com/) voice chat server from the
official Docker image (native arm64).

```bash
sudo bash setup.sh teamspeak
```

Needs Docker (the task runs the `docker` task first when it is missing) and a
**64-bit** OS: the image exists for arm64 and amd64 only, and the task stops
on a 32-bit Pi OS. If the container does not stay up, its last log lines are
shown and it is taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `TEAMSPEAK_ACCEPT_LICENSE` | `yes` | You accept the TeamSpeak server license; the server does not start without it. |
| `TEAMSPEAK_VOICE_PORT` | `9987` | Voice port (UDP) on the Pi. Can be changed later; see "Voice port" below. |
| `TEAMSPEAK_FILE_PORT` | `30033` | File transfer port (TCP). |
| `TEAMSPEAK_QUERY_HTTP` | `no` | Turn on the web query API, an admin API over plain HTTP that nothing in rpi-setup needs. The `firewall` task limits its port to `FIREWALL_ALLOW_FROM`. |
| `TEAMSPEAK_QUERY_PORT` | `10080` | Web query port (TCP). |
| `TEAMSPEAK_QUERY_ADMIN_PASSWORD` | empty: generated with `TEAMSPEAK_USAGE=yes` (and kept once generated), else TeamSpeak's own (none set) | Password of the `serveradmin` query account. Cannot contain `"`, `\` or `$`. A generated one is printed once and kept in `/var/lib/rpi-setup/secrets/teamspeak.env`. |
| `TEAMSPEAK_IMAGE` | `teamspeaksystems/teamspeak6-server:latest` | Docker image. |
| `TEAMSPEAK_USAGE` | `yes` | Log who is online and when, for the start page ([below](#who-is-online-and-when)). |
| `TEAMSPEAK_USAGE_DAYS` | `90` | Days of visits the usage log keeps (1 to 9999). |
| `TEAMSPEAK_USAGE_CONNECTIONS` | `no` | `yes`: the start page lists which nicknames came from the same IP address ("Same connection", [below](#who-is-online-and-when)). Anyone who can open the start page sees it. |
| `TEAMSPEAK_PUBLIC_ADDRESS` | empty: look up the public IP | The address friends outside your LAN connect to, shown on the start page: a DynDNS name or fixed address, empty to look up the Pi's public IPv4 address every 30 minutes, or `no` for none ([below](#internet-address)). Needs `TEAMSPEAK_USAGE=yes`. |
| `TEAMSPEAK_PUBLIC_PORT` | `TEAMSPEAK_VOICE_PORT` | The UDP port your router forwards to the voice port, shown with the internet address. |

## What it installs and changes

- `/opt/teamspeak/docker-compose.yml` (root only) and
  `/opt/teamspeak/data`, owned by UID 9987: the image always runs as 9987.
- `/opt/teamspeak/secrets.env` (root only) with the query password, which
  the server and the usage bot read with `env_file`, so it is not in the
  compose file. Docker still keeps it in each container's settings, which
  `docker inspect` and root can read.
- `/opt/teamspeak/voice-port`: the voice port the server was created with
  (see below).
- The `teamspeak` container with the voice, file and (with
  `TEAMSPEAK_QUERY_HTTP=yes`) web query ports published, restarting on its
  own.
- With `TEAMSPEAK_USAGE=yes`: the SSH query turned on inside the server (its
  port 10022 is not published), and the `teamspeak-usage` container, built on
  the Pi from `templates/teamspeak-usage` (`python:3-alpine` with the SSH
  client) into `/opt/teamspeak/usage`, its log in `/opt/teamspeak/usage/data`
  owned by its own UID.

## Reach it

- Connect the TeamSpeak 6 client to `<pi>:9987`.
- On the first start the task prints the **ServerAdmin privilege key**. It is
  shown only once; enter it in the client to become server admin. Find it
  later with `docker logs teamspeak`.
- Forward UDP 9987 and TCP 30033 on your router for friends outside your LAN.
  They connect to the internet address the start page's TeamSpeak tab shows
  ([below](#internet-address)).

## Voice port

TeamSpeak takes its voice port (`TSSERVER_DEFAULT_PORT`) only when it creates
its database; after that the server keeps listening on that port. So the task
uses `TEAMSPEAK_VOICE_PORT` for the port inside the container only for a new
server (empty data folder) and records it in `/opt/teamspeak/voice-port`. When
you change `TEAMSPEAK_VOICE_PORT` later, only the port on the Pi changes: it
is forwarded to the recorded port inside the container (e.g. `9988:9987/udp`).
A server set up before this file existed gets the port from its old compose
file (else 9987). If that guess is wrong, write the right port into the file
and re-run the task.

## Who is online and when

With `TEAMSPEAK_USAGE=yes` (the default) a small bot in the
`teamspeak-usage` container logs in to the server's SSH query as
`serveradmin` over the containers' own network. Query clients do not show up
in the channel tree, so users do not see it. It reads who is online,
registers for join and leave events and writes to `/opt/teamspeak/usage/data`:

- `sessions.jsonl`: one line per finished visit, with the client's unique ID,
  nickname, start, end, server groups, client platform and when the client
  first connected to the server, and the IP address it connected from. Visits
  older than `TEAMSPEAK_USAGE_DAYS` are dropped once a day.
- `online.json`: who is online now, with their IP addresses.
- `stats.json`: minutes spent in each channel per UTC day (7 days kept), for
  the busiest channels.
- `usage.json`: the summary the [web start page](web.md#teamspeak) shows,
  rewritten every minute, including how many were online at once over the
  last 7 days (the points where that number changes), and every minute the
  server's info, the channel tree and the details of each client online
  (channel, version, platform, country, away, muted, idle) from `serverinfo`,
  `channellist` and `clientlist`. IP addresses stay in `sessions.jsonl` and
  `online.json` on the Pi, and `usage.json` never contains an address. With
  `TEAMSPEAK_USAGE_CONNECTIONS=yes` it also groups visits by address, named
  after the nickname used last (empty by default). A group is
  listed when two or more identities (unique IDs) used the address; visits
  from one address more than 30 days apart are separate groups, so an address
  handed to another household (or a carrier-grade NAT address) does not link
  strangers for `TEAMSPEAK_USAGE_DAYS` days. A nickname that several
  identities used is listed once, with their number.

The data folder is readable by the bot's own user and root only (`0700`, the
two files with addresses `0600`); the web task's timer copies `usage.json` as
root.

When the bot or the server restarts, the people still online keep their
start time; the visits of those who left in between end at the last time the
bot saw them (at most a minute or so early). The bot reconnects on its own;
`sudo docker logs teamspeak-usage` shows why it could not.

Turning it on sets a `serveradmin` password (and turns on the SSH query), so
the server is restarted once. If your server is used by people outside your
home, tell them their connection times are logged. The start page, and so
the log, is meant for your LAN only (the `firewall` task keeps it there).
`TEAMSPEAK_USAGE=no` removes the container and keeps the log (and the
generated password). While the bot cannot reach the server it stops updating
`usage.json`, so the start page hides its TeamSpeak tab after 10 minutes instead of
showing an old list. The bot and its image are rebuilt (with a fresh Python
base image) when the `teamspeak` task runs and by `update.sh`.

## Internet address

With `TEAMSPEAK_USAGE=yes` the start page's TeamSpeak tab shows, next to the
address on your LAN, the **internet address** friends outside it connect to,
as `address:port` with `TEAMSPEAK_PUBLIC_PORT` (default: the voice port). The
usage bot works it out every 30 minutes (5 after a failure):

- `TEAMSPEAK_PUBLIC_ADDRESS` empty (the default): it asks a "what is my IP"
  service, `https://api.ipify.org` and else `https://ipv4.icanhazip.com`, for
  the public IPv4 address the Pi connects from. Neither needs an account, and
  they only learn that address. Most home connections get a new one now and
  then, so the tab shows when it was checked (hover the tile) and keeps the
  last address while the services cannot be reached.
- A DynDNS name (e.g. `kims-den.dyndns.example`): shown as it is, with the
  IPv4 address the name resolves to (its IPv6 address when it has no IPv4
  one; `does not resolve` when it has neither), so you can see whether your
  DynDNS name is up to date. Nothing outside your DNS is asked. Give friends
  the name: it keeps working when the address changes.
- A fixed IPv4 or IPv6 address: shown as it is, with no lookup.
- `no`: no internet address, and nothing is looked up.

The address only reaches the server when the router forwards UDP
`TEAMSPEAK_PUBLIC_PORT` (and TCP `TEAMSPEAK_FILE_PORT` for file transfers) to
the Pi. Behind carrier-grade NAT (many mobile and some fibre or cable
connections) the looked-up address is your provider's and cannot be
forwarded; ask the provider for a public IPv4 address. The lookup of the
Pi's own public address is IPv4 only.

## Good to know

- Docker publishes the ports itself, before the `firewall` task's `input`
  rules see them. The firewall task leaves voice and file transfer open to
  anyone and limits the web query port to `FIREWALL_ALLOW_FROM` in its
  `forward` chain: [Ports of Docker containers](firewall.md#ports-of-docker-containers).
- The server container drops every Linux capability and cannot gain
  privileges (`cap_drop: [ALL]`, `no-new-privileges`): the image runs as
  user 9987 from the start and its ports are above 1024, so it needs none.
  New with this version and not yet tried on a Pi: if the server does not
  come up after an update (`sudo docker logs teamspeak`), say so in an issue
  and take the two settings out of `/opt/teamspeak/docker-compose.yml` for
  the time being.
- A newer image comes with `sudo bash update.sh`.
- Stop: `cd /opt/teamspeak && sudo docker compose down`.
