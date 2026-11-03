# sci-consumer

One-shot consumer of a signed SCI systemd-sysext release.

`sci-consumer.sh` runs as a privileged init container in the DaemonSet that
needs the extensions. It fetches one release, verifies it, deploys only the
extensions the DaemonSet asks for, merges them on the host, and restarts the
units those extensions own. Then it exits.

The artifact is published by `gardenlinux/gardenlinux-sci`. This directory is
the consumer side: it does not depend on `delivery/sci-delivery.sh`, which is
that repository's boot-test vehicle.

## Inputs

| Variable | Meaning |
|---|---|
| `SCI_RELEASE_URL` | base URL of one build, for example `https://github.com/gardenlinux/gardenlinux-sci/releases/download/2150.9.0-g00a1df9` |
| `SCI_PUBKEY` / `SCI_PUBKEY_FILE` | PEM public key that verifies `SHA256SUMS.sig` |
| `SCI_SUMS_DIGEST` | optional sha256 of `SHA256SUMS`; turns "trust the tag" into "trust these bytes" |
| `SCI_EXTENSIONS` | space-separated extension names this container deploys |
| `HOST_ROOT` | host root mount point (default `/host`) |
| `SCI_DEADLINE` | wall-clock budget for the whole pass, seconds (default `900`) |
| `SCI_NSENTER` | `1` runs `systemctl`/`systemd-sysext` in the host namespaces, `0` runs them from `PATH` (tests) |
| `SCI_STATE_DIR` | state directory; defaults to `$HOST_ROOT/var/lib/sci-sysext` |

## What it guarantees

* **Nothing is written before the release is proven.** The order is: inventory
  digest, signature, per-file hash, host trust anchor, base line. Each failure
  exits non-zero with the reason and leaves the host untouched.
* **Only the selected names are touched.** A name that the manifest or the
  inventory does not carry is fatal, not ignored.
* **Only the merged units of changed raws restart.** The unit list comes from
  the signed `extensions.manifest`, so the consumer never invents one.
* **Nothing is removed.** Two DaemonSets on one node end at the union of their
  selections; neither deletes the other's raws.
* **A rejected merge is rolled back.** If `systemd-sysext refresh` refuses the
  new set, the previous files are restored and the pass exits non-zero.
* **A converged host costs one inventory download and no `systemctl` call.**

## What it needs from the node

`/usr/lib/verity.d/*.crt` must carry a certificate whose public key matches the
release certificate. `/usr` is read-only, so the consumer cannot install it;
it fails with the exact requirement instead.

## State on the host

```
/var/lib/sci-sysext/
  lock                      flock; serialises concurrent pod starts
  release-digest            the build this node last converged to
  cache/<sums-digest>/      verified files, shared by every consumer
```

The cache is content-addressed by the signed `SHA256SUMS`, so a second pod on
the same node reuses it. One previous generation is kept for rollback and for
the node's other consumers; older ones are collected at the end of a pass.

## Building

```sh
docker build -t <registry>/sci-consumer:<version> openstack/sci-consumer
```

Pin the digest in `sciSysext.image` in both `nova-hypervisor-agents` and
`neutron-hypervisor-agents`.

## Tests

```sh
./tests/test_consumer.py
```

Stdlib only. The suite builds a signed release and a fake host in a temporary
directory, runs the script against them with `systemctl`/`systemd-sysext`
stubs, and asserts the host state and the calls it made.
