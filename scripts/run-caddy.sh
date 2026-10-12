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
CONF=$REPO/caddy/Caddyfile
HOME_FILE=/etc/mini-deploy/home-lan
IP_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
MAC_RE='^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'

gateway_ip()  { ip -4 route show default | awk '{print $3; exit}'; }
gateway_mac() {
  local gw; gw=$(gateway_ip)
  [ -n "$gw" ] || return 0
  ping -c1 -W1 "$gw" >/dev/null 2>&1   # make sure the router is in the neighbour table
  ip neigh show "$gw" | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print tolower($(i + 1))}' | head -1
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
  grep -q " inet $addr/" <<<"$addrs" || return 0
  [ "$(gateway_mac)" = "$mac" ] && echo "$addr"
}

# What Caddy listens on now, besides loopback (empty if only loopback).
listening_lan() { ss -ltnH 'sport = :8080' | awk '{print $4}' | sed 's/:8080$//' | grep -v '^127\.0\.0\.1$' | head -1; }

case "${1:-}" in
  run)
    export MINI_DEPLOY_LAN_BIND; MINI_DEPLOY_LAN_BIND=$(lan_bind)
    echo "caddy: listening on 127.0.0.1${MINI_DEPLOY_LAN_BIND:+ and $MINI_DEPLOY_LAN_BIND (home Wi-Fi)}"
    exec caddy run --adapter caddyfile --config "$CONF"
    ;;
  reload)
    export MINI_DEPLOY_LAN_BIND; MINI_DEPLOY_LAN_BIND=$(lan_bind)
    echo "caddy: reload, listening on 127.0.0.1${MINI_DEPLOY_LAN_BIND:+ and $MINI_DEPLOY_LAN_BIND (home Wi-Fi)}"
    exec caddy reload --adapter caddyfile --config "$CONF"
    ;;
  sync)
    want=$(lan_bind); have=$(listening_lan)
    [ "$want" = "$have" ] && exit 0
    echo "caddy: network changed (listening on '${have:-only this PC}', should be '${want:-only this PC}'), reloading"
    exec systemctl reload mini-deploy-caddy
    ;;
  status)
    want=$(lan_bind); have=$(listening_lan)
    echo "home network saved:  $([ -f "$HOME_FILE" ] && echo yes || echo 'no (run: run-caddy.sh remember-home, at home)')"
    echo "at home right now:   $([ -n "$want" ] && echo "yes ($want)" || echo no)"
    echo "Caddy listens on:    127.0.0.1${have:+ and $have}"
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
