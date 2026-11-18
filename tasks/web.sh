#!/usr/bin/env bash
# Task: web - nginx web server serving a simple index page.
# Settings: WEB_* in config/rpi-setup.env (names in config/tasks/web.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("web|nginx with a start page on port 80 linking the web pages on this Pi")

run_web() {
  : "${WEB_TITLE:=Raspberry Pi}" "${WEB_DOCKER:=no}" "${WEB_UPDATES:=yes}"
  [[ -z "${WEB_PORT:-}" ]] || require_port WEB_PORT
  setting_on WEB_UPDATES || :  # dies unless yes or no
  [[ "$WEB_TITLE" != *[\<\>\&]* ]] || die "WEB_TITLE cannot contain <, > or & (got '$WEB_TITLE')"
  if setting_on WEB_DOCKER; then run_web_container; return; fi
  container_leave web
  local site=/etc/nginx/sites-available/default owner want cur
  want="$(web_port "$(nginx_site_port "$site" || true)")"

  if ! apt_installed nginx; then
    owner="$(port_owner 80)" || owner=""
    if [[ -n "$owner" ]]; then
      # Something else holds port 80. nginx's postinst would fail to start on
      # it and abort the install, so keep the service down during install
      # and move the default site elsewhere.
      info "Port 80 is used by '$owner'; nginx will listen on $want instead"
      local own_policy=0 prev_trap=""
      if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
        chmod 0755 /usr/sbin/policy-rc.d
        own_policy=1
        # Left in place, the file would stop every apt package from starting
        # its service, so an interrupted run removes it too: in front of the
        # EXIT trap setup.sh set (its log), which stays.
        web_exit_trap prev_trap
        # shellcheck disable=SC2064 # expanded now on purpose
        trap "rm -f /usr/sbin/policy-rc.d${prev_trap:+; $prev_trap}" EXIT
      fi
      local rc=0
      apt_install nginx || rc=$?
      if [[ $own_policy -eq 1 ]]; then
        rm -f /usr/sbin/policy-rc.d
        # shellcheck disable=SC2064  # the saved trap string is put back as it was
        if [[ -n "$prev_trap" ]]; then trap "$prev_trap" EXIT; else trap - EXIT; fi
      fi
      [[ $rc -eq 0 ]] || die 'nginx install failed'
    else
      apt_install nginx
    fi
  fi

  cur="$(nginx_site_port "$site")" ||
    die "nginx's default site $site is missing, but the start page is served from it. Restore it with: sudo apt-get install --reinstall -o Dpkg::Options::=--force-confmiss nginx-common"
  if [[ -n "$cur" && "$want" != "$cur" ]]; then
    owner="$(port_owner "$want")" || owner=""
    if [[ -n "$owner" && "$owner" != nginx ]]; then
      die "Port $want is already used by '$owner'; set WEB_PORT to a free port"
    fi
    nginx_move_port "$site" "$cur" "$want"
    info "nginx moved from port $cur to $want"
  fi

  web_index_page /var/www/html/index.html
  web_links_install /var/www/html
  web_updates_install /var/www/html

  nginx -t -q || die "nginx configuration test failed; check $site"
  systemctl enable --now nginx
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  web_links_refresh

  say "nginx running - open $(service_url "$(nginx_site_port "$site")") in your browser"
}

# Sets $1 to the command of the current EXIT trap (setup.sh's stop_log), or
# to nothing. Not in $( ): a subshell has no traps to print.
web_exit_trap() {
  local -n _web_exit_trap="$1"
  local t
  t="$(trap -p EXIT)"
  t="${t#trap -- \'}"
  t="${t%\' EXIT}"
  _web_exit_trap="${t//\'\\\'\'/\'}"
}

# The line that marks the start page as rpi-setup's (second line of the
# page). The page is rewritten while it holds it and left alone once it is
# removed. Pages written before the marker existed are told apart by their
# footer line (RPI_WEB_PAGE_OLD_FOOTER) and marked once, with a copy of the old
# page kept next to them.
RPI_WEB_PAGE_MARK='<!-- Written by rpi-setup (tasks/web.sh). Remove this line to keep your own edits to this page. -->'
RPI_WEB_PAGE_OLD_FOOTER='<footer>Provisioned by <a href="https://github.com/Programmer-Den/rpi-setup">rpi-setup</a>.'

# The page is (re)written while it is ours (it holds RPI_WEB_PAGE_MARK) or
# missing; a page you put there yourself, or ours without the marker line,
# is never overwritten. Either way the service list next to it
# (services.json) is kept up to date by web_links_install.
web_index_page() {
  local f="$1" page
  if [[ -f "$f" ]] && ! grep -qF "$RPI_WEB_PAGE_MARK" "$f"; then
    if ! grep -qF "$RPI_WEB_PAGE_OLD_FOOTER" "$f"; then
      info "$f is your own page; leaving it alone"
      return
    fi
    # A page from before the marker: rewritten this once, with the old one
    # kept in case it was edited.
    cp -p "$f" "$f.old"
    info "$f was written by an older rpi-setup; the old page is kept as $f.old"
  fi
  page="$(web_index_html)"
  page="${page//@MARK@/"$RPI_WEB_PAGE_MARK"}"
  printf '%s\n' "${page//@TITLE@/"$WEB_TITLE"}" | write_if_changed "$f" 0644 || true
}

# The start page, with @TITLE@ for WEB_TITLE. It follows the browser's light
# or dark setting, lists the web pages from services.json, linked on the
# address the page was opened with, and the Docker containers from
# containers.json (both re-read every 30 seconds).
web_index_html() {
  cat <<'HTML'
<!DOCTYPE html>
@MARK@
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>@TITLE@</title>
<style>
  :root {
    --bg: #f6f7f9; --card: #ffffff; --text: #1d2330; --muted: #5d6677;
    --border: #dfe3ea; --accent: #c51a4a; --up: #1f9d55; --down: #b4262e; --wait: #b7791f;
    --chart: #c51a4a;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #12151b; --card: #1b2029; --text: #e7eaf0; --muted: #9aa3b2;
      --border: #2c3340; --accent: #ff5c86; --up: #3ccf7f; --down: #ff6b6b; --wait: #f0b429;
      --chart: #f0457a;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; background: var(--bg); color: var(--text);
    font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  main { max-width: 960px; margin: 0 auto; padding: 48px 16px; }
  h1 { margin: 0; font-size: 2rem; }
  .host { margin: 4px 0 32px; color: var(--muted); }
  .grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
  .card {
    display: block; padding: 18px 20px; border: 1px solid var(--border); border-radius: 12px;
    background: var(--card); color: inherit; text-decoration: none;
    transition: border-color .15s, transform .15s;
  }
  .card:hover, .card:focus-visible { border-color: var(--accent); transform: translateY(-2px); }
  .name { display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 1.1rem; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); flex: none; }
  .dot.up { background: var(--up); }
  .dot.down { background: var(--down); }
  .dot.wait { background: var(--wait); }
  .desc { margin: 6px 0 10px; color: var(--muted); font-size: .95rem; }
  .addr { color: var(--accent); font-size: .9rem; word-break: break-all; }
  .note { color: var(--muted); }
  h2 { margin: 40px 0 12px; font-size: 1.25rem; }
  .list { border: 1px solid var(--border); border-radius: 12px; background: var(--card); }
  .row {
    display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 2fr) minmax(0, 1fr);
    gap: 4px 16px; align-items: center; padding: 10px 16px;
  }
  .row + .row { border-top: 1px solid var(--border); }
  .row .name { font-size: 1rem; }
  .image, .ports { color: var(--muted); font-size: .9rem; overflow-wrap: anywhere; }
  .ports { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .85rem; }
  .state { color: var(--muted); font-size: .9rem; text-align: right; }
  @media (max-width: 600px) {
    .row { grid-template-columns: minmax(0, 1fr) auto; }
    .row .image { grid-column: 1 / -1; grid-row: 2; }
    .row .state { grid-row: 1; grid-column: 2; }
  }
  .tabs { display: flex; gap: 4px; margin: -12px 0 28px; border-bottom: 1px solid var(--border); }
  .tabs a {
    padding: 8px 14px; margin-bottom: -1px; border-bottom: 2px solid transparent;
    color: var(--muted); text-decoration: none; font-weight: 600;
  }
  .tabs a:hover { color: var(--text); }
  .tabs a.on { color: var(--text); border-bottom-color: var(--accent); }
  .head { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 4px 16px; }
  .head a { color: var(--accent); font-size: .9rem; }
  .row.cols2 { grid-template-columns: minmax(0, 1fr) minmax(0, 3fr); }
  .row.cols2 .name { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .95rem; }
  .row.cols4 { grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 2fr) minmax(0, 1fr); }
  .groups { color: var(--muted); font-size: .9rem; }
  @media (max-width: 600px) {
    .row.cols2 { grid-template-columns: minmax(0, 1fr); }
    .row.cols4 { grid-template-columns: minmax(0, 1fr) auto; }
    .row.cols4 .groups { grid-column: 1 / -1; grid-row: 2; }
    .row.cols4 .image { grid-column: 1 / -1; grid-row: 3; }
    .row.cols4 .state { grid-column: 1 / -1; grid-row: 4; text-align: left; }
    .row.cols4 .state:empty, .row.cols4 .groups:empty, .row.cols4 .image:empty { display: none; }
  }
  .tiles { display: grid; grid-auto-flow: dense; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); }
  .tile { padding: 12px 16px; border: 1px solid var(--border); border-radius: 12px; background: var(--card); }
  .tile .label { color: var(--muted); font-size: .85rem; }
  .tile.wide { grid-column: span 2; }
  .tile .value { font-size: 1.25rem; font-weight: 600; overflow-wrap: anywhere; }
  .note code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .85rem; color: var(--text); }
  .head .note { font-size: .9rem; }
  .welcome { color: var(--muted); margin: 12px 0 0; white-space: pre-line; }
  .bar { height: 8px; border-radius: 4px; background: var(--chart); min-width: 2px; }
  .heat {
    display: grid; grid-template-columns: 2.5em repeat(24, minmax(0, 1fr)); gap: 2px;
    padding: 12px 16px; border: 1px solid var(--border); border-radius: 12px; background: var(--card);
    font-size: 11px; color: var(--muted);
  }
  .heat .cell { height: 18px; border-radius: 3px; background: var(--chart); }
  .heat .cell.zero { background: var(--border); opacity: .5; }
  .heat .hour { grid-row: 1; text-align: left; }
  .legend { display: flex; align-items: center; gap: 6px; margin-top: 8px; color: var(--muted); font-size: .85rem; }
  .legend span.cell { width: 12px; height: 12px; border-radius: 3px; background: var(--chart); }
  .chart {
    position: relative; margin-bottom: 16px; padding: 12px 16px 8px;
    border: 1px solid var(--border); border-radius: 12px; background: var(--card);
  }
  .chart-head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 4px 16px; font-size: .9rem; }
  .chart-head .peak { color: var(--muted); }
  .chart svg { display: block; width: 100%; height: 180px; margin-top: 8px; touch-action: pan-y; }
  .chart .grid { stroke: var(--border); stroke-width: 1; }
  .chart .axis { fill: var(--muted); font-size: 11px; }
  .chart .area { fill: var(--chart); fill-opacity: .1; }
  .chart .line { fill: none; stroke: var(--chart); stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .chart .cursor { stroke: var(--muted); stroke-width: 1; }
  .chart .mark { fill: var(--chart); stroke: var(--card); stroke-width: 2; }
  .tip {
    position: absolute; top: 0; pointer-events: none; padding: 4px 8px; border-radius: 6px;
    background: var(--text); color: var(--bg); font-size: .85rem; white-space: nowrap;
    transform: translate(-50%, -100%);
  }
  footer { margin-top: 48px; color: var(--muted); font-size: .85rem; }
  footer a { color: inherit; }
</style>
</head>
<body>
<main>
  <h1>@TITLE@</h1>
  <p class="host" id="host"></p>
  <nav class="tabs" id="tabs" hidden>
    <a href="#" id="tab-overview">Overview</a>
    <a href="#docker" id="tab-docker" hidden>Docker</a>
    <a href="#teamspeak" id="tab-teamspeak" hidden>TeamSpeak</a>
  </nav>
  <div id="page-overview">
    <div class="grid" id="services"></div>
    <p class="note" id="note">Looking for web pages on this Pi...</p>
    <section id="tasks-box" hidden>
      <div class="head"><h2>Set up on this Pi</h2>
        <a href="https://github.com/Programmer-Den/rpi-setup">rpi-setup on GitHub</a></div>
      <div class="list" id="tasks"></div>
    </section>
    <section id="updates-box" hidden>
      <div class="head"><h2>Updates</h2><span class="note" id="updates-checked"></span></div>
      <div class="list" id="updates"></div>
      <p class="note" id="updates-how" hidden></p>
    </section>
  </div>
  <div id="page-docker" hidden>
    <h2>Docker containers</h2>
    <div class="list" id="containers"></div>
  </div>
  <div id="page-teamspeak" hidden>
    <section id="tsx-server-box">
      <h2 id="tsx-name">Server</h2>
      <div class="tiles" id="tsx-server"></div>
      <p class="welcome" id="tsx-welcome" hidden></p>
    </section>
    <h2>Online now</h2>
    <div class="list" id="tsx-clients"></div>
    <section id="tsx-channels-box">
      <h2>Channels</h2>
      <div class="list" id="tsx-channels"></div>
    </section>
    <h2>History</h2>
    <div class="chart" id="tsx-chart" hidden></div>
    <h2>Busy times</h2>
    <div id="tsx-heat-box"></div>
    <section id="tsx-busy-box">
      <h2>Busiest channels, last 7 days</h2>
      <div class="list" id="tsx-busy"></div>
    </section>
    <h2>Last 7 days</h2>
    <div class="list" id="tsx-users"></div>
    <h2 id="tsx-people-title">Everyone</h2>
    <div class="list" id="tsx-people"></div>
    <section id="tsx-conn-box">
      <h2>Same connection</h2>
      <p class="note">Visitors who connected from the same IP address, named after the nickname used last from it.</p>
      <div class="list" id="tsx-conn"></div>
    </section>
    <h2>Last visits</h2>
    <div class="list" id="tsx-recent"></div>
  </div>
  <noscript><p class="note">Turn on JavaScript to see the web pages on this Pi.</p></noscript>
  <footer>Set up by <a href="https://github.com/Programmer-Den/rpi-setup">rpi-setup</a>.
    New services and containers show up here on their own within a minute.</footer>
</main>
<script>
(function () {
  var grid = document.getElementById('services');
  var note = document.getElementById('note');
  var host = document.getElementById('host');
  var rows = document.getElementById('containers');

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }

  function link(s) {
    var port = Number(s.port) === 80 ? '' : ':' + s.port;
    return 'http://' + location.hostname + port + (s.path || '/');
  }

  function render(data) {
    var list = Array.isArray(data.services) ? data.services : [];
    host.textContent = [data.host, data.ip].filter(Boolean).join(' \u00b7 ');
    grid.textContent = '';
    list.forEach(function (s) {
      var a = el('a', 'card');
      a.href = link(s);
      var name = el('div', 'name');
      var dot = el('span', 'dot' + (s.up === true ? ' up' : s.up === false ? ' down' : ''));
      dot.title = s.up === true ? 'answering' : s.up === false ? 'not answering' : '';
      name.appendChild(dot);
      name.appendChild(document.createTextNode(s.name));
      a.appendChild(name);
      if (s.description) a.appendChild(el('div', 'desc', s.description));
      a.appendChild(el('div', 'addr', a.href.replace(/^http:\/\//, '')));
      grid.appendChild(a);
    });
    note.textContent = list.length ? '' : 'No other web pages on this Pi yet.';
  }

  // "45 s", "12 min", "3 h", "2 d" since the ISO time t, or "" if unknown.
  function since(t) {
    var s = Math.floor((Date.now() - Date.parse(t)) / 1000);
    if (!t || isNaN(s)) return '';
    s = Math.max(s, 0);
    if (s < 60) return s + ' s';
    if (s < 3600) return Math.floor(s / 60) + ' min';
    if (s < 86400) return Math.floor(s / 3600) + ' h';
    return Math.floor(s / 86400) + ' d';
  }

  function containerState(c) {
    var restarts = c.restarts > 0 ? ', ' + c.restarts + (c.restarts === 1 ? ' restart' : ' restarts') : '';
    if (c.state === 'running') {
      var up = since(c.started);
      var health = c.health && c.health !== 'healthy' ? c.health + ', ' : '';
      return {
        dot: c.health === 'unhealthy' ? 'down' : c.health === 'starting' ? 'wait' : 'up',
        text: health + (up ? 'up ' + up : 'running') + restarts
      };
    }
    if (c.state === 'restarting') return { dot: 'wait', text: 'restarting' + restarts };
    var ago = since(c.finished);
    return { dot: c.state === 'created' ? '' : 'down', text: c.state + (ago ? ' ' + ago + ' ago' : '') };
  }

  var lastContainers = null, newImage = {};
  function renderContainers(data) {
    lastContainers = data;
    var list = Array.isArray(data.containers) ? data.containers : [];
    showTabLink('docker', list.length > 0);
    rows.textContent = '';
    list.forEach(function (c) {
      var st = containerState(c);
      var row = el('div', 'row');
      var name = el('div', 'name');
      var dot = el('span', 'dot' + (st.dot ? ' ' + st.dot : ''));
      dot.title = c.state + (c.health ? ', ' + c.health : '');
      name.appendChild(dot);
      name.appendChild(document.createTextNode(c.name));
      row.appendChild(name);
      var image = el('div', 'image', c.image);
      var ports = (c.ports || []).join(' ') || (c.network === 'host' ? 'host network' : '');
      if (ports) image.appendChild(el('div', 'ports', ports));
      row.appendChild(image);
      row.appendChild(el('div', 'state', st.text + (newImage[c.name] ? ' \u00b7 update available' : '')));
      rows.appendChild(row);
    });
  }

  // The rpi-setup tasks that ran on this Pi, from tasks.json.
  function renderTasks(data) {
    var list = Array.isArray(data.tasks) ? data.tasks : [];
    document.getElementById('tasks-box').hidden = !list.length;
    fill('tasks', list, function (box, t) {
      var row = el('div', 'row cols2');
      row.appendChild(el('div', 'name', t.name));
      row.appendChild(el('div', 'image', t.description));
      box.appendChild(row);
    });
  }

  // What is installed and what is newest for one entry of updates.json.
  function updateInfo(u) {
    var newer = u.update === true && u.latest;
    if (u.kind === 'container') return u.image || '';
    if (u.kind === 'git') {
      return (u.branch ? 'branch ' + u.branch + ' at ' : 'at ') + u.current + (newer ? ', newest ' + u.latest : '');
    }
    if (u.kind === 'apt') {
      var names = Array.isArray(u.packages) ? u.packages : [];
      if (!u.count) return 'All packages are current';
      return plural(u.count, 'package', 'packages') + (u.security ? ', ' + u.security + ' from security updates' : '') +
        (names.length ? ': ' + names.slice(0, 12).join(', ') + (u.count > 12 ? ', ...' : '') : '');
    }
    return (u.current || '') + (newer ? '; newest: ' + u.latest : '');
  }

  // The Updates section, from updates.json, which the Pi rewrites every
  // 6 hours. Containers with a newer image are marked on the Docker tab too.
  function renderUpdates(data) {
    var items = Array.isArray(data.items) ? data.items : [];
    var due = items.filter(function (u) { return u.update === true; });
    document.getElementById('updates-box').hidden = !items.length;
    var ago = since(data.checked);
    document.getElementById('updates-checked').textContent =
      (due.length ? plural(due.length, 'update', 'updates') + ' available' : 'Everything is up to date') +
      (ago ? ', checked ' + ago + ' ago' : '');
    fill('updates', items, function (list, u) {
      var row = el('div', 'row');
      var name = el('div', 'name');
      var dot = el('span', 'dot' + (u.update === true ? ' wait' : u.update === false ? ' up' : ''));
      dot.title = u.update === true ? 'update available' : u.update === false ? 'up to date' : 'could not check';
      name.appendChild(dot);
      name.appendChild(document.createTextNode(u.name));
      row.appendChild(name);
      row.appendChild(el('div', 'image', updateInfo(u)));
      row.appendChild(el('div', 'state', dot.title));
      list.appendChild(row);
    });
    // rpi-setup itself first (git pull), then everything else (update.sh).
    var how = document.getElementById('updates-how');
    how.hidden = !due.length;
    how.textContent = 'Install them on the Pi, in the rpi-setup folder: ';
    if (due.some(function (u) { return u.kind === 'git'; })) {
      how.appendChild(el('code', '', 'git pull'));
      how.appendChild(document.createTextNode(', then '));
    }
    how.appendChild(el('code', '', 'sudo bash update.sh'));
    newImage = {};
    items.forEach(function (u) { if (u.kind === 'container' && u.update === true) newImage[u.name] = true; });
    if (lastContainers) renderContainers(lastContainers);
  }

  // "<1 min", "12 min", "3 h 5 min", "2 d 4 h" for s seconds.
  function duration(s) {
    var m = Math.floor(s / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
    if (m < 1) return '<1 min';
    if (h < 1) return m + ' min';
    if (d < 1) return h + ' h' + (m % 60 ? ' ' + m % 60 + ' min' : '');
    return d + ' d' + (h % 24 ? ' ' + h % 24 + ' h' : '');
  }

  function clock(t, day) {
    var o = { hour: '2-digit', minute: '2-digit' };
    if (day) { o.weekday = 'short'; o.day = 'numeric'; o.month = 'short'; }
    return new Date(t).toLocaleString([], o);
  }

  // A row of a TeamSpeak list: name with a dot, server groups, details and a
  // right-hand note. o: { nick, dot ('up', 'wait' or ''), groups, info,
  // right, indent }.
  function tsRow(list, o) {
    var row = el('div', 'row cols4');
    var name = el('div', 'name');
    if (o.indent) name.style.paddingLeft = (o.indent * 16) + 'px';
    if (o.dot !== null) {
      var dot = el('span', 'dot' + (o.dot ? ' ' + o.dot : ''));
      dot.title = o.dot === 'up' ? 'online' : o.dot === 'wait' ? 'away' : 'offline';
      name.appendChild(dot);
    }
    name.appendChild(document.createTextNode(o.nick));
    row.appendChild(name);
    row.appendChild(el('div', 'groups', (o.groups || []).join(', ')));
    var info = el('div', 'image', typeof o.info === 'string' ? o.info : '');
    if (o.info && typeof o.info !== 'string') info.appendChild(o.info);
    row.appendChild(info);
    row.appendChild(el('div', 'state', o.right || ''));
    list.appendChild(row);
  }

  function fill(id, items, each, empty) {
    var list = document.getElementById(id);
    list.textContent = '';
    (items || []).forEach(function (x) { each(list, x); });
    if (!list.childNodes.length && empty) list.appendChild(el('div', 'row', empty));
    return list;
  }

  function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }

  function bytes(n) {
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    n = Number(n) || 0;
    while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
    return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + ' ' + u[i];
  }

  // Step chart of how many were online at once: points are [epoch seconds,
  // count] where the count changes, from 7 days ago to now. One per box.
  var charts = [];
  function makeChart(box) {
    box.innerHTML = '<div class="chart-head"><span>Online at the same time, last 7 days</span>' +
      '<span class="peak"></span></div><svg role="img"></svg><div class="tip" hidden></div>';
    var svg = box.querySelector('svg'), tip = box.querySelector('.tip');
    var peakText = box.querySelector('.peak');
    var pts = [], scale = null, cur = null, mark = null;

    function countAt(t) {
      var c = 0;
      for (var i = 0; i < pts.length && pts[i][0] <= t; i++) c = pts[i][1];
      return c;
    }

    function draw() {
      if (pts.length < 2 || box.hidden || !svg.clientWidth) return;
      var W = svg.clientWidth, H = 180, L = 28, R = 6, T = 8, B = 22;
      var t0 = pts[0][0], t1 = pts[pts.length - 1][0], max = 1, i, c, out = '';
      pts.forEach(function (p) { max = Math.max(max, p[1]); });
      var step = Math.ceil(max / 4), top = Math.ceil(max / step) * step;
      var x = function (t) { return L + (t - t0) / Math.max(t1 - t0, 1) * (W - L - R); };
      var y = function (n) { return T + (1 - n / top) * (H - T - B); };
      scale = { x: x, y: y, t0: t0, t1: t1, L: L, R: R, W: W };
      svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
      for (c = 0; c <= top; c += step) {
        out += '<line class="grid" x1="' + L + '" x2="' + (W - R) + '" y1="' + y(c) + '" y2="' + y(c) + '"/>';
        out += '<text class="axis" x="' + (L - 8) + '" y="' + (y(c) + 4) + '" text-anchor="end">' + c + '</text>';
      }
      // A day name under the middle of each day.
      var d = new Date(t0 * 1000);
      d.setHours(12, 0, 0, 0);
      for (; d.getTime() / 1000 <= t1; d.setDate(d.getDate() + 1)) {
        var noon = d.getTime() / 1000;
        if (noon < t0) continue;
        out += '<text class="axis" x="' + x(noon) + '" y="' + (H - 4) + '" text-anchor="middle">' +
          d.toLocaleDateString([], { weekday: 'short' }) + '</text>';
      }
      var line = 'M' + x(t0) + ' ' + y(pts[0][1]);
      for (i = 1; i < pts.length; i++) line += 'H' + x(pts[i][0]) + 'V' + y(pts[i][1]);
      out += '<path class="area" d="' + line + 'V' + y(0) + 'H' + x(t0) + 'Z"/>';
      out += '<path class="line" d="' + line + '"/>';
      out += '<line class="cursor" y1="' + T + '" y2="' + y(0) + '" visibility="hidden"/>';
      out += '<circle class="mark" r="4" visibility="hidden"/>';
      svg.innerHTML = out;
      cur = svg.querySelector('.cursor');
      mark = svg.querySelector('.mark');
    }

    function hover(ev) {
      if (!scale || !cur) return;
      var r = svg.getBoundingClientRect();
      var px = Math.min(Math.max((ev.touches ? ev.touches[0] : ev).clientX - r.left, scale.L), scale.W - scale.R);
      var t = scale.t0 + (px - scale.L) / (scale.W - scale.L - scale.R) * (scale.t1 - scale.t0);
      var n = countAt(t);
      cur.setAttribute('x1', px); cur.setAttribute('x2', px); cur.setAttribute('visibility', 'visible');
      mark.setAttribute('cx', px); mark.setAttribute('cy', scale.y(n)); mark.setAttribute('visibility', 'visible');
      tip.textContent = clock(t * 1000, true) + ' · ' + n + ' online';
      tip.hidden = false;
      // Centered over the cursor, but kept inside the chart box.
      var b = box.getBoundingClientRect(), half = tip.offsetWidth / 2;
      tip.style.left = Math.min(Math.max(r.left - b.left + px, half), b.width - half) + 'px';
      tip.style.top = (r.top - b.top + scale.y(n) - 8) + 'px';
    }

    function unhover() {
      tip.hidden = true;
      if (cur) { cur.setAttribute('visibility', 'hidden'); mark.setAttribute('visibility', 'hidden'); }
    }

    svg.addEventListener('mousemove', hover);
    svg.addEventListener('touchstart', hover, { passive: true });
    svg.addEventListener('touchmove', hover, { passive: true });
    svg.addEventListener('mouseleave', unhover);
    svg.addEventListener('touchend', unhover);

    var chart = {
      draw: draw,
      render: function (points) {
        pts = (Array.isArray(points) ? points : []).filter(function (p) {
          return Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]);
        });
        box.hidden = pts.length < 2;
        if (box.hidden) return;
        var peak = pts[0];
        pts.forEach(function (p) { if (p[1] > peak[1]) peak = p; });
        var text = peak[1] ? 'Peak: ' + peak[1] + ' online, ' + clock(peak[0] * 1000, true)
          : 'Nobody was online in the last 7 days.';
        peakText.textContent = text;
        svg.setAttribute('aria-label', 'How many people were online at the same time over the last 7 days. ' + text);
        unhover();
        draw();
      }
    };
    charts.push(chart);
    return chart;
  }
  var chartTab = makeChart(document.getElementById('tsx-chart'));
  window.addEventListener('resize', function () { charts.forEach(function (c) { c.draw(); }); });

  // Average number online per weekday and hour. The data is in UTC (Monday
  // 0:00 first); the grid is shown in the browser's time zone.
  function renderHeat(cells) {
    var box = document.getElementById('tsx-heat-box');
    box.textContent = '';
    if (!Array.isArray(cells) || cells.length !== 168) return;
    var shift = Math.round(-new Date().getTimezoneOffset() / 60), max = 0, d, h;
    cells.forEach(function (v) { max = Math.max(max, Number(v) || 0); });
    var grid = el('div', 'heat');
    grid.appendChild(el('span', '', ''));
    for (h = 0; h < 24; h++) grid.appendChild(el('span', 'hour', h % 6 ? '' : String(h)));
    var days = [], ref = new Date(2024, 0, 1); // a Monday
    for (d = 0; d < 7; d++) {
      days.push(new Date(ref.getFullYear(), 0, 1 + d).toLocaleDateString([], { weekday: 'short' }));
    }
    for (d = 0; d < 7; d++) {
      grid.appendChild(el('span', '', days[d]));
      for (h = 0; h < 24; h++) {
        var v = Number(cells[(((d * 24 + h - shift) % 168) + 168) % 168]) || 0;
        var cell = el('span', 'cell' + (v ? '' : ' zero'));
        if (v) cell.style.opacity = (0.15 + 0.85 * v / max).toFixed(2);
        cell.title = days[d] + ' ' + h + ':00–' + (h + 1) + ':00 · ' +
          (v ? v.toFixed(1) + ' online on average' : 'nobody');
        grid.appendChild(cell);
      }
    }
    box.appendChild(grid);
    var legend = el('div', 'legend', 'Average people online per hour: fewer ');
    [0.15, 0.45, 0.75, 1].forEach(function (o) {
      var c = el('span', 'cell'); c.style.opacity = o; legend.appendChild(c);
    });
    legend.appendChild(document.createTextNode(' more (most: ' + max.toFixed(1) + ')'));
    box.appendChild(legend);
  }

  function clientState(c) {
    var parts = ['online ' + since(c.since)];
    if (c.away) parts.push('away' + (c.away_message ? ': ' + c.away_message : ''));
    if (c.input_off) parts.push('mic off'); else if (c.input_muted) parts.push('mic muted');
    if (c.output_off) parts.push('sound off'); else if (c.output_muted) parts.push('sound muted');
    if (c.talking) parts.push('talking');
    if (c.recording) parts.push('recording');
    if (c.idle_seconds >= 60) parts.push('idle ' + duration(c.idle_seconds));
    return parts.join(' · ');
  }

  // host:port, with an IPv6 address in brackets.
  function hostPort(h, port) { return (h.indexOf(':') >= 0 && h[0] !== '[' ? '[' + h + ']' : h) + ':' + port; }

  // The server tiles. pub: the address people on the internet connect to,
  // lanPort: the voice port on the Pi (both from teamspeak.json).
  function renderServer(sv, pub, lanPort) {
    var tiles = [], up = sv.status ? sv.status === 'online' : null;
    if (sv.status) tiles.push(['Status', sv.status]);
    if (sv.clients_online !== undefined) {
      var users = Math.max(0, (Number(sv.clients_online) || 0) - (Number(sv.query_clients_online) || 0));
      tiles.push(['People online', users + (sv.max_clients ? ' / ' + sv.max_clients : '')]);
    }
    if (sv.uptime !== undefined) tiles.push(['Uptime', duration(Number(sv.uptime) || 0)]);
    if (sv.ping !== undefined) tiles.push(['Average ping', Math.round(Number(sv.ping) || 0) + ' ms']);
    if (sv.packet_loss !== undefined) tiles.push(['Packet loss', ((Number(sv.packet_loss) || 0) * 100).toFixed(1) + ' %']);
    if (sv.bandwidth_sent !== undefined) tiles.push(['Upload, last minute', bytes(sv.bandwidth_sent) + '/s']);
    if (sv.bandwidth_received !== undefined) tiles.push(['Download, last minute', bytes(sv.bandwidth_received) + '/s']);
    if (sv.bytes_sent !== undefined) tiles.push(['Sent in total', bytes(sv.bytes_sent)]);
    if (sv.bytes_received !== undefined) tiles.push(['Received in total', bytes(sv.bytes_received)]);
    if (sv.channels !== undefined) tiles.push(['Channels', String(sv.channels)]);
    if (sv.client_connections !== undefined) tiles.push(['Connections ever', String(sv.client_connections)]);
    if (sv.reserved_slots) tiles.push(['Reserved slots', String(sv.reserved_slots)]);
    var port = lanPort || sv.port;
    if (pub.address && (pub.port || port)) {
      tiles.push(['Internet address', hostPort(pub.address, pub.port || port),
        pub.checked ? 'Checked ' + since(pub.checked) + ' ago' : '']);
      if (pub.ip && pub.ip !== pub.address) tiles.push(['Public IP', pub.ip]);
      else if (!pub.ip) tiles.push(['Public IP', 'does not resolve']);
    }
    if (port) tiles.push([pub.address ? 'LAN address' : 'Address', hostPort(location.hostname, port)]);
    if (sv.version) tiles.push(['Version', String(sv.version).split(' [')[0]]);
    if (sv.platform) tiles.push(['Platform', String(sv.platform)]);
    if (sv.created) tiles.push(['Created', new Date(sv.created * 1000).toLocaleDateString()]);
    document.getElementById('tsx-name').textContent = sv.name ? 'Server: ' + sv.name : 'Server';
    fill('tsx-server', tiles, function (list, t) {
      var tile = el('div', String(t[1]).length > 12 ? 'tile wide' : 'tile');
      if (t[2]) tile.title = t[2];
      tile.appendChild(el('div', 'label', t[0]));
      var value = el('div', 'value', t[1]);
      if (t[0] === 'Status' && up !== null) {
        var dot = el('span', 'dot ' + (up ? 'up' : 'down'));
        dot.style.display = 'inline-block'; dot.style.marginRight = '8px';
        value.insertBefore(dot, value.firstChild);
      }
      tile.appendChild(value);
      list.appendChild(tile);
    });
    document.getElementById('tsx-server-box').hidden = !tiles.length;
    var welcome = document.getElementById('tsx-welcome');
    welcome.textContent = sv.welcome || '';
    welcome.hidden = !sv.welcome;
  }

  function weekRow(list, u) {
    tsRow(list, { nick: u.nick, dot: u.online ? 'up' : '', groups: u.groups,
      info: duration(u.week_seconds) + ' in the last 7 days, ' + plural(u.week_visits, 'visit', 'visits'),
      right: u.online ? 'online now' : 'seen ' + since(u.last_seen) + ' ago' });
  }

  function visitRow(list, v) {
    var secs = (Date.parse(v.end) - Date.parse(v.start)) / 1000;
    tsRow(list, { nick: v.nick, dot: '', groups: v.groups,
      info: clock(v.start, true) + ' – ' + clock(v.end, false), right: duration(secs) });
  }

  // The TeamSpeak tab, from teamspeak.json.
  function renderTeamspeak(data) {
    var online = Array.isArray(data.online) ? data.online : [];
    var users = Array.isArray(data.users) ? data.users : [];
    var recent = Array.isArray(data.recent) ? data.recent : [];
    showTabLink('teamspeak', true);
    chartTab.render(data.concurrent);
    renderServer(data.server || {}, data.public || {}, data.voice_port);
    var clients = Array.isArray(data.clients) && data.clients.length ? data.clients
      : online.map(function (c) { return { nick: c.nick, since: c.since }; });
    fill('tsx-clients', clients, function (list, c) {
      var where = [c.channel, [c.platform, c.version].filter(Boolean).join(' '), c.country]
        .filter(Boolean).join(' · ');
      tsRow(list, { nick: c.nick, dot: c.away ? 'wait' : 'up', groups: c.groups, info: where,
        right: clientState(c) });
    }, 'Nobody is online right now.');
    var channels = Array.isArray(data.channels) ? data.channels : [];
    fill('tsx-channels', channels, function (list, ch) {
      tsRow(list, { nick: ch.name, dot: null, indent: ch.depth, groups: ch.topic ? [ch.topic] : [],
        info: (ch.clients || []).join(', '), right: ch.clients && ch.clients.length ? plural(ch.clients.length, 'person', 'people') : '' });
    });
    document.getElementById('tsx-channels-box').hidden = !channels.length;
    renderHeat(data.heatmap);
    var busy = Array.isArray(data.busy_channels) ? data.busy_channels : [];
    var most = busy.length ? busy[0].minutes : 1;
    fill('tsx-busy', busy, function (list, b) {
      var bar = el('div', 'bar');
      bar.style.width = Math.max(1, b.minutes / most * 100) + '%';
      tsRow(list, { nick: b.name, dot: null, info: bar, right: duration(b.minutes * 60) });
    });
    document.getElementById('tsx-busy-box').hidden = !busy.length;
    fill('tsx-users', users, weekRow, 'Nobody was online in the last 7 days.');
    var everyone = Array.isArray(data.people) ? data.people : [];
    document.getElementById('tsx-people-title').textContent =
      'Everyone' + (data.days ? ', last ' + data.days + ' days' : '');
    fill('tsx-people', everyone, function (list, p) {
      tsRow(list, { nick: p.nick, dot: p.online ? 'up' : '', groups: p.groups,
        info: duration(p.total_seconds) + ' in total, ' + plural(p.visits, 'visit', 'visits') +
          ', longest ' + duration(p.longest_seconds) + (p.platform ? ', ' + p.platform : ''),
        right: 'first seen ' + since(p.first_seen) + ' ago' +
          (p.online ? ', online now' : ', last ' + since(p.last_seen) + ' ago') });
    });
    var conns = Array.isArray(data.connections) ? data.connections : [];
    fill('tsx-conn', conns, function (list, g) {
      tsRow(list, { nick: g.nick, dot: g.online ? 'up' : '',
        groups: g.others && g.others.length ? ['also ' + g.others.join(', ')] : [],
        info: plural(g.identities, 'identity', 'identities') + ', ' + plural(g.visits, 'visit', 'visits'),
        right: g.online ? 'online now' : 'seen ' + since(g.last_seen) + ' ago' });
    });
    document.getElementById('tsx-conn-box').hidden = !conns.length;
    fill('tsx-recent', recent, visitRow, 'No visits yet.');
  }

  // The tabs: the overview, the Docker tab (#docker) while there are
  // containers and the TeamSpeak tab (#teamspeak) while there is TeamSpeak
  // data. The tab bar shows once there is more than the overview.
  var tabs = document.getElementById('tabs');
  var tabNames = ['overview', 'docker', 'teamspeak'];
  function showTabLink(name, on) {
    var a = document.getElementById('tab-' + name);
    if (a.hidden === !on) return;
    a.hidden = !on;
    tabs.hidden = !tabNames.some(function (n) { return n !== 'overview' && !document.getElementById('tab-' + n).hidden; });
    showTab();
  }
  function showTab() {
    var want = location.hash.slice(1), cur = 'overview';
    if (want !== 'overview' && tabNames.indexOf(want) > 0 && !document.getElementById('tab-' + want).hidden) cur = want;
    tabNames.forEach(function (n) {
      document.getElementById('page-' + n).hidden = n !== cur;
      document.getElementById('tab-' + n).className = n === cur ? 'on' : '';
    });
    charts.forEach(function (c) { c.draw(); });
  }
  window.addEventListener('hashchange', function () { showTab(); window.scrollTo(0, 0); });

  function get(file, done, failed) {
    fetch(file, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(done)
      .catch(failed);
  }

  function load() {
    get('services.json', render, function () {
      note.textContent = 'The list of web pages is not ready yet; it is retried every 30 seconds.';
    });
    get('tasks.json', renderTasks, function () { document.getElementById('tasks-box').hidden = true; });
    get('containers.json', renderContainers, function () { showTabLink('docker', false); });
    get('teamspeak.json', renderTeamspeak, function () { showTabLink('teamspeak', false); });
    get('updates.json', renderUpdates, function () { renderUpdates({}); });
  }

  showTab();
  load();
  setInterval(load, 30000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) load(); });
})();
</script>
</body>
</html>
HTML
}

# --- Service list (services.json for the start page) ----------------------

RPI_WEB_LINKS_SCRIPT=/usr/local/sbin/rpi-setup-web-links
RPI_WEB_LINKS_UNIT=rpi-setup-web-links

# Install the script that writes $1/services.json and $1/containers.json, and
# a timer that runs it every minute.
web_links_install() {
  local out="$1/services.json" units=0
  install -m 0755 -d "$(dirname "$RPI_WEB_LINKS_SCRIPT")"
  web_links_script "$out" | write_if_changed "$RPI_WEB_LINKS_SCRIPT" 0755 || true
  printf '%s\n' \
    '[Unit]' \
    'Description=List the web pages on this Pi for the start page (tasks/web.sh)' \
    'After=docker.service pihole-FTL.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$RPI_WEB_LINKS_SCRIPT" \
    'Nice=10' \
    'PrivateTmp=yes' \
    'ProtectHome=read-only' \
    'NoNewPrivileges=yes' |
    write_if_changed "/etc/systemd/system/$RPI_WEB_LINKS_UNIT.service" && units=1
  printf '%s\n' \
    '[Unit]' \
    'Description=Refresh the start page service list every minute' \
    '' \
    '[Timer]' \
    'OnBootSec=30s' \
    'OnUnitActiveSec=1min' \
    'AccuracySec=10s' \
    '' \
    '[Install]' \
    'WantedBy=timers.target' |
    write_if_changed "/etc/systemd/system/$RPI_WEB_LINKS_UNIT.timer" && units=1
  if [[ $units -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart "$RPI_WEB_LINKS_UNIT.timer" 2>/dev/null || true
  fi
  systemctl enable --now "$RPI_WEB_LINKS_UNIT.timer"
}

# Write the lists now, once the services are up, instead of within a minute.
web_links_refresh() {
  "$RPI_WEB_LINKS_SCRIPT" || warn "Could not write the lists for the start page yet; the timer tries again every minute"
}

# Print the standalone service list script writing to $1: the web_links_run_*
# functions below plus the helpers they use from lib/common.sh, so the unit
# tests exercise the very code the timer runs.
web_links_script() {
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/web.sh): lists the web pages on this Pi for\n'
  printf '# the start page. Re-run "sudo bash setup.sh web" instead of editing this file.\n'
  printf 'set -euo pipefail\n'
  printf 'WL_OUT=%q\n' "$1"
  printf 'WL_DONE=%q\n' "${RPI_SETUP_DONE_FILE:-/var/lib/rpi-setup/tasks.done}"
  printf 'WL_TASKS=%q\n' "$(printf '%s\n' "${TASKS[@]}")"
  declare -f have container_dir task_in_container pihole_ftl pihole_web_ports write_if_changed \
    web_links_run_json web_links_run_known web_links_run_ports web_links_run_ip web_links_run_http \
    web_links_run_entry web_links_run_list web_links_run_containers web_links_run_tasks web_links_run_teamspeak \
    web_links_run
  printf 'web_links_run\n'
}

# --- Code of the service list script (uses only WL_* variables, plain tools
# and the lib/common.sh helpers named in web_links_script) ----------------

# $1 as a JSON string: quotes and backslashes escaped, control characters
# dropped.
web_links_run_json() {
  local s="${1//[[:cntrl:]]/}"
  s="${s//\\/\\\\}"
  printf '"%s"' "${s//\"/\\\"}"
}

# Name, description and path (tab separated) of a container an rpi-setup task
# runs, "-" for one that is not a web page (or listed on its own), or exit 1
# for any other container.
web_links_run_known() {
  case "$1" in
    netalertx) printf 'NetAlertX\tWhich devices are on the network, and when\t/\n' ;;
    den-watcher) printf 'Den-Watcher\tCPU, memory, temperature and disks of this Pi, with their history\t/\n' ;;
    pihole|web|teamspeak|teamspeak-usage|samba|gateway) printf -- '-\n' ;;
    *) return 1 ;;
  esac
}

# TCP ports container $1 offers on the LAN, one per line as "port" or, for a
# port published on one address only, "port address" (an IPv6 address in
# brackets): the ports Docker publishes (not those bound to localhost only),
# and for NetAlertX on the host network its PORT setting.
web_links_run_ports() {
  if [[ "$1" == netalertx ]]; then
    sed -nE 's/^[[:space:]]*PORT:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' \
      "$(container_dir netalertx)/docker-compose.yml" 2>/dev/null | head -n1
    return 0
  fi
  docker port "$1" 2>/dev/null |
    sed -nE '/-> (127\.|\[::1\])/d; s#^[0-9]+/tcp -> (.*):([0-9]+)$#\2 \1#p; s/ (0\.0\.0\.0|\[::\])$//' |
    awk '!seen[$1]++'
}

# The Pi's LAN address: the source address of its default route (no packet
# is sent), else the first address "hostname -I" reports, else nothing.
web_links_run_ip() {
  local addr
  addr="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n1)" || addr=""
  [[ -n "$addr" ]] || addr="$(hostname -I 2>/dev/null | awk '{print $1}')" || addr=""
  printf '%s\n' "$addr"
}

# HTTP status code of http://$3:$1$2 ($3: the address the port is published
# on, 127.0.0.1 when it is on every address), "000" when nothing answers.
web_links_run_http() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 \
    "http://${3:-127.0.0.1}:$1${2%%#*}" 2>/dev/null)" || true
  printf '%s\n' "${code:-000}"
}

# Print one service as a JSON object: name $1, description $2, port $3, path
# $4. With $5=probe it is listed only if it answers HTTP; $6 is the address
# the port is published on, if only one. Returns 1 if it was left out: a bad
# port, a port already listed, or no answer to a probe. Uses the caller's
# "seen" and "sep".
web_links_run_entry() {
  local name="${1:0:60}" desc="${2:0:160}" port="$3" path="${4:-/}" mode="${5:-}" addr="${6:-}" up=null code
  local path_re='^/[A-Za-z0-9._~/?#=&%:@+,;!-]*$' addr_re='^[][0-9A-Za-z.:]*$'
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  port=$((10#$port))
  [[ -z "${seen[$port]:-}" ]] || return 1
  [[ "$path" =~ $path_re ]] || path=/
  [[ "$addr" =~ $addr_re ]] || addr=""
  if have curl; then
    code="$(web_links_run_http "$port" "$path" "$addr")"
    if [[ "$code" == 000 ]]; then up=false; else up=true; fi
  fi
  [[ "$mode" != probe || "$up" != false ]] || return 1
  seen[$port]=1
  printf '%s{"name":%s,"description":%s,"port":%s,"path":%s,"up":%s}' "$sep" \
    "$(web_links_run_json "$name")" "$(web_links_run_json "$desc")" "$port" \
    "$(web_links_run_json "$path")" "$up"
  sep=$',\n'
}

# Print services.json: Pi-hole (in its container or on the host), then every
# running container, sorted by name, from one "docker inspect" of their
# labels. A container's rpi-setup.link.* labels win; rpi-setup's own
# containers have a name and description; any other container is listed
# with the first published port that answers HTTP.
web_links_run_list() {
  local -A seen=()
  local sep="" name port addr known title desc path hide lport lname lpath ldesc fmt
  printf '{"host":%s,"ip":%s,"services":[\n' "$(web_links_run_json "$(hostname 2>/dev/null || true)")" \
    "$(web_links_run_json "$(web_links_run_ip)")"
  if task_in_container pihole || systemctl is-active --quiet pihole-FTL 2>/dev/null; then
    port="$(pihole_web_ports | head -n1)"
    [[ -z "$port" ]] ||
      web_links_run_entry Pi-hole 'Blocks ads and trackers for every device on the network' "$port" /admin/ || true
  fi
  if [[ "${WL_DOCKER:-0}" -eq 1 ]]; then
    fmt=$'{{.Name}}\x1f{{index .Config.Labels "rpi-setup.link"}}\x1f{{index .Config.Labels "rpi-setup.link.port"}}\x1f'
    fmt+=$'{{index .Config.Labels "rpi-setup.link.name"}}\x1f{{index .Config.Labels "rpi-setup.link.path"}}\x1f'
    fmt+='{{index .Config.Labels "rpi-setup.link.description"}}'
    while IFS=$'\x1f' read -r name hide lport lname lpath ldesc; do
      name="${name#/}"
      [[ -n "$name" ]] || continue
      [[ ! "${hide,,}" =~ ^(no|off|false|0)$ ]] || continue
      if [[ -n "$lport" ]]; then
        web_links_run_entry "${lname:-$name}" "$ldesc" "$lport" "${lpath:-/}" || true
        continue
      fi
      if known="$(web_links_run_known "$name")"; then
        [[ "$known" != - ]] || continue
        IFS=$'\t' read -r title desc path <<<"$known"
        port="" addr=""
        read -r port addr < <(web_links_run_ports "$name" | head -n1) || true
        web_links_run_entry "$title" "$desc" "$port" "$path" '' "$addr" || true
        continue
      fi
      while read -r port addr; do
        ! web_links_run_entry "$name" '' "$port" / probe "${addr:-}" || break
      done < <(web_links_run_ports "$name")
    done < <(docker ps -q 2>/dev/null | xargs -r docker inspect -f "$fmt" 2>/dev/null | sed 's/<no value>//g' | sort)
  fi
  printf '\n]}\n'
}

# Print containers.json: every container, running or not, by name, with its
# image, state, health, restart count, network mode and the ports it
# publishes. Start and stop are timestamps (the page works out the uptime),
# so the file only changes when a container does.
web_links_run_containers() {
  local fmt name image state health started finished restarts net ports p host ip sep="" list
  printf '{"containers":[\n'
  if [[ "${WL_DOCKER:-0}" -eq 1 ]]; then
    # Written for Docker's raw JSON (HostIp, a missing Health key), which
    # "docker inspect" falls back to when the template does not fit its types.
    fmt=$'{{.Name}}\x1f{{.Config.Image}}\x1f{{.State.Status}}\x1f{{with index .State "Health"}}{{index . "Status"}}{{end}}\x1f'
    fmt+=$'{{.State.StartedAt}}\x1f{{.State.FinishedAt}}\x1f{{.RestartCount}}\x1f{{.HostConfig.NetworkMode}}\x1f'
    # shellcheck disable=SC2016 # Go template variables, not shell ones.
    fmt+='{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}>{{$p}} {{end}}{{end}}'
    while IFS=$'\x1f' read -r name image state health started finished restarts net ports; do
      [[ -n "$name" ]] || continue
      [[ "$restarts" =~ ^[0-9]+$ ]] || restarts=0
      # Ports as "8090:9393/tcp", once each (IPv4 and IPv6 bindings are the same
      # port), without those bound to localhost only.
      list=""
      for p in $ports; do
        host="${p%%>*}"
        ip="${host%:*}"
        [[ "$ip" != 127.* && "$ip" != ::1 ]] || continue
        p="$(web_links_run_json "${host##*:}:${p#*>}")"
        [[ ",$list," == *",$p,"* ]] || list+="${list:+,}$p"
      done
      # "2026-10-03T09:55:01.123456789Z" -> "2026-10-03T09:55:01Z"; Docker
      # reports year 1 for a time that never happened.
      started="${started%%.*}" finished="${finished%%.*}"
      started="${started%Z}" finished="${finished%Z}"
      [[ -n "$started" && "$started" != 0001-* ]] && started+=Z || started=""
      [[ -n "$finished" && "$finished" != 0001-* ]] && finished+=Z || finished=""
      printf '%s{"name":%s,"image":%s,"state":%s,"health":%s,"started":%s,"finished":%s,"restarts":%s,"network":%s,"ports":[%s]}' \
        "$sep" "$(web_links_run_json "${name#/}")" "$(web_links_run_json "$image")" \
        "$(web_links_run_json "$state")" "$(web_links_run_json "$health")" \
        "$(web_links_run_json "$started")" "$(web_links_run_json "$finished")" \
        "$((10#$restarts))" "$(web_links_run_json "$net")" "$list"
      sep=$',\n'
    done < <(docker ps -aq 2>/dev/null | xargs -r docker inspect -f "$fmt" 2>/dev/null | sort)
  fi
  printf '\n]}\n'
}

# Print tasks.json: the rpi-setup tasks that finished on this Pi (setup.sh
# records them in $WL_DONE), by name, with their description from WL_TASKS
# ("name|description" lines). The web task is always listed: it wrote the page.
web_links_run_tasks() {
  local sep="" name line desc
  printf '{"tasks":[\n'
  while IFS= read -r name; do
    [[ "$name" =~ ^[a-z0-9_-]+$ ]] || continue
    desc=""
    while IFS= read -r line; do
      [[ "${line%%|*}" != "$name" ]] || desc="${line#*|}"
    done <<<"$WL_TASKS"
    printf '%s{"name":%s,"description":%s}' "$sep" "$(web_links_run_json "$name")" "$(web_links_run_json "$desc")"
    sep=$',\n'
  done < <({ cat "$WL_DONE" 2>/dev/null || true; echo web; } | sort -u)
  printf '\n]}\n'
}

# Copy the TeamSpeak usage summary (teamspeak task, TEAMSPEAK_USAGE) to
# teamspeak.json next to $WL_OUT while its logger keeps it fresh (it rewrites
# it every minute), else remove it so the page hides the section.
web_links_run_teamspeak() {
  local src dest="${WL_OUT%/*}/teamspeak.json"
  src="$(container_dir teamspeak)/usage/data/usage.json"
  if [[ -f "$src" && -n "$(find "$src" -mmin -10 2>/dev/null)" ]]; then
    write_if_changed "$dest" 0644 <"$src" || true
  else
    rm -f "$dest"
  fi
}

# Write the lists to $WL_OUT, and containers.json, tasks.json and
# teamspeak.json next to it; each file only changes when its list does.
# WL_DOCKER says once whether Docker answers.
web_links_run() {
  WL_DOCKER=0
  if have docker && docker info >/dev/null 2>&1; then WL_DOCKER=1; fi
  web_links_run_list | write_if_changed "$WL_OUT" 0644 || true
  web_links_run_containers | write_if_changed "${WL_OUT%/*}/containers.json" 0644 || true
  web_links_run_tasks | write_if_changed "${WL_OUT%/*}/tasks.json" 0644 || true
  web_links_run_teamspeak
}

# --- Update check (updates.json for the start page) ------------------------

RPI_WEB_UPDATES_SCRIPT=/usr/local/sbin/rpi-setup-updates
RPI_WEB_UPDATES_UNIT=rpi-setup-updates

# WEB_UPDATES=yes: install the script that writes $1/updates.json and a timer
# that runs it 15 minutes after boot (or after this install, so its
# "apt-get update" does not get in the way of the tasks still running) and
# then every 6 hours. WEB_UPDATES=no: remove them and the file.
web_updates_install() {
  local out="$1/updates.json" units=0
  if ! setting_on WEB_UPDATES; then
    if [[ -e "/etc/systemd/system/$RPI_WEB_UPDATES_UNIT.timer" ]]; then
      systemctl disable --now "$RPI_WEB_UPDATES_UNIT.timer" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$RPI_WEB_UPDATES_UNIT.timer" "/etc/systemd/system/$RPI_WEB_UPDATES_UNIT.service"
      systemctl daemon-reload
      info 'Update check turned off (WEB_UPDATES=no)'
    fi
    rm -f "$RPI_WEB_UPDATES_SCRIPT" "$out"
    return 0
  fi
  install -m 0755 -d "$(dirname "$RPI_WEB_UPDATES_SCRIPT")"
  web_updates_script "$out" | write_if_changed "$RPI_WEB_UPDATES_SCRIPT" 0755 || true
  printf '%s\n' \
    '[Unit]' \
    'Description=Look for updates of what rpi-setup installed, for the start page (tasks/web.sh)' \
    'After=network-online.target docker.service' \
    'Wants=network-online.target' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$RPI_WEB_UPDATES_SCRIPT" \
    'Nice=10' \
    'IOSchedulingClass=idle' \
    'TimeoutStartSec=30min' \
    'PrivateTmp=yes' \
    'ProtectHome=read-only' \
    'NoNewPrivileges=yes' |
    write_if_changed "/etc/systemd/system/$RPI_WEB_UPDATES_UNIT.service" && units=1
  printf '%s\n' \
    '[Unit]' \
    'Description=Look for updates for the start page every 6 hours' \
    '' \
    '[Timer]' \
    'OnActiveSec=15min' \
    'OnUnitActiveSec=6h' \
    'RandomizedDelaySec=5min' \
    '' \
    '[Install]' \
    'WantedBy=timers.target' |
    write_if_changed "/etc/systemd/system/$RPI_WEB_UPDATES_UNIT.timer" && units=1
  if [[ $units -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart "$RPI_WEB_UPDATES_UNIT.timer" 2>/dev/null || true
  fi
  systemctl enable --now "$RPI_WEB_UPDATES_UNIT.timer"
}

# Print the standalone update check script writing to $1, built like
# web_links_script so the unit tests run the very code the timer runs.
web_updates_script() {
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/web.sh): looks for updates of what rpi-setup\n'
  printf '# installed, for the start page. Re-run "sudo bash setup.sh web" instead of\n'
  printf '# editing this file.\n'
  printf 'set -euo pipefail\n'
  printf 'WU_OUT=%q\n' "$1"
  printf 'WU_ROOT=%q\n' "$RPI_SETUP_ROOT"
  # shellcheck disable=SC2016 # expanded by the written script
  printf ': "${WU_PIHOLE_VERSIONS:=/etc/pihole/versions}"\n'
  declare -f have container_dir task_in_container write_if_changed web_links_run_json web_updates_run_item web_updates_run_digest \
    web_updates_run_containers web_updates_run_git_as web_updates_run_git web_updates_run_apt \
    web_updates_run_pihole web_updates_run_eeprom web_updates_run_list web_updates_run
  printf 'web_updates_run\n'
}

# --- Code of the update check script (uses only WU_* variables, plain tools
# and the helpers named in web_updates_script) -----------------------------

# Print one entry of updates.json: name $1, kind $2, current version $3,
# newest version $4, update $5 (true, false or null when it could not be
# checked), then $6, more JSON fields starting with a comma. Uses the
# caller's "sep".
web_updates_run_item() {
  printf '%s{"name":%s,"kind":%s,"current":%s,"latest":%s,"update":%s%s}' "$sep" \
    "$(web_links_run_json "$1")" "$(web_links_run_json "$2")" "$(web_links_run_json "$3")" \
    "$(web_links_run_json "$4")" "$5" "${6:-}"
  sep=$',\n'
}

# The digest a registry serves for image $1 (e.g. nginx:stable-alpine or
# ghcr.io/owner/app:main) right now, without pulling it: a HEAD request for
# the manifest, with an anonymous token where the registry asks for one.
# Docker Hub does not count HEAD requests against its pull limit. Fails for
# an image pinned by digest, a private image or no answer.
web_updates_run_digest() {
  local ref="$1" reg repo tag last first url hdr realm service scope token digest
  local -a accept=(
    -H 'Accept: application/vnd.oci.image.index.v1+json'
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
    -H 'Accept: application/vnd.oci.image.manifest.v1+json'
  )
  [[ "$ref" != *@* ]] || return 1
  last="${ref##*/}"
  if [[ "$last" == *:* ]]; then tag="${last##*:}" repo="${ref%:*}"; else tag=latest repo="$ref"; fi
  first="${repo%%/*}"
  if [[ "$repo" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    reg="$first" repo="${repo#*/}"
  else
    reg=docker.io
    [[ "$repo" == */* ]] || repo="library/$repo"
  fi
  [[ "$reg" != docker.io ]] || reg=registry-1.docker.io
  [[ "$reg/$repo:$tag" =~ ^[A-Za-z0-9.:-]+/[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || return 1
  url="https://$reg/v2/$repo/manifests/$tag"
  hdr="$(curl -sSI --max-time 20 "${accept[@]}" "$url" 2>/dev/null | tr -d '\r')" || return 1
  # The last status line: a proxy puts its own answer first.
  if [[ "$(sed -nE 's#^HTTP/[0-9.]+ ([0-9]+).*#\1#p' <<<"$hdr" | tail -n1)" == 401 ]]; then
    realm="$(sed -nE 's/^www-authenticate:.*realm="([^"]*)".*/\1/Ip' <<<"$hdr" | head -n1)"
    service="$(sed -nE 's/^www-authenticate:.*service="([^"]*)".*/\1/Ip' <<<"$hdr" | head -n1)"
    scope="$(sed -nE 's/^www-authenticate:.*scope="([^"]*)".*/\1/Ip' <<<"$hdr" | head -n1)"
    [[ "$realm" == https://* ]] || return 1
    token="$(curl -fsS --max-time 20 -G --data-urlencode "service=$service" \
      --data-urlencode "scope=${scope:-repository:$repo:pull}" "$realm" 2>/dev/null |
      sed -nE 's/.*"(token|access_token)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n1)" || return 1
    [[ -n "$token" ]] || return 1
    hdr="$(curl -sSI --max-time 20 "${accept[@]}" -H "Authorization: Bearer $token" "$url" 2>/dev/null |
      tr -d '\r')" || return 1
  fi
  [[ "$(sed -nE 's#^HTTP/[0-9.]+ ([0-9]+).*#\1#p' <<<"$hdr" | tail -n1)" == 200 ]] || return 1
  digest="$(sed -nE 's/^docker-content-digest:[[:space:]]*(sha256:[0-9a-f]{64})[[:space:]]*$/\1/Ip' <<<"$hdr" | head -n1)"
  [[ -n "$digest" ]] || return 1
  printf '%s\n' "$digest"
}

# One entry per container: is the image it runs still the one its registry
# serves for that tag? Images built on the Pi and images pinned by digest
# have nothing to compare with and are left out. Each image is asked once.
web_updates_run_containers() {
  local name ref id digests current latest update
  local -A remote=()
  have docker && docker info >/dev/null 2>&1 || return 0
  while IFS=$'\x1f' read -r name ref id; do
    [[ -n "$name" && -n "$ref" && "$ref" != *@* ]] || continue
    digests="$(docker image inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$id" 2>/dev/null)" || digests=""
    [[ "$digests" == *@sha256:* ]] || continue
    current="${digests#*@}" current="${current%% *}"
    [[ -n "${remote[$ref]+x}" ]] || remote[$ref]="$(web_updates_run_digest "$ref" || true)"
    latest="${remote[$ref]}"
    if [[ -z "$latest" ]]; then update=null
    elif [[ " $digests" == *"@$latest "* ]]; then update=false
    else update=true
    fi
    web_updates_run_item "${name#/}" container "$current" "$latest" "$update" \
      ",\"image\":$(web_links_run_json "$ref")"
  done < <(docker ps -aq 2>/dev/null |
    xargs -r docker inspect -f $'{{.Name}}\x1f{{.Config.Image}}\x1f{{.Image}}' 2>/dev/null | sort)
}

# git in the rpi-setup checkout as the user who owns it (their credentials
# for a private repository, and root never touches their files), without
# ever waiting for a password.
web_updates_run_git_as() {
  local owner
  owner="$(stat -c %U "$WU_ROOT")"
  if [[ "$owner" == "$(id -un)" ]]; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' timeout 60 git -C "$WU_ROOT" "$@"
  else
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' timeout 60 runuser -u "$owner" -- git -C "$WU_ROOT" "$@"
  fi
}

# The rpi-setup checkout: its commit against the newest commit of the branch
# it follows (git ls-remote, so nothing in the checkout changes). A checkout
# ahead of that commit is up to date.
web_updates_run_git() {
  local head branch="" upstream=origin ref=HEAD latest update
  have git && [[ -e "$WU_ROOT/.git" ]] || return 0
  head="$(web_updates_run_git_as rev-parse HEAD 2>/dev/null)" || return 0
  if branch="$(web_updates_run_git_as symbolic-ref -q --short HEAD 2>/dev/null)"; then
    upstream="$(web_updates_run_git_as config "branch.$branch.remote" 2>/dev/null)" || upstream=origin
    ref="$(web_updates_run_git_as config "branch.$branch.merge" 2>/dev/null)" || ref="refs/heads/$branch"
  fi
  latest="$(web_updates_run_git_as ls-remote "$upstream" "$ref" 2>/dev/null | awk -v r="$ref" '$2 == r { print $1; exit }')" || latest=""
  if [[ -z "$latest" ]]; then update=null
  elif [[ "$latest" == "$head" ]]; then update=false
  elif web_updates_run_git_as merge-base --is-ancestor "$latest" "$head" 2>/dev/null; then update=false
  else update=true
  fi
  web_updates_run_item rpi-setup git "${head:0:7}" "${latest:0:7}" "$update" \
    ",\"branch\":$(web_links_run_json "$branch")"
}

# OS packages: refresh the package lists, then the packages "apt-get upgrade
# --with-new-pkgs" (what update.sh runs) would install, how many come from a
# security repository, and their names (the first 50). A busy package
# manager just leaves the lists as they are.
web_updates_run_apt() {
  local sim count security names="" p
  have apt-get || return 0
  timeout 600 apt-get update -qq >/dev/null 2>&1 || true
  sim="$(apt-get -s -q upgrade --with-new-pkgs 2>/dev/null | grep '^Inst ')" || sim=""
  count=0 security=0
  if [[ -n "$sim" ]]; then
    count="$(wc -l <<<"$sim")"
    security="$(grep -ci 'security' <<<"$sim")" || security=0
    for p in $(awk '{ print $2 }' <<<"$sim" | head -n 50); do
      names+="${names:+,}$(web_links_run_json "$p")"
    done
  fi
  web_updates_run_item 'OS packages' apt "" "" "$( ((count)) && echo true || echo false)" \
    ",\"count\":$((count)),\"security\":$((security)),\"packages\":[$names]"
}

# Pi-hole installed on the host: its own update check (the "pihole
# updatechecker" its cron job runs) keeps the installed and the newest
# versions of Core, Web and FTL in /etc/pihole/versions. With Pi-hole in its
# container the native install stays installed but stopped, and the
# container is listed with the others.
web_updates_run_pihole() {
  local f="$WU_PIHOLE_VERSIONS" part label c l cur="" new="" update=false
  have pihole && [[ -f "$f" ]] || return 0
  ! task_in_container pihole || return 0
  for part in CORE WEB FTL; do
    case "$part" in CORE) label=Core ;; WEB) label=Web ;; *) label=FTL ;; esac
    c="$(sed -nE "s/^${part}_VERSION=['\"]?([^'\"]*)['\"]?\$/\\1/p" "$f" | head -n1)"
    l="$(sed -nE "s/^GITHUB_${part}_VERSION=['\"]?([^'\"]*)['\"]?\$/\\1/p" "$f" | head -n1)"
    [[ -n "$c" ]] || continue
    cur+="${cur:+, }$label $c"
    [[ -z "$l" ]] || new+="${new:+, }$label $l"
    [[ -z "$l" || "$l" == "$c" ]] || update=true
  done
  [[ -n "$cur" ]] || return 0
  [[ -n "$new" ]] || update=null
  web_updates_run_item Pi-hole pihole "$cur" "$new" "$update"
}

# The Raspberry Pi bootloader (EEPROM): rpi-eeprom-update without options
# only reports, as update.sh would install with -a.
web_updates_run_eeprom() {
  local out update cur new
  have rpi-eeprom-update || return 0
  out="$(timeout 60 rpi-eeprom-update 2>/dev/null)" || true
  case "$out" in
    *'BOOTLOADER: update available'*) update=true ;;
    *'BOOTLOADER: up to date'*) update=false ;;
    *) return 0 ;;
  esac
  cur="$(sed -nE '/BOOTLOADER/,/^[[:space:]]*$/ s/^[[:space:]]*CURRENT:[[:space:]]*(.*[^[:space:]])[[:space:]]*\([0-9]+\).*/\1/p' <<<"$out" | head -n1)"
  new="$(sed -nE '/BOOTLOADER/,/^[[:space:]]*$/ s/^[[:space:]]*LATEST:[[:space:]]*(.*[^[:space:]])[[:space:]]*\([0-9]+\).*/\1/p' <<<"$out" | head -n1)"
  web_updates_run_item 'EEPROM firmware' eeprom "$cur" "$new" "$update"
}

# Print updates.json: when it was checked, then rpi-setup itself, Pi-hole,
# the bootloader, the containers and the OS packages.
web_updates_run_list() {
  local sep=""
  printf '{"checked":%s,"items":[\n' "$(web_links_run_json "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  web_updates_run_git
  web_updates_run_pihole
  web_updates_run_eeprom
  web_updates_run_containers
  web_updates_run_apt
  printf '\n]}\n'
}

# Write updates.json to $WU_OUT, only once the whole list is there.
web_updates_run() {
  local list
  list="$(web_updates_run_list)"
  printf '%s\n' "$list" | write_if_changed "$WU_OUT" 0644 || true
}

# Port nginx listens on: WEB_PORT, else the port $1 it used so far, else 80,
# so http://<pi>/ opens the start page. 8080 used so far is the old fallback
# next to Pi-hole and counts as unset. Pi-hole's admin UI is moved off port
# 80 when it holds it; anything else on 80 (or PIHOLE_WEB_PORT=80) leaves
# nginx on 8080.
web_port() {
  local want="${WEB_PORT:-}" cur="${1:-}" owner to
  if [[ -z "$want" && -n "$cur" && "$cur" != 8080 ]]; then echo "$cur"; return; fi
  owner="$(port_owner "${want:-80}")" || owner=""
  if [[ "${want:-80}" == 80 && "$owner" == pihole-FTL ]]; then
    # A subshell, so the pihole settings do not leak into this task.
    to="$(load_task_config pihole >/dev/null; printf '%s' "${PIHOLE_WEB_PORT:-8080}")"
    if [[ "$to" != 80 ]]; then web_move_pihole "$to" >&2; echo 80; return; fi
    [[ -z "$want" ]] || die 'WEB_PORT=80 and PIHOLE_WEB_PORT=80 both ask for port 80; change one of them'
    warn 'PIHOLE_WEB_PORT=80 keeps Pi-hole on port 80; nginx will listen on 8080'
  elif [[ -n "$want" ]]; then
    echo "$want"; return
  elif [[ -z "$owner" || "$owner" == nginx ]]; then
    echo 80; return
  else
    warn "Port 80 is used by '$owner'; nginx will listen on 8080 (free port 80 or set WEB_PORT)"
  fi
  echo 8080
}

# Move Pi-hole's admin UI from port 80 to port $1, in its container or on the
# host. nginx on that port (8080, the old fallback) is stopped first, so the
# two can swap; the caller starts it again on port 80. web_port runs it in
# $( ), where errexit is off, so every step checks its own result.
web_move_pihole() {
  local to="$1" dir owner stopped=0 cur new
  owner="$(port_owner "$to")" || owner=""
  if [[ "$owner" == nginx ]]; then
    info "Stopping nginx on port $to so Pi-hole can move there"
    if task_in_container web; then docker stop web >/dev/null; else systemctl stop nginx; fi ||
      die "Could not stop nginx on port $to"
    owner="" stopped=1
  fi
  [[ -z "$owner" || "$owner" == pihole-FTL ]] ||
    web_move_fail "Port 80 is for the start page, but Pi-hole cannot move to $to: '$owner' uses it (set PIHOLE_WEB_PORT)"
  info "Moving Pi-hole's web admin from port 80 to $to so the start page gets port 80"
  if task_in_container pihole; then
    dir="$(container_dir pihole)"
    cur="$(sed -nE 's/^[[:space:]]*FTLCONF_webserver_port:[[:space:]]*"?([^"]*)"?.*/\1/p' "$dir/docker-compose.yml" | head -n1)" || cur=""
    new="$(pihole_port_setting "${cur:-$(pihole_default_ports)}" "$to")"
    sed -Ei "s/^([[:space:]]*FTLCONF_webserver_port:[[:space:]]*).*/\\1\"${new}\"/" "$dir/docker-compose.yml" ||
      web_move_fail "Could not change the port in $dir/docker-compose.yml"
    docker compose -f "$dir/docker-compose.yml" up -d >/dev/null || web_move_fail 'Could not restart the Pi-hole container'
  else
    cur="$(pihole-FTL --config webserver.port 2>/dev/null)" || cur=""
    new="$(pihole_port_setting "${cur:-$(pihole_default_ports)}" "$to")"
    pihole-FTL --config webserver.port "$new" >/dev/null ||
      web_move_fail "Could not set Pi-hole's web admin port to $to"
    systemctl restart pihole-FTL || web_move_fail 'Could not restart pihole-FTL'
  fi
  for _ in $(seq 1 30); do
    [[ "$(port_owner 80 || true)" == pihole-FTL ]] || break
    sleep 1
  done
  [[ "$(port_owner 80 || true)" != pihole-FTL ]] || web_move_fail 'Pi-hole still holds port 80 after the move'
  say "Pi-hole web admin moved to $(service_url "$to")/admin"
  web_move_firewall_warn "$to"
}

# A failed Pi-hole move: nginx stopped for it (the caller's "stopped") is
# started again on its old port before dying with message $1.
web_move_fail() {
  if [[ "${stopped:-0}" -eq 1 ]]; then
    if task_in_container web; then docker start web >/dev/null; else systemctl start nginx; fi ||
      warn 'Could not start nginx again; see: sudo systemctl status nginx'
  fi
  die "$1"
}

# After the move, port $1 is closed by a firewall that opened Pi-hole's old
# port: the rpi-setup firewall (its unit, or its nftables table while it is
# loaded) or ufw. The firewall task reads Pi-hole's port when it runs, so it
# has to run again.
web_move_firewall_warn() {
  local to="$1"
  if systemctl is-enabled --quiet rpi-setup-firewall.service 2>/dev/null ||
     systemctl is-active --quiet rpi-setup-firewall.service 2>/dev/null ||
     { have nft && nft list table inet rpi_setup >/dev/null 2>&1; }; then
    warn "The firewall task still blocks Pi-hole's new port $to; open it with: sudo bash setup.sh firewall"
  elif have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is on; open port $to for Pi-hole, e.g. with: sudo ufw allow $to/tcp"
  fi
}

# The IPv4 port of the default site's first "listen" line, e.g. "80".
nginx_site_port() {
  [[ -f "$1" ]] || return 1  # the callers say what a missing site file means
  sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)([[:space:];]).*/\1/p' "$1" 2>/dev/null | head -n1
}

# Change the IPv4 and IPv6 "listen <from>" lines of an nginx site to <to>.
nginx_move_port() {
  local site="$1" from="$2" to="$3"
  sed -Ei "s/^([[:space:]]*listen[[:space:]]+(\\[::\\]:)?)${from}([[:space:];])/\\1${to}\\3/" "$site"
}

# WEB_DOCKER=yes: nginx in its own container (host network), serving
# /opt/web/html with the site config from /opt/web/conf. A native nginx is
# stopped and its /var/www/html copied over once.
run_web_container() {
  : "${WEB_IMAGE:=nginx:stable-alpine}"
  local dir name=web port owner="" changed=0
  require_image_ref WEB_IMAGE
  container_require_64bit WEB_DOCKER
  container_require_docker
  dir="$(container_dir web)"

  # nginx_site_port fails (sed: no such file) when the file is missing.
  port="$(nginx_site_port "$dir/conf/default.conf" || true)"
  [[ -n "$port" ]] || port="$(nginx_site_port /etc/nginx/sites-available/default || true)"
  port="$(web_port "$port")"
  owner="$(port_owner "$port")" || owner=""
  [[ -z "$owner" || "$owner" == nginx ]] ||
    die "Port $port is already used by '$owner'; set WEB_PORT to a free port"

  install -m 0755 -d "$dir" "$dir/conf" "$dir/html"
  if web_container_compose "$dir" "$name" | write_if_changed "$dir/docker-compose.yml" 0644; then changed=1; fi
  if web_container_site "$port" | write_if_changed "$dir/conf/default.conf" 0644; then changed=1; fi
  container_pull "$dir"

  container_copy_once "$dir" /var/www/html "$dir/html" || true
  web_index_page "$dir/html/index.html"
  web_links_install "$dir/html"
  web_updates_install "$dir/html"
  local extra=""
  if [[ -d /etc/nginx/sites-enabled ]]; then
    extra="$(find /etc/nginx/sites-enabled -mindepth 1 ! -name default -printf '%f ' 2>/dev/null)" || extra=""
  fi
  [[ -z "$extra" ]] || warn "Native nginx sites not carried over: ${extra}(add them to $dir/conf)"
  container_stop_native "$dir" nginx

  # The site config is a bind mount; nginx reads it at start.
  container_up "$dir" "$name" "$changed"
  web_links_refresh
  say "nginx container running - open $(service_url "$port") in your browser (files in $dir/html)"
}

# nginx site for the container, listening on port $1 (IPv6 too where the
# host has it; nginx will not start on a missing address family).
web_container_site() {
  local v6=""
  # /proc files report size 0, so test the content, not -s.
  [[ -z "$(cat /proc/net/if_inet6 2>/dev/null)" ]] || v6="    listen [::]:$1;"
  cat <<EOF
# Managed by rpi-setup (tasks/web.sh, WEB_* settings).
server {
    listen $1;
${v6}
    server_name _;
    root /usr/share/nginx/html;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# Compose file of the web container in folder $1, container name $2: no
# privilege escalation, a process limit and only the capabilities nginx
# needs to bind its port and drop to its own user.
web_container_compose() {
  local dir="$1" name="$2"
  cat <<EOF
services:
  web:
    image: "$WEB_IMAGE"
    container_name: $name
    restart: unless-stopped
    pids_limit: 512
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - NET_BIND_SERVICE
    network_mode: host
    read_only: true
    tmpfs:
      - /var/cache/nginx
      - /run
      - /tmp
    environment:
      NGINX_ENTRYPOINT_QUIET_LOGS: "1"
    volumes:
      - type: bind
        source: $dir/html
        target: /usr/share/nginx/html
        read_only: true
      - type: bind
        source: $dir/conf
        target: /etc/nginx/conf.d
        read_only: true
EOF
}
