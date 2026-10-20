# Neutron hypervisor agents

## Node-local OVSDB storage

With `ovsOnHost: false`, both the OVN controller and Open vSwitch agent mount
the host directory `/var/lib/openvswitch` into their `ovsdb-server` container.
The `DirectoryOrCreate` hostPath retains `conf.db` across container restarts
and Pod replacement on the same node. Host-managed OVS is unchanged.

The database belongs to the node's OVS instance, not to an individual Pod or
Helm release. Do not share it across nodes or place it on NFS: host networking
must work before network storage can be reached. Helm uninstall does not
delete this host directory. Node replacement does not transfer its contents.

### Upgrading from container-local storage

Adding this mount changes the Pod template and replaces existing Pods. It does
not copy an existing container-local database into the host directory. An empty
host directory hides the old container-local `conf.db` in the replacement Pod.
The startup script's hitless path requires the existing bridge configuration
in OVSDB as well as the surviving kernel bridge.

Do not treat this change as an automatic recovery for nodes whose primary NIC
has already been moved onto OVS. Before rolling out to those nodes, use a
separately reviewed, code-driven database migration or node replacement plan
that preserves required instance storage and provides out-of-band access.
Do not copy a live database file without an OVS-supported consistency procedure.

Validate a fresh deployment and subsequent Pod replacement with NFS mounted,
checking bridge/port configuration, host connectivity, and NFS I/O. Rendering
and unit tests alone do not establish that an existing-node upgrade is safe.