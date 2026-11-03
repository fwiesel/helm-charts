#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Activate this agent's SCI systemd extensions from one signed release.
#
# One pass, then exit. The caller runs this as a privileged init container in
# the DaemonSet that needs the extensions. The chart supplies this script in
# its bin ConfigMap; the existing agent image provides the tools.
#
# This is a consumer of the artifact published by gardenlinux-sci. It is not
# the delivery step from that repository, and it does not depend on it.
set -Eeuo pipefail

HOST_ROOT=${HOST_ROOT:-/host}
SCI_RELEASE_URL=${SCI_RELEASE_URL:-}
SCI_SUMS_DIGEST=${SCI_SUMS_DIGEST:-}
SCI_PUBKEY=${SCI_PUBKEY:-}
SCI_PUBKEY_FILE=${SCI_PUBKEY_FILE:-}
SCI_EXTENSIONS=${SCI_EXTENSIONS:-}
SCI_STATE_DIR=${SCI_STATE_DIR:-}
SCI_DEADLINE=${SCI_DEADLINE:-900}
SCI_NSENTER=${SCI_NSENTER:-1}
SCI_AGENT=${SCI_AGENT:-}

STATE_DIR=${SCI_STATE_DIR:-$HOST_ROOT/var/lib/sci-sysext}

CLEANUP=()
declare -A SUM=() LISTED=() UNITS=() RAW_CHANGED=() SHIM_CHANGED=()
MANIFEST_NAMES=()
SELECTED=()
WANTED=()
REQUESTED=()

log() { printf '[activate-sci-sysext:%s] %s\n' "$SCI_AGENT" "$*"; }
warn() { printf '[activate-sci-sysext:%s] warning: %s\n' "$SCI_AGENT" "$*" >&2; }
die() {
    printf '[activate-sci-sysext:%s] error: %s\n' "$SCI_AGENT" "$*" >&2
    exit 1
}

cleanup() {
    local path
    for path in "${CLEANUP[@]}"; do
        [ -n "$path" ] && rm -rf -- "$path"
    done
}

remaining() {
    local value=$((SCI_DEADLINE - SECONDS))
    if [ "$value" -gt 0 ]; then
        printf '%s' "$value"
    else
        printf '1'
    fi
}

check_deadline() { # <phase>
    [ "$SECONDS" -lt "$SCI_DEADLINE" ] \
        || die "deadline of ${SCI_DEADLINE}s exceeded during: $1"
}

validate_config() {
    [ -n "$SCI_RELEASE_URL" ] || die "SCI_RELEASE_URL is empty"
    case $SCI_RELEASE_URL in
        http://* | https://* | file://*) ;;
        *) die "SCI_RELEASE_URL must start with http://, https:// or file://" ;;
    esac
    if [ -n "$SCI_SUMS_DIGEST" ]; then
        [[ $SCI_SUMS_DIGEST =~ ^[0-9a-f]{64}$ ]] \
            || die "SCI_SUMS_DIGEST must be 64 lowercase hex characters"
    fi
    [ -n "$SCI_EXTENSIONS" ] || die "SCI_EXTENSIONS is empty"
    read -r -a REQUESTED <<<"${SCI_EXTENSIONS//$'\n'/ }"
    local name
    for name in "${REQUESTED[@]}"; do
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || die "SCI_EXTENSIONS carries an invalid extension name: '$name'"
    done
    [[ $SCI_AGENT =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || die "SCI_AGENT must be a safe agent name"
    case $SCI_NSENTER in
        0 | 1) ;;
        *) die "SCI_NSENTER must be 0 or 1: $SCI_NSENTER" ;;
    esac
    [[ $SCI_DEADLINE =~ ^[1-9][0-9]*$ ]] \
        || die "SCI_DEADLINE must be a positive integer: $SCI_DEADLINE"
}

prepare_state() {
    umask 077
    mkdir -p -- "$STATE_DIR/cache" \
        || die "cannot create the state directory: $STATE_DIR"
    export LC_ALL=C
    WORK=$(mktemp -d "$STATE_DIR/.fetch.XXXXXX") \
        || die "cannot create a temporary directory under $STATE_DIR"
    CLEANUP+=("$WORK")

    if [ -n "$SCI_PUBKEY_FILE" ]; then
        PUBKEY=$SCI_PUBKEY_FILE
        [ -r "$PUBKEY" ] || die "SCI_PUBKEY_FILE is not readable: $PUBKEY"
    elif [ -n "$SCI_PUBKEY" ]; then
        PUBKEY=$WORK/pubkey.pem
        printf '%s\n' "$SCI_PUBKEY" >"$PUBKEY" \
            || die "cannot write the public key"
    else
        die "neither SCI_PUBKEY nor SCI_PUBKEY_FILE is set"
    fi
}

run_host() {
    check_deadline "host command"
    if [ "$SCI_NSENTER" -eq 1 ]; then
        timeout --foreground "$(remaining)" nsenter -t 1 -m -r -w -- "$@"
    else
        timeout --foreground "$(remaining)" "$@"
    fi
}

run_sysext_refresh() {
    if [ "$SCI_NSENTER" -eq 1 ] \
        && [ -x "$HOST_ROOT/usr/lib/systemd/systemd-sysext" ]; then
        run_host /usr/lib/systemd/systemd-sysext refresh
    else
        run_host systemd-sysext refresh
    fi
}

sha256_of() {
    local out
    out=$(sha256sum -- "$1") || return 1
    printf '%s' "${out%% *}"
}

fetch_get() { # <inventory name> <destination>
    check_deadline "download"
    curl -fsSL --proto '=https,http,file' \
        --connect-timeout 10 --max-time "$(remaining)" \
        --retry 2 --retry-connrefused --retry-max-time "$(remaining)" \
        -o "$2" -- "$SCI_RELEASE_URL/$1" \
        || die "cannot fetch release file $1"
}

verify_inventory() {
    check_deadline "fetch"
    fetch_get SHA256SUMS "$WORK/SHA256SUMS"
    fetch_get SHA256SUMS.sig "$WORK/SHA256SUMS.sig"

    if [ -n "$SCI_SUMS_DIGEST" ]; then
        local actual
        actual=$(sha256_of "$WORK/SHA256SUMS") \
            || die "cannot hash the downloaded SHA256SUMS"
        [ "$actual" = "$SCI_SUMS_DIGEST" ] \
            || die "SHA256SUMS digest mismatch: got $actual, expected $SCI_SUMS_DIGEST"
    fi

    openssl dgst -sha256 -verify "$PUBKEY" \
        -signature "$WORK/SHA256SUMS.sig" "$WORK/SHA256SUMS" >/dev/null 2>&1 \
        || die "SHA256SUMS.sig does not verify against the configured public key"

    SUMS_SHA=$(sha256_of "$WORK/SHA256SUMS") \
        || die "cannot hash the downloaded SHA256SUMS"
    log "verified SHA256SUMS signature (build $SUMS_SHA)"
}

parse_inventory() {
    local line lineno=0 hash rest name
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        rest=${line#* }
        [ "$rest" != "$line" ] \
            || die "SHA256SUMS line $lineno carries no file name: $line"
        hash=${line%% *}
        name=${rest# }
        name=${name#\*}
        [[ $hash =~ ^[0-9a-f]{64}$ ]] \
            || die "SHA256SUMS line $lineno does not start with a sha256: $line"
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || die "SHA256SUMS line $lineno has an invalid file name: $line"
        [ -z "${LISTED[$name]+set}" ] \
            || die "SHA256SUMS lists '$name' twice (line $lineno)"
        SUM[$name]=$hash
        LISTED[$name]=1
    done <"$WORK/SHA256SUMS"
    [ "${#SUM[@]}" -gt 0 ] || die "SHA256SUMS is empty"
}

parse_manifest() { # <path>
    local path=$1 line name rest unit lineno=0
    local base=
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%%#*}
        line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -n "$line" ] || continue
        case $line in
            TARGET_BASE=*)
                [ -z "$base" ] || die "$path carries more than one TARGET_BASE directive"
                base=${line#TARGET_BASE=}
                [[ $base =~ ^[0-9]+$ ]] || die "$path carries an invalid TARGET_BASE: $base"
                continue
                ;;
            REMOVE=*)
                die "$path contains a removal directive; this agent does not remove host extensions"
                ;;
        esac
        read -r name rest <<<"$line"
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || die "$path line $lineno has an invalid extension name: $name"
        [ -z "${UNITS[$name]+set}" ] \
            || die "$path lists '$name' twice (line $lineno)"
        local -a unit_names=()
        read -r -a unit_names <<<"$rest"
        for unit in "${unit_names[@]}"; do
            [[ $unit =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*\.(service|socket|target)$ ]] \
                || die "$path lists an invalid restart unit: $unit"
        done
        MANIFEST_NAMES+=("$name")
        UNITS[$name]=$rest
    done <"$path"
    [ -n "$base" ] \
        || die "$path carries no TARGET_BASE=<major> directive"
    TARGET_BASE=$base
}

select_extensions() {
    local token
    local -A requested=()
    for token in "${REQUESTED[@]}"; do
        [ -n "${UNITS[$token]+set}" ] \
            || die "SCI_EXTENSIONS lists '$token', which the release manifest does not deploy"
        [ -n "${LISTED[$token.raw]+set}" ] \
            || die "SCI_EXTENSIONS lists '$token', which SHA256SUMS does not carry"
        requested[$token]=1
    done

    WANTED=(extensions.manifest)
    [ -n "${LISTED[verity-run.crt]+set}" ] && WANTED+=(verity-run.crt)

    # Manifest order, not request order: the manifest is the merge order.
    for token in "${MANIFEST_NAMES[@]}"; do
        [ -n "${requested[$token]+set}" ] || continue
        SELECTED+=("$token")
        WANTED+=("$token.raw")
        if [ -n "${LISTED[$token-activation.service]+set}" ]; then
            WANTED+=("$token-activation.service")
        fi
    done
    [ "${#SELECTED[@]}" -gt 0 ] || die "SCI_EXTENSIONS selected no extension"
}

download() {
    check_deadline "download"
    local name dest part actual
    for name in "${WANTED[@]}"; do
        dest=$CACHE/$name
        if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "${SUM[$name]}" ]; then
            continue
        fi
        # Downloads stay concurrent. A unique temporary file and an atomic
        # rename make duplicate fetches safe without locking the whole pass.
        part=$(mktemp "$CACHE/.$name.XXXXXX")
        CLEANUP+=("$part")
        fetch_get "$name" "$part"
        actual=$(sha256_of "$part") \
            || die "cannot hash the downloaded $name"
        if [ "$actual" != "${SUM[$name]}" ]; then
            rm -f -- "$part"
            die "downloaded $name does not match its SHA256SUMS line"
        fi
        mv -f -- "$part" "$dest" \
            || die "cannot move $name into the cache"
        log "downloaded $name"
    done
}

cert_pubkey_sha() { # <certificate>
    openssl x509 -in "$1" -noout -pubkey 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | sha256sum | cut -d' ' -f1
}

preflight_anchor() {
    local cert=$CACHE/verity-run.crt
    [ -f "$cert" ] \
        || die "the release carries no verity-run.crt; cannot check the host trust anchor"

    local want
    want=$(cert_pubkey_sha "$cert") || die "cannot read the release certificate $cert"
    [ -n "$want" ] || die "cannot read the release certificate $cert"

    local dir=$HOST_ROOT/usr/lib/verity.d
    [ -d "$dir" ] \
        || die "$dir does not exist: the base image carries no sysext trust anchor"

    local found=0 candidate fingerprint
    for candidate in "$dir"/*.crt; do
        [ -e "$candidate" ] || continue
        fingerprint=$(cert_pubkey_sha "$candidate") || continue
        if [ "$fingerprint" = "$want" ]; then
            found=1
            break
        fi
    done
    [ "$found" -eq 1 ] \
        || die "no certificate in $dir matches the release signing key; provision the host trust anchor before starting this agent"
    log "matching host public key found; systemd-sysext will verify the raws at merge"
}

check_base() {
    local os_release=$HOST_ROOT/etc/os-release
    [ -r "$os_release" ] || die "cannot read $os_release"
    local version
    version=$(sed -n 's/^IMAGE_VERSION="\{0,1\}\([0-9][0-9.]*\)"\{0,1\}$/\1/p' "$os_release" | head -n 1)
    if [ -z "$version" ]; then
        version=$(sed -n 's/^VERSION_ID="\{0,1\}\([0-9][0-9.]*\)"\{0,1\}$/\1/p' "$os_release" | head -n 1)
    fi
    [ -n "$version" ] || die "$os_release carries no machine image version"
    case $version in
        "$TARGET_BASE" | "$TARGET_BASE".*) ;;
        *) die "host base is $version, but the release targets $TARGET_BASE" ;;
    esac
}

ROLLBACK_DESTS=()
ROLLBACK_BACKUPS=()

save_previous() { # <destination>
    local dest=$1 backup=
    if [ -f "$dest" ]; then
        backup=$(mktemp -d "$STATE_DIR/.rollback.XXXXXX") \
            || die "cannot create a rollback directory"
        CLEANUP+=("$backup")
        cp -a -- "$dest" "$backup/file" \
            || die "cannot save the previous version of $dest"
        backup=$backup/file
    fi
    ROLLBACK_DESTS+=("$dest")
    ROLLBACK_BACKUPS+=("$backup")
}

restore_previous() {
    local i dest backup
    for i in "${!ROLLBACK_DESTS[@]}"; do
        dest=${ROLLBACK_DESTS[$i]}
        backup=${ROLLBACK_BACKUPS[$i]}
        if [ -n "$backup" ]; then
            cp -a -- "$backup" "$dest" \
                || warn "cannot restore $dest"
        else
            rm -f -- "$dest"
        fi
    done
}

deploy_file() { # <source> <destination>; returns 1 when the file changed
    local src=$1 dest=$2 tmp
    [ ! -L "$dest" ] || die "refusing to replace a host symlink: $dest"
    if [ -f "$dest" ] && cmp -s -- "$src" "$dest"; then
        return 1
    fi
    save_previous "$dest"
    mkdir -p -- "$(dirname "$dest")" \
        || die "cannot create $(dirname "$dest")"
    tmp=$(mktemp "$dest.XXXXXX")
    CLEANUP+=("$tmp")
    cp -- "$src" "$tmp" \
        || die "cannot write $dest"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$dest" \
        || die "cannot move $tmp to $dest"
    return 0
}

plan_activation() {
    # Only the host-wide merge needs serialization. Independent agents may
    # download and verify their selections concurrently.
    exec 9>>"$STATE_DIR/lock"
    flock -w "$(remaining)" 9 || die "timed out waiting for the host activation lock"
    PENDING=$STATE_DIR/pending/$SCI_AGENT
    local name src dest wants kind
    for name in "${SELECTED[@]}"; do
        RAW_CHANGED[$name]=0
        SHIM_CHANGED[$name]=0
        src=$CACHE/$name.raw
        dest=$HOST_ROOT/var/lib/extensions/$name.raw
        if ! cmp -s -- "$src" "$dest"; then
            RAW_CHANGED[$name]=1
        fi
        src=$CACHE/$name-activation.service
        dest=$HOST_ROOT/etc/systemd/system/$name-activation.service
        wants=$HOST_ROOT/etc/systemd/system/multi-user.target.wants/$name-activation.service
        if [ -f "$src" ] && { ! cmp -s -- "$src" "$dest" || { [ ! -e "$wants" ] && [ ! -L "$wants" ]; }; }; then
            SHIM_CHANGED[$name]=1
        fi
    done
    # This is a per-agent retry marker, not an ownership/removal ledger.
    if [ -f "$PENDING" ]; then
        while read -r kind name; do
            [ -n "${RAW_CHANGED[$name]+set}" ] \
                || die "pending activation names '$name', which this agent no longer selects"
            case $kind in
                raw) RAW_CHANGED[$name]=1 ;;
                shim) SHIM_CHANGED[$name]=1 ;;
                *) die "invalid pending activation record" ;;
            esac
        done <"$PENDING"
    fi
    ACTIVATION_NEEDED=0
    for name in "${SELECTED[@]}"; do
        if [ "${RAW_CHANGED[$name]}" -eq 1 ] || [ "${SHIM_CHANGED[$name]}" -eq 1 ]; then
            ACTIVATION_NEEDED=1
        fi
    done
    [ "$ACTIVATION_NEEDED" -eq 1 ] || return 0
    mkdir -p -- "$STATE_DIR/pending"
    local marker
    marker=$(mktemp "$STATE_DIR/pending/.pending.XXXXXX")
    CLEANUP+=("$marker")
    for name in "${SELECTED[@]}"; do
        if [ "${RAW_CHANGED[$name]}" -eq 1 ]; then
            printf 'raw %s\n' "$name" >>"$marker"
        fi
        if [ "${SHIM_CHANGED[$name]}" -eq 1 ]; then
            printf 'shim %s\n' "$name" >>"$marker"
        fi
    done
    # Write before deployment: a killed or failed pass cannot silently skip
    # activation merely because the next pass finds identical host files.
    mv -f -- "$marker" "$PENDING"
}

deploy() {
    local name
    for name in "${SELECTED[@]}"; do
        if deploy_file "$CACHE/$name.raw" \
            "$HOST_ROOT/var/lib/extensions/$name.raw"; then
            log "deployed $name.raw"
        fi
        local shim=$CACHE/$name-activation.service
        if [ -f "$shim" ]; then
            if deploy_file "$shim" \
                "$HOST_ROOT/etc/systemd/system/$name-activation.service"; then
                log "deployed $name-activation.service"
            fi
        fi
    done
}

activate() {
    check_deadline "activation"
    if [ "$ACTIVATION_NEEDED" -eq 0 ]; then
        log "host already converged; nothing to activate"
        return 0
    fi

    run_host systemctl daemon-reload \
        || die "systemctl daemon-reload failed"

    if ! run_sysext_refresh; then
        restore_previous
        run_host systemctl daemon-reload || warn "daemon-reload failed after restoring the previous files"
        if run_sysext_refresh; then
            die "systemd-sysext refresh rejected the new set; the previous set was restored"
        fi
        die "systemd-sysext refresh rejected the new set, and restoring the previous set did not help"
    fi
    run_host systemctl reload dbus.service || die "dbus reload failed after the sysext merge"
    log "merged the selected extensions"

    local name units
    local -a restart_units=()
    for name in "${SELECTED[@]}"; do
        units=${UNITS[$name]}
        if [ "${RAW_CHANGED[$name]}" -eq 1 ] && [ -n "$units" ]; then
            read -r -a restart_units <<<"$units"
            run_host systemctl restart "${restart_units[@]}" \
                || die "required unit restart failed for $name: $units"
        fi
        if [ -f "$HOST_ROOT/etc/systemd/system/$name-activation.service" ]; then
            run_host systemctl enable "$name-activation.service" >/dev/null 2>&1 \
                || die "cannot enable $name-activation.service"
            if [ "${RAW_CHANGED[$name]}" -eq 1 ] || [ "${SHIM_CHANGED[$name]}" -eq 1 ]; then
                run_host systemctl restart "$name-activation.service" \
                    || die "cannot activate $name-activation.service"
            fi
        fi
    done
    rm -f -- "$PENDING"
}

main() {
    trap cleanup EXIT
    validate_config
    prepare_state
    verify_inventory
    parse_inventory
    [ -n "${LISTED[extensions.manifest]+set}" ] || die "signed inventory has no extensions.manifest"
    [ -n "${LISTED[verity-run.crt]+set}" ] || die "signed inventory has no verity-run.crt"
    fetch_get extensions.manifest "$WORK/extensions.manifest"
    [ "$(sha256_of "$WORK/extensions.manifest")" = "${SUM[extensions.manifest]}" ] \
        || die "extensions.manifest does not match its SHA256SUMS line"
    parse_manifest "$WORK/extensions.manifest"
    select_extensions

    CACHE=$STATE_DIR/cache/$SUMS_SHA
    mkdir -p -- "$CACHE" || die "cannot create $CACHE"
    download
    preflight_anchor
    check_base
    plan_activation
    deploy
    activate
    log "done: ${#SELECTED[@]} extension(s) selected"
}

main "$@"
