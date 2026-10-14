#!/usr/bin/env bash
# Start or reload Caddy, listening on the home Wi-Fi ONLY when this PC is really at home,
# and on the Tailscale network (phone from anywhere, P5) only while Tailscale is up.
#
#   run-caddy.sh run             start Caddy in the foreground (the systemd service uses this)
#   run-caddy.sh reload          apply caddy/Caddyfile again (systemctl reload uses this)
#   run-caddy.sh sync            reload only if "at home?" or "Tailscale up?" changed (30 s timer)
#   run-caddy.sh status          say what Caddy listens on and why
#   run-caddy.sh remember-home   run once, AT HOME: save this network as home
#   run-caddy.sh check-start     what `run` would do now (taken phone ports, fallback), starts nothing
#
# "At home" = this PC has the saved home address AND the default router has the saved
# hardware (MAC) address. The address alone is not enough: 192.168.40.x is a common range,
# and another network could hand out the same address. The pair is kept in
# /etc/mini-deploy/home-lan (root only, never in the repo). Without that file, or anywhere
# else, Caddy listens on 127.0.0.1 only. Run as root (WSL's default user).
set -uo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
CONF=${MINI_DEPLOY_CADDYFILE:-$REPO/caddy/Caddyfile}   # override only for tests
HOME_FILE=/etc/mini-deploy/home-lan
FAILED_MARK=/run/mini-deploy-caddy-sync.failed       # last reload that failed (and when)
RETRY_AFTER=300                                      # seconds before the same failed reload is tried again
IP_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
MAC_RE='^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'

gateway_ip()  { ip -4 route show default | awk '{print $3; exit}'; }
gateway_mac() {
  # The router's hardware address, but only if it JUST answered. Right after a network
  # change the neighbour table can still hold the old (home) router's entry as STALE for
  # a while; only an entry the kernel has just confirmed (REACHABLE) counts.
  local gw entry; gw=$(gateway_ip)
  [ -n "$gw" ] || return 0
  # The router must answer now. Up to 3 quick tries: one slow reply must not close the
  # Wi-Fi side for 30 s (ping succeeds if any reply arrives).
  ping -c3 -i0.3 -W1 "$gw" >/dev/null 2>&1 || return 0
  # Wait for the kernel's own confirmation. A STALE entry that gets used goes to DELAY,
  # and about 5 s later Linux asks the router directly for its MAC (PROBE); only an answer
  # makes it REACHABLE. On another network the old home entry fails that and goes FAILED.
  local i state
  for i in 1 2 3 4 5 6 7 8 9; do
    entry=$(ip neigh show "$gw")
    state=${entry##* }
    case $state in
      REACHABLE) break ;;
      DELAY|PROBE) sleep 1 ;;
      *) return 0 ;;   # STALE (unused), FAILED, INCOMPLETE: not confirmed
    esac
  done
  [ "$state" = REACHABLE ] || return 0
  awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print tolower($(i + 1))}' <<<"$entry" | head -1
}
saved() {  # key -> value from the home file, only if it has the right shape
  [ -f "$HOME_FILE" ] || return 0
  sed -n "s/^$1=//p" "$HOME_FILE" | head -1
}

# The address to listen on besides 127.0.0.1, or nothing.
lan_bind() {
  local addr mac
  addr=$(saved ADDR); mac=$(saved GATEWAY_MAC)
  [[ $addr =~ $IP_RE ]] && [[ $mac =~ $MAC_RE ]] || return 0
  # (not `ip ... | grep -q`: with pipefail, grep -q stopping early makes the pipe "fail")
  local addrs; addrs=$(ip -4 -o addr)
  grep -qF " inet $addr/" <<<"$addrs" || return 0   # -F: the dots are dots, not "any character"
  [ "$(gateway_mac)" = "$mac" ] && echo "$addr"
}

# This machine's Tailscale address (100.64.0.0/10, on tailscale0) while Tailscale is up, or
# nothing. Without it the phone listener stays on 127.0.0.1: a missing address must never
# stop Caddy from starting (that would take every site down with it).
TAILNET_RE='^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$'
TAILNET_DEV=${MINI_DEPLOY_TAILNET_DEV:-tailscale0}   # override only for tests ("Tailscale is down")
tailnet_bind() {
  local addrs addr; addrs=$(ip -4 -o addr show dev "$TAILNET_DEV" 2>/dev/null)
  addr=$(sed -n 's/.* inet \([0-9.]*\)\/32 .*/\1/p' <<<"$addrs" | head -1)
  [[ $addr =~ $TAILNET_RE ]] && echo "$addr"
}

# The phone apps' ports, from the Caddyfile's "https://<name>.ts.net:<port> {" lines (the same
# lines the admin page reads). A phone app that is removed is simply not checked any more.
phone_ports() { tr -d '\r' < "$CONF" | sed -n 's/^https:\/\/[a-z0-9.-]*\.ts\.net:\([0-9]\{4,5\}\) {$/\1/p' | sort -un; }

# Every address Caddy listens on now besides loopback, one per line, sorted ("" = only this PC).
# "*", "0.0.0.0" or "[::]" would mean "everywhere": that shows up here too, and never matches.
listening_lan() { ss -ltnH 'sport = :8080' | awk '{print $4}' | sed 's/:8080$//' | grep -vx '127\.0\.0\.1' | sort -u; }

# "<address>:<port>" for every phone port where CADDY itself (not another program) listens
# beyond loopback, and the same list as it should be. Both sides cover exactly the
# Caddyfile's phone ports and only Caddy's own sockets, so they can agree: comparing against
# anything else could make the sync reload every 30 s, forever.
listening_tailnet() {
  local p out
  for p in $(phone_ports); do
    out=$(ss -ltnpH "sport = :$p")
    grep '"caddy"' <<<"$out" | awk '{print $4}' | grep -v '^127\.0\.0\.1:'
  done | sort -u
}
wanted_tailnet() {
  local p addr; addr=$(tailnet_bind)
  [ -n "$addr" ] || return 0
  for p in $(phone_ports); do echo "$addr:$p"; done | sort -u
}

# What should be open, and what is: "<Wi-Fi address>|<Tailscale address:port ...>", empty = closed.
oneline() { tr '\n' ' ' | sed 's/ $//'; }
wanted() { echo "$(lan_bind)|$(wanted_tailnet | oneline)"; }
current() { echo "$(listening_lan | oneline)|$(listening_tailnet | oneline)"; }

# Can this address and port be taken right now? Asks the kernel itself: in mirrored WSL a
# Windows program shares 127.0.0.1, and `ss` here would not show it.
port_free() {
  python3 -c 'import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2]))); s.close()' "$1" "$2" 2>/dev/null
}
# Phone ports another program holds, checked before Caddy starts. If one were taken, `caddy
# run` would fail as a whole and take this PC's sites down with the phone site.
busy_phone_ports() {
  local p a
  for p in $(phone_ports); do
    for a in 127.0.0.1 ${MINI_DEPLOY_TAILNET_BIND:-}; do
      port_free "$a" "$p" || { echo "$p"; break; }
    done
  done
}
# The adapted config without the servers on the given ports (on stdout).
fallback_config() {
  caddy adapt --adapter caddyfile --config "$CONF" 2>/dev/null | BUSY="$*" python3 -c 'import json, os, sys
busy = set(os.environ["BUSY"].split())
c = json.load(sys.stdin)
servers = c["apps"]["http"]["servers"]
for name in list(servers):
    if any(l.rsplit(":", 1)[-1] in busy for l in servers[name]["listen"]):
        del servers[name]
json.dump(c, sys.stdout)'
}

# One sync or reload at a time (the 30 s timer, `systemctl reload`, the tests).
LOCK=/run/mini-deploy-caddy.lock
take_lock() { exec 9>"$LOCK"; flock -w "$1" 9; }   # $1 = seconds to wait

describe() {
  echo "127.0.0.1${MINI_DEPLOY_LAN_BIND:+ and $MINI_DEPLOY_LAN_BIND (home Wi-Fi)}${MINI_DEPLOY_TAILNET_BIND:+; phone apps also on $MINI_DEPLOY_TAILNET_BIND (Tailscale)}"
}

set_binds() {
  export MINI_DEPLOY_LAN_BIND MINI_DEPLOY_TAILNET_BIND
  MINI_DEPLOY_LAN_BIND=$(lan_bind)
  MINI_DEPLOY_TAILNET_BIND=$(tailnet_bind)
}

do_reload() {
  set_binds
  echo "caddy: reload, listening on $(describe)"
  # caddy reload checks the new config first; if it is refused, the old one keeps serving.
  caddy reload --adapter caddyfile --config "$CONF"
}

case "${1:-}" in
  run)
    set_binds
    busy=$(busy_phone_ports | sort -u | oneline)
    if [ -n "$busy" ]; then
      echo "caddy: WARNING: phone port(s) $busy are taken by another program; starting WITHOUT the phone site(s), so this PC's sites still come up (see: run-caddy.sh status)"
      fb=/run/mini-deploy-caddy-fallback.json
      # shellcheck disable=SC2086  # $busy is digits and spaces only
      if fallback_config $busy > "$fb.tmp" && [ -s "$fb.tmp" ] && mv "$fb.tmp" "$fb"; then
        echo "caddy: listening on $(describe), phone port(s) $busy left out until a reload succeeds"
        exec caddy run --config "$fb"
      fi
      echo "caddy: could not build the fallback config; starting the full one"
    fi
    echo "caddy: listening on $(describe)"
    exec caddy run --adapter caddyfile --config "$CONF"
    ;;
  reload)
    take_lock 60 || { echo "caddy: another reload or sync is still running; try again"; exit 1; }
    do_reload
    ;;
  sync)
    take_lock 0 || exit 0      # another sync or reload is running: it will do this
    want=$(wanted); have=$(current)
    [ "$want" = "$have" ] && { rm -f "$FAILED_MARK"; exit 0; }
    # Before changing anything, ask again 2 s later: one router reply that came too late
    # must not close the Wi-Fi side (and cut the phone off). Act only if both agree.
    sleep 2
    [ "$(wanted)" = "$want" ] || exit 0
    if grep -qE '(^|[ |])(\*|0\.0\.0\.0|\[::\])($|[ |])' <<<"$have"; then
      echo "caddy: WARNING: listening on all addresses ($have); this config never does that, reloading"
    fi
    # Back off: if this exact change failed less than RETRY_AFTER seconds ago, wait.
    if [ -f "$FAILED_MARK" ] && [ "$(cat "$FAILED_MARK" 2>/dev/null)" = "$want" ] \
       && [ $(( $(date +%s) - $(stat -c %Y "$FAILED_MARK") )) -lt $RETRY_AFTER ]; then
      exit 0
    fi
    echo "caddy: network changed (Wi-Fi|Tailscale listening on '$have', should be '$want'), reloading"
    if do_reload >/dev/null 2>&1; then
      # "Reloaded" is not proof: check what Caddy really listens on. If it still differs, back
      # off like a failure, instead of reloading again on every run of the timer.
      sleep 1
      now=$(current)
      if [ "$now" = "$want" ]; then
        rm -f "$FAILED_MARK"
      else
        echo "$want" > "$FAILED_MARK"
        echo "caddy: reloaded, but Caddy listens on '$now' (should be '$want'); next try in ${RETRY_AFTER}s (see: run-caddy.sh status)"
        exit 1
      fi
    else
      echo "$want" > "$FAILED_MARK"
      echo "caddy: reload FAILED; Caddy keeps its current config. Next try in ${RETRY_AFTER}s (see: systemctl reload mini-deploy-caddy)"
      exit 1
    fi
    ;;
  status)
    want=$(lan_bind); have=$(listening_lan); tail_want=$(tailnet_bind); tail_have=$(listening_tailnet)
    echo "home network saved:  $([ -f "$HOME_FILE" ] && echo yes || echo 'no (run: run-caddy.sh remember-home, at home)')"
    echo "at home right now:   $([ -n "$want" ] && echo "yes ($want)" || echo no)"
    echo "Caddy listens on:    127.0.0.1${have:+ and $(tr '\n' ' ' <<<"$have")}"
    echo "Tailscale up:        $([ -n "$tail_want" ] && echo "yes ($tail_want)" || echo no)"
    echo "phone app ports:     $(phone_ports | oneline) (Caddy on 127.0.0.1${tail_have:+ and $(oneline <<<"$tail_have")})"
    for p in $(phone_ports); do
      out=$(ss -ltnpH "sport = :$p"); others=$(grep -v '"caddy"' <<<"$out" | sed '/^$/d')
      [ -n "$others" ] && echo "WARNING: port $p is also held by: $(awk '{print $4, $6}' <<<"$others" | oneline)"
    done
    if [ -f "$FAILED_MARK" ]; then
      echo "last network reload:  FAILED (retried after ${RETRY_AFTER}s; check: journalctl -u mini-deploy-caddy-sync)"
    fi
    ;;
  check-start)
    # Meant for before Caddy starts (and for the tests, on a copy of the Caddyfile): while Caddy
    # runs, it holds the phone ports itself, so they all show as taken.
    set_binds
    busy=$(busy_phone_ports | sort -u | oneline)
    echo "taken phone ports: ${busy:-none}"
    if [ -n "$busy" ]; then
      # shellcheck disable=SC2086
      fallback_config $busy | python3 -c 'import json, sys
s = json.load(sys.stdin)["apps"]["http"]["servers"]
print("fallback listens on:", " ".join(sorted(l for v in s.values() for l in v["listen"])))'
    fi
    ;;
  remember-home)
    addr=$(ip -4 -o route get "$(gateway_ip)" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    mac=$(gateway_mac)
    if ! [[ $addr =~ $IP_RE ]] || ! [[ $mac =~ $MAC_RE ]]; then
      echo "error: could not read this network's address and router (address '$addr', router '$mac')" >&2; exit 1
    fi
    mkdir -p "$(dirname "$HOME_FILE")"; chmod 700 "$(dirname "$HOME_FILE")"
    umask 077; printf 'ADDR=%s\nGATEWAY_MAC=%s\n' "$addr" "$mac" > "$HOME_FILE"
    echo "saved this network as home: address $addr, router hardware address saved (root-only file $HOME_FILE)"
    echo "apply it now with: systemctl reload mini-deploy-caddy (the 30 s timer would do it too)"
    ;;
  *)
    sed -n '2,11p' "$0"; exit 2
    ;;
esac
