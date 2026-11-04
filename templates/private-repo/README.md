# Private rpi-setup settings and deploy

This folder is a template for a **private** GitHub repository of your own
(for example `rpi-private`). The public rpi-setup repository stays free of
anything about your devices; this private one holds your settings and a
**Deploy to Pi** button.

## Layout

```
.github/workflows/deploy.yml   the Deploy to Pi workflow (copy from here)
.github/workflows/update.yml   the Update Pi workflow (copy from here)
pis/<pi>/tasks                 tasks that Pi should have, one per line (read by Update Pi)
pis/<pi>/rpi-setup.env         filled settings of one Pi (start from config/rpi-setup.env.example)
pis/<pi>/id_ed25519.pub        public SSH key for that Pi (for host/flash.sh -a); never the private key
```

`<pi>` is the Pi's runner label, by default its hostname (for example `pi5`).

## Setup

1. Create a private repository on GitHub and copy this folder's contents into it.
2. Copy `config/rpi-setup.env.example` from rpi-setup to `pis/<pi>/rpi-setup.env`
   and fill it in. Set `RUNNER_REPO=<you>/<private repo>`.
3. In the private repository open **Settings > Actions > Runners > New
   self-hosted runner** and copy the value after `--token`. It is valid for
   one hour.
4. On the Pi, once, with that token:
   `sudo RUNNER_TOKEN=<token> bash setup.sh runner`
   The task installs the runner as user `rpi-runner`, registers it to the
   private repository only, and allows it one root command:
   `/usr/local/sbin/rpi-setup-deploy`.
5. Deploy: **Actions > Deploy to Pi > Run workflow**, pick the Pi, the tasks
   (empty = every task already on the Pi) and the branch.
6. Later updates: **Actions > Update Pi > Run workflow**. It updates the
   containers already on the Pi (new images) and sets up only the tasks from
   `pis/<pi>/tasks` that the Pi does not have yet. Add a task to that file to
   install it with the next update.

## What the deploy does

1. The workflow checks out this repository on the Pi.
2. `rpi-setup-deploy` updates the rpi-setup checkout on the Pi to the chosen
   branch (only branches listed in `RUNNER_BRANCHES`), or to the commit of
   this repository's `rpi-setup` submodule if it has one (see below), installs
   `pis/<pi>/rpi-setup.env` as `/etc/rpi-setup/rpi-setup.env` (root only)
   and runs `setup.sh` with the chosen tasks for the user who owns the
   checkout (never `rpi-runner`). Without the settings file it stops if your
   settings are still in the checkout's `config/rpi-setup.env`; move them
   once with `sudo bash setup.sh --move-config`.
3. Only the run summary appears in the workflow log. The full output,
   including any generated passwords, stays on the Pi in
   `/var/log/rpi-setup-deploy/`.
4. The checkout of this repository is deleted from the Pi afterwards.

## Keep in mind

- Never register the runner to a public repository: pull requests from
  strangers could run code on your Pi.
- Anyone who can push to or run workflows in this repository can run setup
  on the Pi as root. Keep it private and keep two-factor login on GitHub.
- The runner takes only manual runs (*Run workflow*) of workflows from this
  repository's `main` (`RUNNER_WORKFLOW_BRANCH`) and refuses every other job
  before its first step, so a workflow on another branch never reaches the
  Pi. Protect `main` with a ruleset (*Settings > Rules > Rulesets*: block
  force pushes and deletion, require a pull request).
- Optional: add rpi-setup as a submodule (`git submodule add
  https://github.com/Programmer-Den/rpi-setup.git rpi-setup`). The workflows
  then deploy exactly the commit it pins instead of the tip of `main`, so a
  new rpi-setup commit reaches the Pi only once you move the submodule (for
  example by merging Dependabot's `gitsubmodule` pull request).
- Pin the actions in the workflows to a commit SHA, as the templates do; a
  moved tag would otherwise run on the Pi.
- Your SSH private key never goes into this repository, only the `.pub` file.
