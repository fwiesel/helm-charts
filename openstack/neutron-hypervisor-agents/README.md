# Neutron hypervisor agents

## Host OVS provider bridge

With `ovsOnHost: true` the chart consumes an OVS that the host owns (on SCI
workers, `openvswitch-switch.service` from the network sysext). Upstream
bare-metal provisioning creates the provider bridge itself, so the chart only
configures one when `ovs.physicalBridgeTakeover` is true.

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