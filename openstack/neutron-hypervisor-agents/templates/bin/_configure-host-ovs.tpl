#!/usr/bin/env bash

# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

set -eEuo pipefail

# Converge the HOST's OVS onto the provider bridge.
#
# With ovsOnHost=true the OVS daemons belong to the host (SCI sysext starts
# openvswitch-switch.service), so this script only changes OVSDB and
# systemd-networkd state on the host. It never starts or stops ovsdb-server
# or ovs-vswitchd.
#
# The sequence mirrors files/start-ovs-vswitchd.py, which performs the same
# takeover from inside the in-pod ovs-vswitchd sidecar. Hosts that get their
# provider bridge from bare-metal provisioning leave
# OVS_PHYSICAL_BRIDGE_TAKEOVER=false; this script then does nothing.

TAKEOVER="${OVS_PHYSICAL_BRIDGE_TAKEOVER:-false}"
TAKEOVER="${TAKEOVER,,}"
BR="${OVS_PHYSICAL_BRIDGE:-br-ovs0}"
NIC_ENV="${PUBLIC_INTERFACE:-}"
NETDIR=/host/etc/systemd/network
VENDOR_DIR=/host/usr/lib/systemd/network
TEMPLATE_DIR=/usr/local/share/network-templates
PYTHON=/var/lib/openstack/bin/python3
OVS_SOCKET_TIMEOUT="${OVS_SOCKET_TIMEOUT:-120}"
BRIDGE_DHCP_TIMEOUT="${BRIDGE_DHCP_TIMEOUT:-60}"

log() { echo "[configure-host-ovs] $*"; }
die() { echo "[configure-host-ovs] ERROR: $*" >&2; exit 1; }

if [ "$TAKEOVER" != "true" ]; then
    log "OVS_PHYSICAL_BRIDGE_TAKEOVER is not true; the host OVS is provisioned externally, nothing to do"
    exit 0
fi

# The host's systemd-networkd, /sys and interfaces live in PID 1's
# namespaces. Executables are resolved inside the host mount namespace, so
# networkctl and arping do not have to exist in this image.
PID1_MNT="$(readlink /proc/1/ns/mnt 2>/dev/null || true)"
SELF_MNT="$(readlink /proc/self/ns/mnt 2>/dev/null || true)"
[ -n "$PID1_MNT" ] || die "cannot read /proc/1/ns/mnt; the Pod must run with hostPID"
[ "$PID1_MNT" != "$SELF_MNT" ] \
    || die "PID 1 shares this Pod's mount namespace; the Pod must run with hostPID to reach the host's systemd-networkd"
command -v nsenter >/dev/null 2>&1 || die "nsenter not found in this image"
HOST=(nsenter --mount=/proc/1/ns/mnt --net=/proc/1/ns/net --)

host_has_ipv4() {
    "${HOST[@]}" ip -4 -o addr show dev "$1" 2>/dev/null | grep -q 'inet '
}

host_default_dev() {
    "${HOST[@]}" ip -4 route show default 2>/dev/null \
        | awk '$1 == "default" { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

wait_for_bridge_ipv4() {
    local deadline=$((SECONDS + BRIDGE_DHCP_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        host_has_ipv4 "$BR" && return 0
        sleep 1
    done
    return 1
}

# The bridge already owns the address: a previous Pod, a host reboot or a
# migration from container mode got here first. Only recover a missing lease.
converge_existing() {
    if host_has_ipv4 "$BR"; then
        log "$BR already carries an IPv4 address; nothing to do"
        return 0
    fi
    log "$BR has no IPv4 address yet; reconfiguring it via systemd-networkd"
    "${HOST[@]}" networkctl reconfigure "$BR" \
        || die "networkctl reconfigure $BR failed on the host"
    wait_for_bridge_ipv4 \
        || die "$BR did not acquire a DHCPv4 lease within ${BRIDGE_DHCP_TIMEOUT}s"
}

# --- 1. wait for the host OVS ----------------------------------------------
# SCI delivers host OVS asynchronously. Wait with a bounded timeout and fail
# loudly; never start an OVS daemon from here.
OVS=()
wait_for_ovs() {
    local deadline=$((SECONDS + OVS_SOCKET_TIMEOUT)) sock
    while true; do
        for sock in /run/openvswitch/db.sock /var/run/openvswitch/db.sock; do
            if [ -S "$sock" ] && ovs-vsctl --timeout=2 --db="unix:$sock" show >/dev/null 2>&1; then
                OVS=(ovs-vsctl --timeout=10 --db="unix:$sock")
                log "host OVS answered on $sock"
                return 0
            fi
        done
        if [ "$SECONDS" -ge "$deadline" ]; then
            die "no host OVS socket answered within ${OVS_SOCKET_TIMEOUT}s (expected /run/openvswitch/db.sock); is openvswitch-switch.service running?"
        fi
        log "waiting for the host OVS socket on /run/openvswitch/db.sock"
        sleep 2
    done
}
wait_for_ovs

# --- 2. ensure the provider bridge on the host OVS -------------------------
if "${OVS[@]}" br-exists "$BR"; then
    log "bridge $BR already exists in the host OVS"
else
    log "creating bridge $BR in the host OVS"
    "${OVS[@]}" --may-exist add-br "$BR"
fi

# --- 3. decide whether the primary NIC still needs the takeover ------------
DEFAULT_DEV="$(host_default_dev || true)"

if [ -n "$NIC_ENV" ]; then
    NIC="$NIC_ENV"
elif [ -n "$DEFAULT_DEV" ] && [ "$DEFAULT_DEV" = "$BR" ]; then
    log "the host's default route already uses $BR; the takeover is already applied"
    converge_existing
    exit 0
else
    NIC="$DEFAULT_DEV"
fi

[ -n "$NIC" ] || die "no host default IPv4 route; set ovs.publicInterface (PUBLIC_INTERFACE)"
[ "$NIC" != "$BR" ] || die "the public interface resolves to $BR itself; set ovs.publicInterface"

if [ "$("${OVS[@]}" port-to-br "$NIC" 2>/dev/null || true)" = "$BR" ]; then
    log "$NIC is already a port of $BR; the takeover is already applied"
    converge_existing
    exit 0
fi

# --- 4. take the primary NIC over ------------------------------------------
if ! MAC="$("${HOST[@]}" ip -o link show dev "$NIC" \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "link/ether") { print $(i + 1); exit } }')"; then
    die "could not inspect $NIC on the host"
fi
[ -n "$MAC" ] || die "could not read the MAC address of $NIC"

[ -x "$PYTHON" ] || die "$PYTHON not found; expected the OpenStack venv with jinja2"
log "rendering systemd-networkd drop-ins for $NIC and $BR in $NETDIR"
"$PYTHON" - "$TEMPLATE_DIR" "$NETDIR" "$VENDOR_DIR" "$NIC" "$MAC" "$BR" <<'PY'
import configparser
import os
import sys
from fnmatch import fnmatchcase
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

templates, netdir, vendordir, nic, mac, br = sys.argv[1:7]
netdir = Path(netdir)
vendordir = Path(vendordir)

# Same rendering as files/start-ovs-vswitchd.py.
jinja = Environment(loader=FileSystemLoader(templates),
                    undefined=StrictUndefined, keep_trailing_newline=True)
netdir.mkdir(parents=True, exist_ok=True)
(netdir / "10-ovs-uplink.network").write_text(
    jinja.get_template("ovs-uplink.network.j2").render(nic=nic))
(netdir / f"15-{br}.network").write_text(
    jinja.get_template("ovs-bridge.network.j2").render(br=br))


def vendor_matches(vendor_file):
    """Would this /usr/lib .network's [Match] apply to $NIC?"""
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    try:
        cp.read(vendor_file, encoding="utf-8")
    except configparser.Error:
        return False
    match = cp["Match"] if cp.has_section("Match") else {}
    return (mac.lower() in match.get("MACAddress", "").lower().split()
            or any(fnmatchcase(nic, p) for p in match.get("Name", "").split())
            or any("ether" in t for t in match.get("Type", "").split()))


# Shadow vendor .network files that match $NIC by symlinking their basename
# in /etc to /dev/null. Leave admin-authored files alone.
if vendordir.is_dir():
    for vendor in sorted(vendordir.glob("*.network")):
        etc_path = netdir / vendor.name
        if etc_path.exists() and not (etc_path.is_symlink()
                                      and os.readlink(etc_path) == "/dev/null"):
            continue
        if vendor_matches(vendor):
            etc_path.unlink(missing_ok=True)
            etc_path.symlink_to("/dev/null")
PY

# Pin the bridge to $NIC's MAC before add-port so upstream sees no L2 change.
log "pinning $BR to the MAC of $NIC ($MAC)"
"${OVS[@]}" set bridge "$BR" "other-config:hwaddr=$MAC"

# ovs-vswitchd creates the kernel bridge asynchronously after add-br.
for _ in {1..30}; do
    "${HOST[@]}" ip link show dev "$BR" >/dev/null 2>&1 && break
    sleep 1
done
"${HOST[@]}" ip link show dev "$BR" >/dev/null 2>&1 \
    || die "kernel bridge $BR did not appear within 30s; is ovs-vswitchd running on the host?"
"${HOST[@]}" ip link set dev "$BR" address "$MAC"

log "attaching $NIC to $BR"
"${OVS[@]}" --may-exist add-port "$BR" "$NIC"

# Reconfigure $BR before $NIC so systemd-resolved gains the bridge's DNS
# servers before it loses the NIC's; DHCP on $BR then restores the node's
# address, default route and DNS without a userspace gap.
"${HOST[@]}" networkctl reload || die "networkctl reload failed on the host"
"${HOST[@]}" networkctl reconfigure "$BR" \
    || die "networkctl reconfigure $BR failed on the host"
wait_for_bridge_ipv4 \
    || die "$BR did not acquire a DHCPv4 lease within ${BRIDGE_DHCP_TIMEOUT}s"

if ! BR_IP="$("${HOST[@]}" ip -4 -o addr show dev "$BR" \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "inet") { split($(i + 1), a, "/"); print a[1]; exit } }')"; then
    die "could not query the IPv4 address of $BR on the host"
fi
if [ -n "$BR_IP" ]; then
    # Converge upstream CAM tables onto the bridge port.
    "${HOST[@]}" arping -q -c 2 -U -I "$BR" "$BR_IP" \
        || log "warning: gratuitous ARP on $BR failed; continuing"
fi

"${HOST[@]}" networkctl reconfigure "$NIC" \
    || die "networkctl reconfigure $NIC failed on the host"

log "$NIC is bridged onto $BR (address ${BR_IP:-unknown}); the host OVS owns the provider bridge"
