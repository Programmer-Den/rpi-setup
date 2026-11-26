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
| `APPS_DATA` | empty (none) | Apps from `APPS_LIST` that keep data, separated by spaces or commas, such as `game`. Each gets the folder `/opt/apps/data/<name>`, owned by the apps' user and closed to everyone else, as `/data` in its container: the one place besides `/tmp` it can write, and the one that survives restarts, updates and redeploys. A name that is not in `APPS_LIST` stops the task. Taking an app out of the list keeps its folder. |
| `APPS_BUILD` | empty (every app runs its image) | Apps from `APPS_LIST` to build on the Pi from a git repository instead of pulling their image, as `name=url#ref`, separated by spaces or commas, such as `game=https://github.com/you/game.git#main`. `url` is the repository over `https`; `ref` is a branch, a tag or a commit (7 to 40 hex digits), and without `#ref` the repository's default branch. The repository needs a `Dockerfile` at the top. The app keeps its port and settings from `APPS_LIST`; its image there only names the registry where a published image of the commit is looked for first. See [Built on the Pi](#built-on-the-pi). |
| `APPS_BUILD_TOKEN` | empty (the saved one, or none) | Token for private repositories in `APPS_BUILD`: on GitHub a fine-grained token with only **Contents: read** on them. It is saved in `/var/lib/rpi-setup/secrets/apps.env` (root only) and used by later runs that leave it empty; a new value replaces it. Public repositories need none. |

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

## Built on the Pi

For a version that has no image, such as the newest commit of a branch that
is not released, list the app in `APPS_BUILD`. Every run then:

1. fetches the repository into `/var/cache/rpi-setup/apps/<name>` (root only;
   not in `/opt/apps`, so the `backup` task leaves it out): the full history,
   but file contents only for the commit it checks out. With a token,
   it goes to the server as an HTTP header and is never written to the
   checkout;
2. checks out the commit `ref` points to now, with nothing else in the folder;
3. looks for a published image of that commit in the registry of the app's
   image in `APPS_LIST`: the tag `sha-<first 7 digits of the commit>`, as a CI
   publishes a commit, then each release tag of the commit without its
   leading `v` (`1.2.3` for the git tag `v1.2.3`). The first one that pulls
   runs, and nothing is built;
4. otherwise builds the image there (`docker compose build --pull`; an
   unchanged commit comes from Docker's build cache) and recreates the app
   when it changed. The card on the start page then names the repository and
   the commit.

So `APPS_LIST` keeps the app's published image, such as
`game:8091=ghcr.io/you/game:latest`, and `APPS_BUILD` only adds where its
code lives. The build
runs on the Pi, so it takes longer than a pull, and a Dockerfile that builds
for another platform needs emulation; one whose build stage runs on
`$BUILDPLATFORM` (only the last stage per platform) needs none. `update.sh`
builds the apps again from the same commit, with their base images pulled;
only a run of this task moves them to a new commit. Removing an app from
`APPS_BUILD` goes back to its image from `APPS_LIST` and removes its checkout.

## Reach it

`http://<pi>:<port>` for each app, and its card on the start page.

Docker publishes each app's port itself, before the `firewall` task's
`input` rules see it; the firewall task limits it to `FIREWALL_ALLOW_FROM` in
its `forward` chain. See
[Ports of Docker containers](firewall.md#ports-of-docker-containers).
