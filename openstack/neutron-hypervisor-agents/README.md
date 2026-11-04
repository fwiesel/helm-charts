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

## SCI sysext activation per agent

The host OVS stack comes from a signed SCI release published by
`gardenlinux/gardenlinux-sci`. This chart consumes that release; it does not
build or publish sysext artifacts.

`sciSysext` controls how the stack is provisioned:

* release and public key empty (default) — trust mode: the host provides the
  stack natively and the chart renders no activation container;
* release and public key set — an `activate-sci-sysext` init container runs one
  pass at Pod start: it verifies the release, deploys the extensions listed in
  `extensions`, merges them on the host, and restarts the units those
  extensions own. An already converged host is a no-op verify.

A partially set release configuration fails the render. Both `ovn-controller`
and `openvswitch-agent` run the script from this chart's `bin` ConfigMap, in
their existing `loci-neutron` image. There is no separate consumer image or
DaemonSet. The script is `files/activate-sci-sysext.sh`; it does not execute
upstream's pipeline test script.

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

The signed manifest supplies restart-unit names. The chart supplies the
extension selection. Only changed raws trigger their unit restarts; a failed
required restart blocks the agent and is retried at the next init. Downloads
can run concurrently, while the node-global merge is protected by a host lock.
Verified files are cached under `/var/lib/sci-sysext/cache/<sums-digest>`, and
retry markers are per agent. This chart removes neither deployed extensions
nor another agent's cache. The script compares the host's verity trust anchors
with the release certificate and warns on a mismatch; it never changes host
trust, and systemd-sysext remains the enforcement point at merge.

Roll out release changes only in a maintenance window, not during a running
workload test. Unit tests use signed fixtures and stub host commands. Live
verity, NFS and dataplane checks still require a real deployment.
