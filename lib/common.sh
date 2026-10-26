#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared paths and strict, non-executable configuration reader.
VERSION=0.2.0
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
    # Bare Kuma Push URL only. Reject malformed authorities and out-of-range ports.
    [[ $1 =~ ^https?://([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)(:([0-9]{1,5}))?/api/push/[a-zA-Z0-9_-]+$ ]] || return 1
    local host=${BASH_REMATCH[1]} port=${BASH_REMATCH[4]}
    [[ $host != *..* && $host != *.-* && $host != *-.* ]] || return 1
    [[ -z $port ]] || ((10#$port > 0 && 10#$port <= 65535))
}
load_peer() {
    local file=$1 key value
    NAME='' IP='' TCP='' PUSH_URL='' CLIENT='' LOCATION='' ENABLED=no THRESHOLD=300
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
save_peer() {
    # Caller holds the configuration lock. Rename is atomic on this filesystem.
    local target=$1 tmp
    tmp=$(mktemp "$CONFIG/.peer.XXXXXX") || return 1
    if ! printf 'NAME=%s\nIP=%s\nTCP=%s\nPUSH_URL=%s\nTHRESHOLD=%s\nENABLED=%s\nCLIENT=%s\nLOCATION=%s\n' \
        "$NAME" "$IP" "$TCP" "$PUSH_URL" "$THRESHOLD" "$ENABLED" "$CLIENT" "$LOCATION" > "$tmp" ||
        ! load_peer "$tmp" || ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}
health() {
    timeout 3 ping -n -c 1 -W 2 "$IP" >/dev/null 2>&1 || return 1
    if [[ -n $TCP ]]; then
        # Values are positional arguments, never interpolated as code.
        # shellcheck disable=SC2016
        timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${TCP%:*}" "${TCP##*:}" >/dev/null 2>&1 || return 1
    fi
}
push() {
    local status=$1 message=$2 attempt code rc delay=1
    for attempt in 1 2 3; do
        # Keep tokens out of argv, responses and diagnostics. Never follow redirects.
        rc=0
        code=$(printf 'url = "%s"\n' "$PUSH_URL" |
            curl -q --config - --silent --fail --output /dev/null --write-out '%{http_code}' \
            --connect-timeout 3 --max-time 8 --proto '=http,https' --get \
            --data-urlencode "status=$status" --data-urlencode "msg=$message" \
            --data-urlencode 'ping=' 2>/dev/null) || rc=$?
        # Sanitize even the status string before logging.
        [[ $code =~ ^[0-9]{3}$ ]] || code=000
        if (( rc == 0 )) && [[ $code == 2[0-9][0-9] ]]; then return 0; fi
        printf '%s: Push delivery failed http=%s curl_exit=%s attempt=%s\n' "$NAME" "$code" "$rc" "$attempt" >&2
        (( attempt < 3 )) || break
        case $rc:$code in
            6:*|7:*|18:*|28:*|35:*|52:*|55:*|56:*|*:408|*:429|*:500|*:502|*:503|*:504) ;;
            *) break;;
        esac
        sleep "$delay"
        delay=$((delay * 2))
    done
    return 1
}
read_state() {
    since=0 current=unknown reported=unknown delivery=none
    if [[ -e $STATE/$NAME.state ]]; then
        [[ -f $STATE/$NAME.state && ! -L $STATE/$NAME.state ]] || return 1
        IFS=$'\t' read -r since current reported delivery < "$STATE/$NAME.state" || return 1
        # v0.1.0's two-column state did not establish delivery success.
        reported=${reported:-unknown}; delivery=${delivery:-none}
    fi
    [[ $since =~ ^(0|[1-9][0-9]{0,11})$ ]] &&
        [[ $current == up || $current == pending || $current == down || $current == unknown ]] &&
        [[ $reported == up || $reported == down || $reported == unknown ]] &&
        [[ $delivery == none || $delivery == delivered || $delivery == failed ]]
}
write_state() {
    local tmp
    tmp=$(mktemp "$STATE/.state.XXXXXX") || return 1
    if ! printf '%s\t%s\t%s\t%s\n' "$since" "$current" "$reported" "$delivery" > "$tmp" ||
        ! mv -f -- "$tmp" "$STATE/$NAME.state"; then
        rm -f -- "$tmp"
        return 1
    fi
}
check_peer() {
    local file=$1 now since current reported delivery result=0
    load_peer "$file" || { printf 'Invalid peer file (details redacted).\n' >&2; return 1; }
    [[ $ENABLED == yes ]] || return 0
    read_state || { printf '%s: invalid state; repair required.\n' "$NAME" >&2; return 1; }
    now=$(date +%s)
    if health; then
        since=0 current=up
    else
        if (( since == 0 || since > now )); then since=$now; fi
        if (( now - since >= THRESHOLD )); then current=down; else current=pending; fi
    fi
    if [[ $current != pending ]]; then
        local message='Tunnel reachable'
        [[ $current != down ]] || message='Tunnel unreachable beyond threshold'
        if push "$current" "$message"; then
            reported=$current delivery=delivered
        else
            # Never claim recovery was delivered until Kuma acknowledges it.
            delivery=failed result=1
        fi
    fi
    write_state || return 1
    printf '%s vpn=%s reported=%s delivery=%s\n' "$NAME" "$current" "$reported" "$delivery"
    return "$result"
}
