#!/usr/bin/env bash
# Task: apps - your own web apps from container images (Docker), such as a
# static site or a game built by your repository's CI, or built on the Pi
# from a git repository (APPS_BUILD).
# Settings: APPS_* in config/rpi-setup.env (names in config/tasks/apps.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("apps|Your own web apps from container images, each with a card on the start page")

# Containers the other rpi-setup tasks run; an app cannot take their names.
apps_reserved_names='pihole samba teamspeak teamspeak-usage netalertx web den-watcher gateway'

# apps_parse LIST - check APPS_LIST and print one "name port container-port
# image" line per app. LIST holds name:port=image entries, or
# name:port:container-port=image when the app does not listen on 8080,
# separated by spaces or commas. Dies naming the entry that is wrong. A name
# is the compose service, the container name and the card's name: lowercase
# letters, digits and -, at least two characters with a letter, so that it
# is a string to YAML (not 123, 1e3, 0x1f, true, null) and a container
# name to Docker (two characters at least), and none of the names the
# other tasks' containers have.
apps_parse() {
  local entry name ports image port cport names=" " used=" "
  local re='^([a-z0-9][a-z0-9-]{1,30}):([0-9]{1,5})(:([0-9]{1,5}))?=(.+)$'
  for entry in ${1//,/ }; do
    [[ "$entry" =~ $re ]] ||
      die "APPS_LIST entries must look like name:port=image, such as game:8091=ghcr.io/you/game:latest, with a name of at least two characters (got '$entry')"
    name="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}" cport="${BASH_REMATCH[4]:-8080}" image="${BASH_REMATCH[5]}"
    [[ "$name" == *[a-z]* ]] ||
      die "APPS_LIST: the name '$name' needs a letter (digits alone are a number to the compose file)"
    case "$name" in
      true|false|yes|no|on|off|null)
        die "APPS_LIST: '$name' means something else to the compose file; pick another name" ;;
    esac
    [[ ! "$name" =~ ^(0x[0-9a-f]+|0o[0-7]+|0b[01]+|[0-9]+e-?[0-9]+)$ ]] ||
      die "APPS_LIST: '$name' means a number to the compose file; pick another name"
    [[ " $apps_reserved_names " != *" $name "* && "$name" != den-watcher-* ]] ||
      die "APPS_LIST: '$name' is the name of a container another rpi-setup task runs; pick another name"
    for ports in "$port" "$cport"; do
      (( 10#$ports >= 1 && 10#$ports <= 65535 )) ||
        die "APPS_LIST: the ports of '$name' must be between 1 and 65535 (got '$entry')"
    done
    [[ "$image" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ ]] ||
      die "APPS_LIST: the image of '$name' must be a Docker image such as repo/name:tag (got '$image')"
    [[ "$names" != *" $name "* ]] || die "APPS_LIST names '$name' twice"
    [[ "$used" != *" $((10#$port)) "* ]] || die "APPS_LIST: port $port is used by two apps"
    names+="$name " used+="$((10#$port)) "
    printf '%s %s %s %s\n' "$name" "$((10#$port))" "$((10#$cport))" "$image"
  done
}

# apps_data_parse DATA NAMES - check APPS_DATA against the app names in
# NAMES (space separated) and print the apps that keep data, one per line.
# DATA holds app names separated by spaces or commas.
apps_data_parse() {
  local name seen=" "
  for name in ${1//,/ }; do
    [[ " $2 " == *" $name "* ]] ||
      die "APPS_DATA: '$name' is not an app in APPS_LIST; list only apps that APPS_LIST runs"
    [[ "$seen" != *" $name "* ]] || continue
    seen+="$name "
    printf '%s\n' "$name"
  done
}

# apps_build_parse BUILD NAMES - check APPS_BUILD against the app names in
# NAMES (space separated) and print one "name url ref" line per app to build
# on the Pi. BUILD holds name=url#ref entries, separated by spaces or commas:
# url is a git repository over https, ref a branch, tag or commit (7 to 40
# hex digits); without #ref the repository's default branch (ref HEAD).
apps_build_parse() {
  local entry name url ref seen=" "
  local re='^([a-z0-9][a-z0-9-]*)=(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/-]+)(#(.+))?$'
  for entry in ${1//,/ }; do
    [[ "$entry" =~ $re ]] ||
      die "APPS_BUILD entries must look like name=https://host/repo.git#ref, such as game=https://github.com/you/game.git#main (got '$entry')"
    name="${BASH_REMATCH[1]}" url="${BASH_REMATCH[2]}" ref="${BASH_REMATCH[5]:-HEAD}"
    # A ref git takes as a name of its own: no option, no "..", no "@{".
    [[ "$ref" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ && "$ref" != *..* && "$ref" != *.lock && "$ref" != */ ]] ||
      die "APPS_BUILD: '$ref' of '$name' is not a branch, tag or commit"
    [[ "$url" != *..* ]] || die "APPS_BUILD: the address of '$name' must not contain '..' (got '$url')"
    [[ " $2 " == *" $name "* ]] ||
      die "APPS_BUILD: '$name' is not an app in APPS_LIST; list the app there with its port, and any image"
    [[ "$seen" != *" $name "* ]] || die "APPS_BUILD names '$name' twice"
    seen+="$name "
    printf '%s %s %s\n' "$name" "$url" "$ref"
  done
}

# apps_git DIR TOKEN ARGS... - git in DIR, never waiting for a password. A
# TOKEN goes to the server as an HTTP header from the environment, so it is
# never written to the repository's config or shown in the process list.
apps_git() {
  local dir="$1" token="$2"
  shift 2
  if [[ -n "$token" ]]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)" \
      GIT_TERMINAL_PROMPT=0 git -C "$dir" "$@"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$dir" "$@"
  fi
}

# apps_checkout DIR URL REF [TOKEN] - fetch the repository URL into DIR (a
# git checkout of its own, made when missing or when it holds another
# repository) and check out REF, with nothing else in the folder; prints the
# commit. Only the history is fetched in full, file contents only for the
# commit checked out. REF is looked up as a branch, then a tag, then a commit.
apps_checkout() {
  local dir="$1" url="$2" ref="$3" token="${4:-}" sha
  if [[ "$(git -C "$dir" config --get remote.origin.url 2>/dev/null)" != "$url" ]]; then
    rm -rf "$dir"
    install -m 0700 -d "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" config remote.origin.promisor true
    git -C "$dir" config remote.origin.partialclonefilter blob:none
  fi
  apps_git "$dir" "$token" fetch --quiet --prune --force --filter=blob:none origin \
    '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' '+HEAD:refs/remotes/origin/HEAD' ||
    die "Could not fetch $url; check the address, the network and, for a private repository, APPS_BUILD_TOKEN"
  sha="$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" ||
    git -C "$dir" rev-parse --verify --quiet "refs/tags/$ref^{commit}" ||
    { [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] && git -C "$dir" rev-parse --verify --quiet "$ref^{commit}"; })" ||
    die "'$ref' is no branch, tag or commit of $url"
  apps_git "$dir" "$token" -c advice.detachedHead=false checkout --quiet --force --detach "$sha" ||
    die "Could not check out ${sha:0:7} of $url"
  git -C "$dir" clean -qffdx
  printf '%s\n' "$sha"
}

# apps_prebuilt IMAGE DIR SHA - a published image of commit SHA (checked out
# in DIR) in IMAGE's repository, pulled and printed: IMAGE's repository with
# the tag sha-<first 7 digits>, as a CI publishes a commit, or with a release
# tag of the commit (its git tag without a leading v, such as 1.2.3 for
# v1.2.3). False when the registry has none of them.
apps_prebuilt() {
  local image="$1" dir="$2" sha="$3" repo tag
  repo="${image%@*}"
  [[ "${repo##*/}" != *:* ]] || repo="${repo%:*}"
  local -a tags=("sha-${sha:0:7}")
  while read -r tag; do
    tag="${tag#v}"
    [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] && tags+=("$tag")
  done < <(git -C "$dir" tag --points-at "$sha" 2>/dev/null)
  for tag in "${tags[@]}"; do
    if docker pull -q "$repo:$tag" >/dev/null 2>&1; then
      printf '%s\n' "$repo:$tag"
      return 0
    fi
  done
  return 1
}

# apps_compose UID [DATA] [BUILT] < "name port container-port image" lines -
# the compose file: one container per app, named after it, published on its
# port, with labels that give it a card on the web task's start page. Every app
# runs as UID (not root), with no capabilities, a read-only file system and
# only /tmp writable (in memory), so it keeps nothing between restarts; an app
# named in DATA (space separated) also gets its folder under DIR/data as /data.
# An app named in BUILT (space separated) is built on the Pi from its checkout
# DIR/build/<name>; its "image" is then the source shown on its card.
apps_compose() {
  local uid="$1" data=" ${2:-} " built=" ${3:-} " name port cport image from
  echo 'services:'
  while read -r name port cport image; do
    if [[ "$built" == *" $name "* ]]; then
      from="App built from $image"
      printf '  %s:\n    build:\n      context: "./build/%s"\n' "$name" "$name"
    else
      from="App from $image"
      printf '  %s:\n    image: "%s"\n' "$name" "$image"
    fi
    cat <<EOF2
    container_name: $name
    restart: unless-stopped
    labels:
      rpi-setup.link.name: "$name"
      rpi-setup.link.description: "$from"
      rpi-setup.link.port: "$port"
    ports:
      - "0.0.0.0:$port:$cport"
    user: "$uid:$uid"
    read_only: true
    tmpfs:
      - "/tmp:mode=1700,uid=$uid,gid=$uid,rw,nosuid,nodev,noexec"
    volumes:
      - /etc/localtime:/etc/localtime:ro
EOF2
    if [[ "$data" == *" $name "* ]]; then
      printf '      - "./data/%s:/data"\n' "$name"
    fi
    cat <<EOF2
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
  done
}

# apps_port_container PORT - prints the name of the container that publishes
# PORT (its docker-proxy holds the port); false if Docker knows none.
apps_port_container() { container_port_holder "$1"; }

run_apps() {
  local apps dir
  dir="$(container_dir apps)"
  apps="$(apps_parse "${APPS_LIST:-}")"
  if [[ -z "$apps" ]]; then
    # An emptied list takes the apps down; the compose file is renamed so
    # update.sh, the firewall and check.sh no longer see them. With none
    # running there is nothing to do: a deploy that still lists the task
    # must not fail.
    if [[ -f "$dir/docker-compose.yml" ]]; then
      docker compose -f "$dir/docker-compose.yml" down --remove-orphans ||
        die "Could not stop the apps in $dir; stop them with: cd $dir && sudo docker compose down"
      mv -f "$dir/docker-compose.yml" "$dir/docker-compose.yml.disabled"
      say 'APPS_LIST is empty: stopped the apps'
      return 0
    fi
    info 'APPS_LIST is empty and no apps are running; to run some, list them as name:port=image, such as game:8091=ghcr.io/you/game:latest'
    return 0
  fi

  # The port may already be ours (Docker's proxy for one of the apps);
  # another container's proxy or anything else holds it. Found here, not at
  # "up", which would take every app down.
  local name port cport image owner holder names=" "
  while read -r name port cport image; do names+="$name "; done <<<"$apps"
  local data
  data="$(apps_data_parse "${APPS_DATA:-}" "$names")"
  while read -r name port cport image; do
    owner="$(port_owner "$port")" || owner=""
    if [[ "$owner" == docker-proxy ]]; then
      holder="$(apps_port_container "$port")" || holder=""
      [[ -z "$holder" || " $names " == *" $holder "* ]] ||
        die "Port $port of '$name' is published by the $holder container; pick a free port in APPS_LIST"
    elif [[ -n "$owner" ]]; then
      die "Port $port of '$name' is used by $owner; pick a free port in APPS_LIST"
    fi
  done <<<"$apps"

  local builds token=""
  builds="$(apps_build_parse "${APPS_BUILD:-}" "$names")"
  if [[ -n "${APPS_BUILD_TOKEN:-}" ]]; then
    [[ "$APPS_BUILD_TOKEN" =~ ^[A-Za-z0-9_]+$ ]] ||
      die 'APPS_BUILD_TOKEN has characters a GitHub token does not have'
    token="$APPS_BUILD_TOKEN"
  fi

  container_require_64bit APPS_LIST
  container_require_docker

  local uid
  uid="$(assign_uid apps)"
  install -m 0755 -d "$dir"
  # Each app that keeps data gets its own folder, only for its user. It stays
  # when the app leaves APPS_DATA or APPS_LIST; the backup task saves it with
  # the rest of $dir.
  for name in $data; do
    install -m 0700 -o "$uid" -g "$uid" -d "$dir/data/$name"
  done

  # Apps from git: each repository is checked out in DIR/build/<name> (root
  # only). When the registry of the app's image in APPS_LIST already has an
  # image of that commit, the app runs it; otherwise the checkout is the
  # build's context and the app is built here, its card naming the commit.
  # Checkouts of apps no longer in APPS_BUILD are removed.
  local built="" fetched="" url ref sha prebuilt
  if [[ -n "$builds" ]]; then
    if [[ -n "$token" ]]; then
      save_secret apps APPS_BUILD_TOKEN "$token"
    else
      token="$(load_secret apps APPS_BUILD_TOKEN)" || token=""
    fi
    have git || apt_install git
    install -m 0700 -d "$dir/build"
    while read -r name url ref; do
      info "Fetching $name from $url ($ref)"
      sha="$(apps_checkout "$dir/build/$name" "$url" "$ref" "$token")"
      fetched+="$name "
      image="$(awk -v n="$name" '$1 == n { print $4 }' <<<"$apps")"
      if prebuilt="$(apps_prebuilt "$image" "$dir/build/$name" "$sha")"; then
        say "$name: ${sha:0:7} of $url, published as $prebuilt"
      else
        say "$name: ${sha:0:7} of $url, no published image of it; building it here"
        built+="$name "
        prebuilt="$url@${sha:0:7}"
      fi
      apps="$(awk -v n="$name" -v src="$prebuilt" '$1 == n { $4 = src } { print }' <<<"$apps")"
    done <<<"$builds"
  fi
  if [[ -d "$dir/build" ]]; then
    for sha in "$dir"/build/*/; do
      [[ -d "$sha" && " $fetched " != *" $(basename "$sha") "* ]] || continue
      rm -rf "$sha"
      info "Removed the checkout of $(basename "$sha"), which is no longer in APPS_BUILD"
    done
  fi

  apps_compose "$uid" "${data//$'\n'/ }" "$built" <<<"$apps" | write_if_changed "$dir/docker-compose.yml" 0644 || true

  # Pulling every run brings a moving tag such as :latest up to date (the
  # apps built here are skipped); "up" then recreates only the apps whose
  # image or settings changed, and --remove-orphans takes down the ones no
  # longer listed. The apps built here are built again first, with their
  # base images pulled; an unchanged checkout comes from the build cache.
  container_pull "$dir"
  if [[ -n "$built" ]]; then
    info "Building $built"
    # shellcheck disable=SC2086 # one word per app
    docker compose -f "$dir/docker-compose.yml" build --pull $built ||
      die "Could not build $built; see the build output above"
  fi
  container_up "$dir" "$(head -n1 <<<"$apps" | cut -d' ' -f1)"
  while read -r name port cport image; do
    container_wait_stable "$name" ||
      container_fail "$dir" "$name" "The $name container does not stay up"
    say "$name is running: $(service_url "$port")"
  done <<<"$apps"
}
