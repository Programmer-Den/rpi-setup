# apps - your own web apps

Runs your own web apps from container images, such as a static site or a
game that your repository's CI builds into an image. Each app is a container
of its own with a card on the `web` task's start page.

```bash
sudo bash setup.sh apps
```

Needs Docker (the task runs the `docker` task first when it is missing) and a
**64-bit** OS, so the images must be published for arm64 (and amd64 for a PC).
If a container does not stay up, its last log lines are shown and the apps
are taken down again.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `APPS_LIST` | empty (none) | Apps to run, as `name:port=image`, separated by spaces or commas, such as `game:8091=ghcr.io/you/game:latest`. The name (lowercase letters, digits and `-`, at least two characters with a letter; not a word or number the compose file reads differently, such as `true`, `null` or `1e3`, and not the name of another task's container, such as `pihole`) names the container and its card; the port is the app's port on the Pi (TCP), which no other container may publish. Add `:container-port` after the port when the app does not listen on 8080 inside its container: `game:8091:80=...`. An emptied list stops the apps; empty with none running, the task does nothing. |
| `APPS_DATA` | empty (none) | Apps from `APPS_LIST` that keep data, separated by spaces or commas, such as `planner`. Each gets the folder `/opt/apps/data/<name>`, owned by the apps' user and closed to everyone else, as `/data` in its container: the one place besides `/tmp` it can write, and the one that survives restarts, updates and redeploys. A name that is not in `APPS_LIST` stops the task. Taking an app out of the list keeps its folder. |

## What it installs and changes

- `/opt/apps/docker-compose.yml` with one container per app, named after it.
  Each is published on its port over IPv4, restarts on its own, runs as a
  non-root user of its own (`assign_uid apps`) with no capabilities, a
  read-only file system and only `/tmp` writable (in memory), and gets the
  Pi's time zone. It keeps nothing between restarts, except an app in
  `APPS_DATA`: its folder `/opt/apps/data/<name>` (mode 0700, the apps'
  user) is its `/data`. The `backup` task saves `/opt/apps` with it.
- Labels that give each app a card on the start page, linking to its port.

Every run pulls the images, so an app on a moving tag such as `:latest`
gets the newest build, and recreates only the apps whose image or settings
changed. Apps removed from the list are taken down. To update the apps on
every push to your repository, have its CI publish the image and then run
this task through the [runner](runner.md)'s Deploy workflow with
`--tasks apps`.

## Images

- A public image needs no login. For a private one, log in to its registry
  once on the Pi as root, which the task pulls as; Docker keeps the login in
  `/root/.docker/config.json`. On ghcr.io, with a personal access token
  (classic) that has only `read:packages`:

  ```bash
  sudo docker login ghcr.io -u <your GitHub login>
  ```

  The token never goes in the settings file.
- The image must run as any user: it gets the task's user, not its own, and
  can write only to `/tmp`. For a static site,
  `nginxinc/nginx-unprivileged` serves the files on 8080 and writes only
  to `/tmp`:

  ```dockerfile
  FROM nginxinc/nginx-unprivileged:alpine
  COPY dist/ /usr/share/nginx/html/
  ```

## Reach it

`http://<pi>:<port>` for each app, and its card on the start page.

Docker publishes each app's port itself, before the `firewall` task's
`input` rules see it; the firewall task limits it to `FIREWALL_ALLOW_FROM` in
its `forward` chain. See
[Ports of Docker containers](firewall.md#ports-of-docker-containers).
