#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared paths and strict, non-executable configuration reader.
VERSION=0.1.0
ROOT=${WUM_ROOT:-}
CONFIG="$ROOT/etc/wireguard-uptime-monitor/peers.d"
STATE="$ROOT/var/lib/wireguard-uptime-monitor"
LOCK="$ROOT/run/lock/wireguard-uptime-monitor.lock"
umask 077
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_root() { [[ $EUID == 0 || ${WUM_TESTING:-0} == 1 ]] || fail 'Run with sudo.'; }
valid_name() { [[ $1 =~ ^VPN-[A-Z0-9][A-Z0-9-]*-[0-9]{3}$ ]]; }
valid_ip() {
    local octet
    [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local -a parts
    IFS=. read -r -a parts <<< "$1"
    for octet in "${parts[@]}"; do [[ $octet == 0 || $octet != 0* ]] && ((10#$octet <= 255)) || return 1; done
}
valid_url() {
    # No userinfo, config metacharacters, query, fragment, or whitespace.
    [[ $1 =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]{1,5})?/api/push/[a-zA-Z0-9_-]+$ ]]
}
load_peer() {
    local file=$1 key value
    NAME='' IP='' TCP='' PUSH_URL='' CLIENT='' LOCATION='' ENABLED=no THRESHOLD=600
    declare -A seen=()
    [[ -f $file && ! -L $file ]] || return 1
    while IFS='=' read -r key value || [[ -n $key ]]; do
        [[ -z $key || $key == \#* ]] && continue
        [[ ! ${seen[$key]+yes} ]] || return 1
        seen[$key]=1
        case $key in
            NAME) NAME=$value;; IP) IP=$value;; TCP) TCP=$value;;
            PUSH_URL) PUSH_URL=$value;; CLIENT) CLIENT=$value;; LOCATION) LOCATION=$value;;
            ENABLED) ENABLED=$value;; THRESHOLD) THRESHOLD=$value;; *) return 1;;
        esac
    done < "$file"
    valid_name "$NAME" && valid_ip "$IP" && valid_url "$PUSH_URL" || return 1
    [[ $ENABLED == yes || $ENABLED == no ]] || return 1
    [[ $THRESHOLD =~ ^[1-9][0-9]{0,6}$ ]] || return 1
    [[ -z $TCP || $TCP =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]] || return 1
    if [[ -n $TCP ]]; then local port=${TCP##*:}; ((10#$port > 0 && 10#$port <= 65535)) || return 1; fi
    local suffix
    printf -v suffix '%03d' "${IP##*.}"
    [[ $NAME == *-"$suffix" ]]
}
init_dirs() { mkdir -p "$CONFIG" "$STATE" "${LOCK%/*}"; chmod 700 "$CONFIG" "$STATE"; }
lock_all() { exec 9>"$LOCK"; flock -n 9 || fail 'Another monitor or configuration command is running.'; }
health() {
    ping -n -c 1 -W 2 "$IP" >/dev/null 2>&1 || return 1
    if [[ -n $TCP ]]; then
        # Values are passed as positional arguments, never interpolated as code.
        # shellcheck disable=SC2016
        timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${TCP%:*}" "${TCP##*:}" >/dev/null 2>&1 || return 1
    fi
}
push() {
    local status=$1 message=$2
    # Keep the secret out of argv and discard curl diagnostics (which can contain URLs).
    printf 'url = "%s"\n' "$PUSH_URL" |
        curl -q --config - --silent --fail --output /dev/null --connect-timeout 5 --max-time 10 \
        --proto '=http,https' --get --data-urlencode "status=$status" \
        --data-urlencode "msg=$message" --data-urlencode 'ping=' >/dev/null 2>&1
}
write_state() {
    local tmp
    tmp=$(mktemp "$STATE/.state.XXXXXX")
    printf '%s\t%s\n' "$1" "$2" > "$tmp"
    mv -f "$tmp" "$STATE/$NAME.state"
}
