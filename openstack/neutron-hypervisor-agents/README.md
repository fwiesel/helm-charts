# Neutron hypervisor agents

## Host OVS mode

The chart has a single mode: `ovsOnHost: true`. It consumes an OVS that the
host owns (on SCI workers, `openvswitch-switch.service` from the network
sysext). `ovsOnHost: false` selected the removed containerized OVS sidecars — a
sidecar cannot own the host dataplane — and fails the render with a migration
message.

Upstream bare-metal provisioning creates the provider bridge itself, so the
chart only configures one when `ovs.physicalBridgeTakeover` is true.

On takeover, the `configure-host-ovs` init container of the
`neutron-ovn-controller` DaemonSet runs before `ovn-controller`:

* waits (bounded) for `/var/run/openvswitch/db.sock` (the socket the container
  mounts; it does not mount `/run`) and fails loudly instead of starting an OVS
  daemon;
* creates `ovs.physicalBridge` (`br-ovs0` by default) in the host OVSDB;
* renders the same systemd-networkd drop-ins as `files/start-ovs-vswitchd.py`
  into the host's `/etc/systemd/network`, shadows matching vendor `.network`
  files, attaches `ovs.publicInterface` (auto-detected from the default route
  when empty) to the bridge, and moves the DHCP lease onto it;
* exits 0 when the bridge already owns the address, so Pod restarts and host
  reboots are no-ops.

The container never starts or stops `ovsdb-server`/`ovs-vswitchd`. The Pod
needs `hostPID` so the script can run `networkctl` in the host's namespaces;
it does not need `hostNetwork`.

## SCI sysext delivery

`sciSysext.image` controls how the host OVS stack is provisioned:

* empty (default) — trust mode: the host provides the stack natively and the
  chart adds no delivery container;
* set — a `sci-sysext-delivery` init container runs one pass at Pod start and
  installs or activates the stack; an already converged host is a no-op verify.

The init container mounts the host root at `/host`, runs `privileged: true`, and
adds `SYS_ADMIN`/`SYS_PTRACE` with an unconfined AppArmor profile so it can
enter the host namespaces. Privilege is chart-side on purpose: osl's
post-renderer stamps it only onto the retired standalone `sci-sysext-delivery`
DaemonSet, never onto init containers, and the unprivileged variant failed live
with `Operation not permitted`. It is added to both the `ovn-controller` and
`openvswitch-agent`
DaemonSets. Only the `ovn-controller` Pod gains `hostIPC: true`, which the
dm-verity System V semaphore needs during `systemd-sysext refresh`. Use the
same image digest in `nova-hypervisor-agents`: the two charts share the host
stack, and skewed digests would fight over the merged sysext.
