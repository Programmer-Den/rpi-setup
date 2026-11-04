# samba - NAS share

Shares one folder on the Pi over SMB, so Windows, macOS and Linux can open it
as a network drive (`\\<pi>\nas-share`). Password protected, one user.

```bash
sudo bash setup.sh samba
```

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `SAMBA_USER` | the user who ran `sudo` | Linux user who owns the share and logs in to it. Must exist on the Pi. |
| `SAMBA_PASSWORD` | empty: generated | SMB password of that user. Empty: generated the first time, printed once and saved; later runs keep the existing password unless you set one. Switching between the package and the container (`SAMBA_DOCKER`) keeps the saved password too. |
| `SAMBA_SHARE_NAME` | `nas-share` | Share name, as in `\\<pi>\nas-share`. Letters, digits, `.`, `_`, `-`; not `global`, `homes` or `printers`. Renaming it replaces the old share in `smb.conf`. |
| `SAMBA_SHARE_PATH` | `<home of SAMBA_USER>/<SAMBA_SHARE_NAME>` | Folder to share (absolute path). Created if missing. Not a system folder (`/`, `/etc`, `/usr`, `/var`, `/var/lib/...`, `/home` or `/root` themselves, `/boot`, ...): the task refuses those, since the container would get them read-write as root. |
| `SAMBA_READ_ONLY` | `no` | `yes` makes the share read-only. |
| `SAMBA_DOCKER` | `no` | `yes` runs Samba in its own Docker container instead of the apt package ([below](#run-it-in-docker)). |
| `SAMBA_IMAGE` | `crazymax/samba:latest` | Docker image for `SAMBA_DOCKER=yes`. |

## What it installs and changes

- The `samba` package and the `smbd` service, enabled and started.
- A `[<share name>]` section in `/etc/samba/smb.conf`, marked as managed by
  rpi-setup and rewritten when settings change (validated with `testparm`).
- The SMB password of `SAMBA_USER` (`smbpasswd`). It is separate from the
  user's login password.

## Reach it

- Windows: `\\<pi>\nas-share` in Explorer. macOS: `smb://<pi>/nas-share`.
  Linux: `smb://<pi>/nas-share` in the file manager.
- Log in as `SAMBA_USER` with the SMB password. A generated one is in
  `/var/lib/rpi-setup/secrets/samba.env` (root only).

## Run it in Docker

With `SAMBA_DOCKER=yes` the task runs Samba from `SAMBA_IMAGE` in a container
named `samba` on the host network (port 445). Docker is installed first if it
is missing.

- The share folder stays where it is; the container's settings live in
  `/opt/samba`. Files keep the owner `SAMBA_USER`, which cannot be `root` here.
- A native smbd is stopped (its package stays). Its password hash cannot be
  copied, so the first switch needs `SAMBA_PASSWORD` set once (it can be the
  same password); the task says so.
- If the container does not stay up, the native smbd is started again.
  `SAMBA_DOCKER=no` switches back.
- The `firewall` task, `check.sh` and the `backup` task recognise the container; with `BACKUP_INCLUDE_SHARE=yes` the backup also takes the shared folder.

## Good to know

- Run with `sudo` from your normal user, not as root: the share belongs to
  the user who runs `sudo` unless `SAMBA_USER` is set.
- The `backup` task saves the Samba configuration and passwords; the share's
  files only with `BACKUP_INCLUDE_SHARE=yes`.
- Turn it off with `sudo systemctl disable --now smbd`.
