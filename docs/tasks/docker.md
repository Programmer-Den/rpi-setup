# docker - Docker Engine and Compose

Installs Docker Engine with the buildx and Compose plugins from Docker's own
apt repository and limits container logs to 3 files of 10 MB each, so logs
cannot fill the SD card.

```bash
sudo bash setup.sh docker
```

`netalertx` and `teamspeak` (and any task with `<TASK>_DOCKER=yes`) need
Docker. When Docker is not installed yet, such a task runs the `docker` task
itself first, with your `DOCKER_*` settings.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `DOCKER_ADD_USER` | `yes` | Add the user who ran `sudo` to the `docker` group, so `docker` works without `sudo` (after logging in again). |

## What it installs and changes

- Docker's apt repository (`/etc/apt/sources.list.d/docker.list`, key in
  `/etc/apt/keyrings/docker.gpg`; the task refuses a key that is not Docker's
  release key `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`) and the packages `docker-ce docker-ce-cli
  containerd.io docker-buildx-plugin docker-compose-plugin`.
- `/etc/docker/daemon.json` with the log rotation. A `daemon.json` you edited
  yourself is left alone (the task warns and skips the log settings).
- The `docker` service is enabled and started.

If Docker is already installed from another source without Compose v2, the
task only adds the Compose plugin.

## Good to know

- Log out and back in (reconnect SSH) after the first run to use `docker`
  without `sudo`.
- rpi-setup's containers live in `/opt/<task>/` (a `docker-compose.yml` plus
  a `data/` folder). `sudo bash update.sh` (or re-running the task) pulls new
  images and recreates the containers that changed. Switching a task back
  to native (`<TASK>_DOCKER=no`) renames its file to
  `docker-compose.yml.disabled`, so `update.sh` leaves it alone; the data stays.
- Turn Docker off with `sudo systemctl disable --now docker docker.socket`.
