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

## SCI sysext consumer

The host OVS stack comes from a signed SCI release published by
`gardenlinux/gardenlinux-sci`. This chart consumes that release; it does not
build or publish sysext artifacts.

`sciSysext` controls how the stack is provisioned:

* all keys empty (default) — trust mode: the host provides the stack natively
  and the chart renders no consumer container;
* all keys set — a `sci-sysext-consumer` init container runs one pass at Pod
  start: it verifies the release, deploys the extensions listed in
  `extensions`, merges them on the host, and restarts the units those
  extensions own. An already converged host is a no-op verify.

A partially set `sciSysext` block fails the render. `image` is this repo's
consumer image (`openstack/sci-consumer`), not the release.

The network DaemonSets ask for `sci-10-base` and `sci-21-network`, and nothing
else. The full release carries more; the consumer deploys only what
`extensions` names, and it never removes a name another consumer deployed.

The init container mounts the host root at `/host`, runs `privileged: true`, and
adds `SYS_ADMIN`/`SYS_PTRACE` with an unconfined AppArmor profile so it can
enter the host namespaces. Privilege is chart-side on purpose: osl's
post-renderer stamps it only onto the retired standalone `sci-sysext-delivery`
DaemonSet, never onto init containers, and the unprivileged variant failed live
with `Operation not permitted`. It is added to both the `ovn-controller` and
`openvswitch-agent` DaemonSets. Only the `ovn-controller` Pod gains
`hostIPC: true`, which the dm-verity System V semaphore needs during
`systemd-sysext refresh`. Point `nova-hypervisor-agents` at the same release
and `sumsDigest`: the two charts share the host, and a skewed build would make
the shared extensions flap between Pod restarts.
