#!/usr/bin/env bash
# sci-consumer: deploy one signed SCI systemd-sysext release into the host.
#
# One pass, then exit. The caller runs this as a privileged init container in
# the DaemonSet that needs the extensions. The contract is in README.md.
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

STATE_DIR=${SCI_STATE_DIR:-$HOST_ROOT/var/lib/sci-sysext}

CLEANUP=()
declare -A SUM=() LISTED=() UNITS=()
MANIFEST_NAMES=()
SELECTED=()
WANTED=()
PREVIOUS_DIGEST=

log() { printf '[sci-consumer] %s\n' "$*"; }
warn() { printf '[sci-consumer] warning: %s\n' "$*" >&2; }
die() {
    printf '[sci-consumer] error: %s\n' "$*" >&2
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
        *) die "SCI_RELEASE_URL must start with http://, https:// or file://: $SCI_RELEASE_URL" ;;
    esac
    if [ -n "$SCI_SUMS_DIGEST" ]; then
        [[ $SCI_SUMS_DIGEST =~ ^[0-9a-f]{64}$ ]] \
            || die "SCI_SUMS_DIGEST must be 64 lowercase hex characters"
    fi
    [ -n "$SCI_EXTENSIONS" ] || die "SCI_EXTENSIONS is empty"
    local name
    for name in $SCI_EXTENSIONS; do
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || die "SCI_EXTENSIONS carries an invalid extension name: '$name'"
    done
    case $SCI_NSENTER in
        0 | 1) ;;
        *) die "SCI_NSENTER must be 0 or 1: $SCI_NSENTER" ;;
    esac
    [[ $SCI_DEADLINE =~ ^[1-9][0-9]*$ ]] \
        || die "SCI_DEADLINE must be a positive integer: $SCI_DEADLINE"
}

prepare_state() {
    mkdir -p -- "$STATE_DIR/cache" \
        || die "cannot create the state directory: $STATE_DIR"
    export LC_ALL=C
    exec 9>>"$STATE_DIR/lock" \
        || die "cannot open the lock file: $STATE_DIR/lock"
    flock -w "$(remaining)" 9 \
        || die "timed out waiting for the host lock: $STATE_DIR/lock"

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
    if [ "$SCI_NSENTER" -eq 1 ]; then
        nsenter -t 1 -m -- "$@"
    else
        "$@"
    fi
}

run_sysext_refresh() {
    if [ "$SCI_NSENTER" -eq 1 ] \
        && [ -x "$HOST_ROOT/usr/lib/systemd/systemd-sysext" ]; then
        nsenter -t 1 -m -- /usr/lib/systemd/systemd-sysext refresh
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
    curl -fsSL --proto '=https,http,file' \
        --connect-timeout 10 --max-time "$(remaining)" \
        --retry 2 --retry-connrefused \
        -o "$2" -- "$SCI_RELEASE_URL/$1" \
        || die "cannot fetch $SCI_RELEASE_URL/$1"
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
    local path=$1 line name rest lineno=0
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
                die "$path carries '$line': this consumer implements no tombstones; remove '$line' from the release manifest, or delete the extension from the host explicitly"
                ;;
        esac
        name=${line%% *}
        rest=
        if [ "$name" != "$line" ]; then
            rest=${line#* }
        fi
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || die "$path line $lineno has an invalid extension name: $name"
        [ -z "${UNITS[$name]+set}" ] \
            || die "$path lists '$name' twice (line $lineno)"
        MANIFEST_NAMES+=("$name")
        UNITS[$name]=$rest
    done <"$path"
    [ -n "$base" ] \
        || die "$path carries no TARGET_BASE=<major> directive"
    TARGET_BASE=$base
}

select_extensions() {
    local token
    for token in $SCI_EXTENSIONS; do
        [ -n "${UNITS[$token]+set}" ] \
            || die "SCI_EXTENSIONS lists '$token', which the release manifest does not deploy"
        [ -n "${LISTED[$token.raw]+set}" ] \
            || die "SCI_EXTENSIONS lists '$token', which SHA256SUMS does not carry"
    done

    WANTED=(extensions.manifest)
    [ -n "${LISTED[verity-run.crt]+set}" ] && WANTED+=(verity-run.crt)

    # Manifest order, not request order: the manifest is the merge order.
    for token in "${MANIFEST_NAMES[@]}"; do
        case " $SCI_EXTENSIONS " in
            *" $token "*) ;;
            *) continue ;;
        esac
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
        part=$dest.part
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
        || die "no certificate in $dir matches the release signing key: install the release verity-run.crt there, or bake it into the base image"
    log "host trust anchor matches the release certificate"
}

check_base() {
    local os_release=$HOST_ROOT/etc/os-release
    [ -r "$os_release" ] || die "cannot read $os_release"
    local version
    version=$(sed -n 's/^VERSION_ID="\{0,1\}\([0-9][0-9.]*\)"\{0,1\}$/\1/p' "$os_release" | head -n 1)
    [ -n "$version" ] || die "$os_release carries no VERSION_ID"
    case $version in
        "$TARGET_BASE".*) ;;
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
    if [ -f "$dest" ] && cmp -s -- "$src" "$dest"; then
        return 1
    fi
    save_previous "$dest"
    mkdir -p -- "$(dirname "$dest")" \
        || die "cannot create $(dirname "$dest")"
    tmp=$dest.tmp.$$
    cp -- "$src" "$tmp" \
        || die "cannot write $dest"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$dest" \
        || die "cannot move $tmp to $dest"
    return 0
}

deploy() {
    local name changed=0
    for name in "${SELECTED[@]}"; do
        if deploy_file "$CACHE/$name.raw" \
            "$HOST_ROOT/var/lib/extensions/$name.raw"; then
            changed=1
            log "deployed $name.raw"
        fi
        local shim=$CACHE/$name-activation.service
        if [ -f "$shim" ]; then
            if deploy_file "$shim" \
                "$HOST_ROOT/etc/systemd/system/$name-activation.service"; then
                changed=1
                log "deployed $name-activation.service"
            fi
        fi
    done
    DEPLOY_CHANGED=$changed
}

activation_needed() {
    local name wants
    [ "$DEPLOY_CHANGED" -eq 1 ] && return 0
    for name in "${SELECTED[@]}"; do
        wants=$HOST_ROOT/etc/systemd/system/multi-user.target.wants/$name-activation.service
        if [ ! -e "$wants" ] && [ ! -L "$wants" ]; then
            return 0
        fi
    done
    return 1
}

activate() {
    check_deadline "activation"
    if ! activation_needed; then
        log "host already converged; nothing to activate"
        return 0
    fi

    run_host systemctl daemon-reload \
        || die "systemctl daemon-reload failed"

    if ! run_sysext_refresh; then
        restore_previous
        if run_sysext_refresh; then
            die "systemd-sysext refresh rejected the new set; the previous set was restored"
        fi
        die "systemd-sysext refresh rejected the new set, and restoring the previous set did not help"
    fi
    log "merged the selected extensions"

    local name units
    for name in "${SELECTED[@]}"; do
        units=${UNITS[$name]}
        if [ -n "$units" ]; then
            # shellcheck disable=SC2086
            if ! run_host systemctl restart $units; then
                warn "unit restart failed for $name: $units"
            fi
        fi
        if [ -f "$HOST_ROOT/etc/systemd/system/$name-activation.service" ]; then
            run_host systemctl enable "$name-activation.service" >/dev/null 2>&1 \
                || warn "cannot enable $name-activation.service"
            run_host systemctl restart "$name-activation.service" >/dev/null 2>&1 \
                || warn "cannot restart $name-activation.service"
        fi
    done
}

note_release() {
    PREVIOUS_DIGEST=
    if [ -f "$STATE_DIR/release-digest" ]; then
        PREVIOUS_DIGEST=$(cat "$STATE_DIR/release-digest")
    fi
    if [ -n "$PREVIOUS_DIGEST" ] && [ "$PREVIOUS_DIGEST" != "$SUMS_SHA" ]; then
        warn "this node ran release $PREVIOUS_DIGEST and now runs $SUMS_SHA"
    fi
    printf '%s\n' "$SUMS_SHA" >"$STATE_DIR/release-digest" \
        || die "cannot record the release digest"
}

collect_garbage() {
    local dir
    for dir in "$STATE_DIR"/cache/*; do
        [ -d "$dir" ] || continue
        case $(basename "$dir") in
            "$SUMS_SHA" | "$PREVIOUS_DIGEST") continue ;;
        esac
        rm -rf -- "$dir"
    done
}

main() {
    trap cleanup EXIT
    validate_config
    prepare_state
    verify_inventory
    parse_inventory
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
    deploy
    activate
    note_release
    collect_garbage
    log "done: ${#SELECTED[@]} extension(s) selected"
}

main "$@"
