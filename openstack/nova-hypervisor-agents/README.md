# Nova hypervisor agents

## SCI sysext activation per agent

The compute DaemonSet runs an `activate-sci-sysext` init container after
`kubernetes-entrypoint` and before `nova-compute-init` and `setup-nfs`.
It uses the existing agent image and executes `files/activate-sci-sysext.sh`
from this chart's `bin` ConfigMap. It does not start libvirt in a container.

Set `sciSysext.release.url`, `sciSysext.release.sumsDigest` and
`sciSysext.publicKey` together. Leaving all three empty trusts the host and
adds no activation container or script to the rendered resources. A partial
configuration fails the render. Legacy `sciSysext.image` values fail with a
migration message: there is no standalone consumer image.

The chart's default selection is base, compute, storage, libvirt, virt-ch and
virt-qemu. Garden Linux SCI publishes one full release; selection and
activation belong to this agent. `delivery/sci-delivery.sh` from the producer
repository is a pipeline test fixture, not a dependency.

The agent verifies the inventory signature and pinned digest, checks selected
files against the signed inventory, and checks the host base and trust anchor
before changing extension files. The signed manifest supplies restart units.
Only changed raws restart those units; failures block the agent and retain a
per-agent retry marker. Host commands run in the host mount namespace and
root directory. Downloads stay concurrent; a host lock protects the node-wide
merge and activation. The cache is shared, but extensions and cache entries
are not automatically removed.

Provision the verity trust anchor separately. Change the release only in a
maintenance window, between Ralph runs. Instance NFS initialization remains
enabled whenever `instance_nfs_share` is set, independently of SCI activation.

`helm unittest` covers the rendered init order, privileges, script packaging
and inputs. `ci/test_sci_activation.py` tests both charts' identical activation
logic against signed fixtures and stub host commands. These checks do not
prove a live verity merge or preserve a running dataplane; deployment tests
remain necessary.
