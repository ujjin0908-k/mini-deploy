#!/usr/bin/env bash
# Start or reload Caddy, listening on the home Wi-Fi ONLY when this PC is really at home.
#
#   run-caddy.sh run             start Caddy in the foreground (the systemd service uses this)
#   run-caddy.sh reload          apply caddy/Caddyfile again (systemctl reload uses this)
#   run-caddy.sh sync            reload only if "at home?" changed (a 30 s timer runs this)
#   run-caddy.sh status          say what Caddy listens on and why
#   run-caddy.sh remember-home   run once, AT HOME: save this network as home
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

# Every address Caddy listens on now besides loopback, one per line, sorted ("" = only this PC).
# "*", "0.0.0.0" or "[::]" would mean "everywhere": that shows up here too, and never matches.
listening_lan() { ss -ltnH 'sport = :8080' | awk '{print $4}' | sed 's/:8080$//' | grep -vx '127\.0\.0\.1' | sort -u; }

do_reload() {
  export MINI_DEPLOY_LAN_BIND; MINI_DEPLOY_LAN_BIND=$(lan_bind)
  echo "caddy: reload, listening on 127.0.0.1${MINI_DEPLOY_LAN_BIND:+ and $MINI_DEPLOY_LAN_BIND (home Wi-Fi)}"
  # caddy reload checks the new config first; if it is refused, the old one keeps serving.
  caddy reload --adapter caddyfile --config "$CONF"
}

case "${1:-}" in
  run)
    export MINI_DEPLOY_LAN_BIND; MINI_DEPLOY_LAN_BIND=$(lan_bind)
    echo "caddy: listening on 127.0.0.1${MINI_DEPLOY_LAN_BIND:+ and $MINI_DEPLOY_LAN_BIND (home Wi-Fi)}"
    exec caddy run --adapter caddyfile --config "$CONF"
    ;;
  reload)
    do_reload
    ;;
  sync)
    want=$(lan_bind); have=$(listening_lan)
    [ "$want" = "$have" ] && { rm -f "$FAILED_MARK"; exit 0; }
    # Before changing anything, ask again 2 s later: one router reply that came too late
    # must not close the Wi-Fi side (and cut the phone off). Act only if both agree.
    sleep 2
    [ "$(lan_bind)" = "$want" ] || exit 0
    if grep -qxE '\*|0\.0\.0\.0|\[::\]' <<<"$have"; then
      echo "caddy: WARNING: listening on all addresses ($(tr '\n' ' ' <<<"$have")); this config never does that, reloading"
    fi
    # Back off: if this exact change failed less than RETRY_AFTER seconds ago, wait.
    if [ -f "$FAILED_MARK" ] && [ "$(cat "$FAILED_MARK" 2>/dev/null)" = "${want:-loopback}" ] \
       && [ $(( $(date +%s) - $(stat -c %Y "$FAILED_MARK") )) -lt $RETRY_AFTER ]; then
      exit 0
    fi
    echo "caddy: network changed (listening on '$(tr '\n' ' ' <<<"${have:-only this PC}")', should be '${want:-only this PC}'), reloading"
    if do_reload >/dev/null 2>&1; then
      rm -f "$FAILED_MARK"
    else
      echo "${want:-loopback}" > "$FAILED_MARK"
      echo "caddy: reload FAILED; Caddy keeps its current config. Next try in ${RETRY_AFTER}s (see: systemctl reload mini-deploy-caddy)"
      exit 1
    fi
    ;;
  status)
    want=$(lan_bind); have=$(listening_lan)
    echo "home network saved:  $([ -f "$HOME_FILE" ] && echo yes || echo 'no (run: run-caddy.sh remember-home, at home)')"
    echo "at home right now:   $([ -n "$want" ] && echo "yes ($want)" || echo no)"
    echo "Caddy listens on:    127.0.0.1${have:+ and $(tr '\n' ' ' <<<"$have")}"
    if [ -f "$FAILED_MARK" ]; then
      echo "last network reload:  FAILED (retried after ${RETRY_AFTER}s; check: journalctl -u mini-deploy-caddy-sync)"
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
    sed -n '2,9p' "$0"; exit 2
    ;;
esac
