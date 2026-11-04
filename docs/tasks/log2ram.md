# log2ram - logs in RAM

Installs [log2ram](https://github.com/azlux/log2ram), which keeps `/var/log`
(including the system journal) in a RAM disk and copies it to the SD card every
hour and at shutdown. Programs that log all the time then stop wearing out
the SD card and stop filling it between clean-ups.

```bash
sudo bash setup.sh log2ram
sudo reboot
```

log2ram takes over `/var/log` at boot, so it starts working after the next
reboot. Check it afterwards with `df -h /var/log` (the filesystem is `log2ram`)
or `sudo bash check.sh`.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `LOG2RAM_SIZE` | `128M` | Size of the RAM disk for `/var/log` (`128M`, `256M`, `1G`, ...), at least `16M`. It only uses RAM for what is really in it. A lower-case suffix (`128m`) is taken as the upper-case one. |
| `LOG2RAM_SYNC` | `hourly` | How often the logs are copied to the SD card: `hourly`, `daily` (log2ram's own time, once a night) or a [systemd calendar time](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events) such as `*:0/30` (every 30 minutes). rsync writes only what changed, so a frequent copy costs few writes. |
| `LOG2RAM_JOURNAL_MAX_SIZE` | `64M` | Space the system journal may use in that RAM disk; at most 3/4 of `LOG2RAM_SIZE`, so other logs still fit. Overrides `BASE_JOURNAL_MAX_SIZE`. |

## What it changes

- Adds the log2ram maintainer's apt repository (`packages.azlux.fr`, key in
  `/usr/share/keyrings/azlux-archive-keyring.gpg`, list in
  `/etc/apt/sources.list.d/azlux.list`), so `apt-get upgrade` and `update.sh`
  keep log2ram current, and installs `log2ram` and `rsync`.
- `/etc/apt/preferences.d/rpi-setup-azlux`, which lets apt take only
  `log2ram` from that repository, so it can never replace a system package
  (such as `openssh-server` or `sudo`) with its own version.
- `/etc/log2ram.conf`: `SIZE` from `LOG2RAM_SIZE` and `NOTIFICATION=false`
  (a Pi has no mail setup; `MAIL=false` on log2ram before 1.7); the
  package's other defaults stay.
- `/etc/systemd/journald.conf.d/20-log2ram.conf`: `SystemMaxUse` from
  `LOG2RAM_JOURNAL_MAX_SIZE`. It sorts after the `base` task's
  `10-rpi-setup.conf` and wins over it, so the journal cannot fill the RAM disk.
- Enables `log2ram.service`. Its `log2ram-daily.timer` writes the logs to the
  SD card; `/etc/systemd/system/log2ram-daily.timer.d/10-rpi-setup.conf` runs
  it at `LOG2RAM_SYNC` instead of once a night (`daily` removes that file).

All settings are checked before anything changes. Re-running the task with
another size changes the files and asks for a reboot again.

## Good to know

- **A power cut or crash loses the logs since the last copy** (at most an hour
  with the default `LOG2RAM_SYNC`). A clean
  `sudo reboot` or `sudo poweroff` writes them first. Copy them by hand with
  `sudo systemctl reload log2ram`.
- **The logs must fit.** When `/var/log` already holds more than the RAM disk,
  log2ram does not start at boot and the logs stay on the SD card; the task
  warns about it. Shrink the journal with
  `sudo journalctl --vacuum-size=64M`, delete old `*.gz` logs or raise
  `LOG2RAM_SIZE`, then reboot.
- The copy on the SD card is in `/var/hdd.log`.
- Docker keeps container logs in `/var/lib/docker`, not `/var/log`; the
  `docker` task rotates those instead.
- Inside a container or CI the task installs and enables log2ram but does not
  ask for a reboot.
- Remove it with `sudo apt-get remove log2ram` and a reboot, then delete
  `/etc/systemd/journald.conf.d/20-log2ram.conf`.
