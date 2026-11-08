# runner - manual "Deploy to Pi" from your private repository

Lets you update the Pi from GitHub with a button: a **private** repository of
yours holds your settings and a *Deploy to Pi* workflow, and a GitHub Actions
runner on the Pi runs it. Pressing *Run workflow* pulls this public repo on the
Pi, installs your settings and reruns the tasks you pick. Nothing runs on its
own, nothing connects in to the Pi, and GitHub stores no SSH key, Tailscale
key or Pi address.

```bash
sudo RUNNER_TOKEN=<token> bash setup.sh runner
```

The private repository's layout, workflow and step-by-step setup are in
[templates/private-repo/README.md](../../templates/private-repo/README.md).

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `RUNNER_REPO` | none (required) | Your private repository as `owner/name`, e.g. `Chriszly/rpi-private`. Never a public one. |
| `RUNNER_TOKEN` | empty | One-time registration token: in the private repository open *Settings > Actions > Runners > New self-hosted runner* and copy the value after `--token`. Valid for one hour; not needed once the runner is registered. It is passed on `config.sh`'s command line (its only way to take it), so it is visible in `ps` for that moment; it is worthless afterwards. |
| `RUNNER_NAME` | the Pi's hostname | Runner name shown at GitHub. Applied at registration. |
| `RUNNER_LABELS` | `RUNNER_NAME` | Comma separated labels; the workflow's *pi* input picks the Pi by one of them and reads `pis/<pi>/rpi-setup.env`. Applied at registration. |

`RUNNER_REPO`, `RUNNER_NAME` and `RUNNER_LABELS` only count when the runner
registers. A re-run with changed values warns and says how to register
again ([below](#pitfalls)).
| `RUNNER_BRANCHES` | `main` | Branches of this repository a deploy may switch the Pi to. |
| `RUNNER_WORKFLOW_BRANCH` | `main` | Branch of your private repository whose workflows may run on the runner; see [Which jobs the runner takes](#which-jobs-the-runner-takes). |

## What it installs

- System user `rpi-runner` (stable UID via `assign_uid`) and the newest
  GitHub Actions runner in `/opt/rpi-runner`, checked against the SHA-256
  GitHub publishes (a release without a published checksum is refused),
  running as a systemd service. It updates itself.
- `/usr/local/sbin/rpi-setup-deploy`, the only command `rpi-runner` may run as
  root (`/etc/sudoers.d/rpi-setup-runner`). It accepts `--branch` (only from
  `RUNNER_BRANCHES`), `--commit` (a full commit id on that branch to deploy
  instead of its tip), `--config` (a file the caller can read), `--tasks`
  (names of `tasks/<name>.sh` in the checkout; nothing starting with `-`),
  `--skip` (tasks to leave out of this run, same rules) and `--update`.
  After updating the checkout it writes itself again from the checkout's
  `tasks/runner.sh` when that differs, and runs the new
  version, so a deploy never runs older deploy code than the checkout holds.
  A command written before this existed picks it up once `runner` reruns
  (Deploy to Pi with the task `runner`).
- `setup.sh` records every task that finished in
  `/var/lib/rpi-setup/tasks.done`; a deploy with no tasks reruns those. A
  recorded task that was removed from rpi-setup (such as `monitoring`) is
  skipped, and the next `setup.sh` run drops it from the file.

- `/usr/local/libexec/rpi-setup/runner-job-started`, run by the runner before
  every job (a systemd drop-in of the runner's unit sets
  `ACTIONS_RUNNER_HOOK_JOB_STARTED`). See below.

## Which jobs the runner takes

Every job on the runner can call the deploy command, and a job can hand it a
settings file of its own, so a job on the runner is as good as root on the
Pi. GitHub gives a job to a runner by its labels alone: a workflow pushed to
any branch of the private repository, or *Run workflow* with another branch
picked under *Use workflow from*, would reach the Pi too. So before each job
the runner runs the job-started hook, which fails the job before its first
step unless it is

- a manual run (*Run workflow*, `workflow_dispatch`),
- of a workflow of `RUNNER_REPO`,
- from its branch `RUNNER_WORKFLOW_BRANCH` (default `main`).

The workflow log's *Set up runner* step says why a job was refused. Protect
that branch at GitHub too (*Settings > Rules > Rulesets*: block force pushes
and deletion, require a pull request), so a change to it is always seen.
A runner set up before the hook existed gets it with *Deploy to Pi* and the
task `runner`; the runner restarts two minutes later to load it.

## What a deploy does

1. Fast-forwards this repository's checkout on the Pi to the chosen branch,
   or, with `--commit`, moves it to exactly that commit of the branch (also
   back to an older one). The private repository's workflows pass the commit
   of their `rpi-setup` submodule, so the Pi runs the code their *Check*
   tested, not whatever the branch holds at that moment.
2. Installs `pis/<pi>/rpi-setup.env` from the private repository as
   `/etc/rpi-setup/rpi-setup.env` (root, 0600), if the workflow's *settings*
   box is ticked.
3. Runs `setup.sh` with the chosen tasks, as if the owner of the checkout
   had started it with sudo (`SUDO_USER`), so tasks that set up "your" user
   (docker group, SSH keys, Samba user) pick that person and never
   `rpi-runner`. Only the run summary and, when a task fails, its error
   lines (`[x] ...`) go to the workflow log; the full output, which can contain generated passwords,
   stays on the Pi in `/var/log/rpi-setup-deploy/`.
4. Deletes the private repository's checkout from the Pi.

You can run the same deploy by hand on the Pi:
`sudo /usr/local/sbin/rpi-setup-deploy --tasks "base pihole"`.

`--skip "pihole samba"` (the workflows' *skip* input) leaves those tasks out
of one run: a deploy with no tasks reruns every recorded task but these, and
an update neither sets them up nor touches their containers (`update.sh
--skip`; for `web`, its start page). A name that is not a task in the
checkout stops the run, so a typo never skips nothing silently. A deploy
command written before `--skip` existed refuses it (`unknown argument
'--skip'`): run Deploy to Pi once with the task `runner`, which touches no
containers, and the command writes itself again with `--skip`.

## Update instead of deploy

The *Update Pi* workflow (`templates/private-repo/.github/workflows/update.yml`)
passes `--update`. Steps 1, 2 and 4 are the same; step 3 becomes:

- `update.sh --containers-only`: pulls new images for the containers rpi-setup
  set up and recreates the ones that changed, and re-runs the `web` task so
  its start page is the current version. No OS packages, Pi-hole or EEPROM
  update.
- `setup.sh` only for the given tasks that are not yet in
  `/var/lib/rpi-setup/tasks.done`, so tasks you add to the list get set up
  and the others are left alone. The
  workflow takes the list from its *tasks* input or from `pis/<pi>/tasks` in
  the private repository.

By hand: `sudo /usr/local/sbin/rpi-setup-deploy --update --tasks "base docker web"`.
The full output of both steps stays on the Pi in `/var/log/rpi-setup-deploy/`.

## Pitfalls

- The runner account is as good as root: the deploy command is its only
  root command, but `--config` installs whatever settings the workflow
  hands it, and the settings decide what runs as root (which images, which
  folders a container gets). So anyone who can run workflows in, or push to,
  the private repository is root on the Pi, and so is anyone who can push to
  a branch of rpi-setup listed in `RUNNER_BRANCHES`. Keep the repository
  private, keep two-factor login on GitHub, and treat a token that can push
  there like a root password.
- A runner on a public repository would let pull requests from strangers run
  code on the Pi. Make sure `RUNNER_REPO` names a private repository.
- A deploy stops if the checkout on the Pi has local commits or changes
  (`git -C <checkout> status`).
- The checkout must belong to your own login user, not `root` or
  `rpi-runner`; otherwise a deploy stops (`sudo chown -R <you>: <checkout>`).
- A deploy reads `/etc/rpi-setup/rpi-setup.env`. If your settings are still
  in the checkout's `config/rpi-setup.env` and the deploy brings none
  (*settings* box not ticked, no `--config`), it stops instead of running
  every task with defaults. Move them once:
  `cd <checkout> && sudo bash setup.sh --move-config`.
- Remove the runner: `cd /opt/rpi-runner && sudo ./svc.sh uninstall`, then
  delete it at *Settings > Actions > Runners* in the private repository.
- Register it again (another repository, name or labels): stop and remove
  the service and the registration, then run the task with a new token:

  ```bash
  cd /opt/rpi-runner && sudo ./svc.sh stop && sudo ./svc.sh uninstall
  sudo rm -f .runner .credentials .credentials_rsaparams .service .labels
  sudo RUNNER_TOKEN=<new token> bash setup.sh runner
  ```

  A runner registered under the same name replaces the old entry at
  GitHub; one with another name or repository stays listed there until you
  delete it under *Settings > Actions > Runners*.
