#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: Apache-2.0
# Contract tests for the agent charts' activate-sci-sysext scripts.
#
# Stdlib only: build a signed release and a fake host in a temporary
# directory, run the script against them, assert the host state and the
# systemctl calls it made.
#
# Run: uv run ci/test_sci_activation.py
from __future__ import annotations

import hashlib
import http.server
import os
import shutil
import subprocess
import tempfile
import textwrap
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHART = os.environ.get("SCI_TEST_CHART", "nova-hypervisor-agents")
SCRIPT = ROOT / "openstack" / CHART / "files/activate-sci-sysext.sh"

EXTENSIONS = ["sci-10-base", "sci-20-compute", "sci-21-network", "sci-22-storage"]
UNITS = {
    "sci-10-base": "",
    "sci-20-compute": "libvirtd.service",
    "sci-21-network": "openvswitch-switch.service ovsdb-server.service",
    "sci-22-storage": "multipathd.service",
}


def manifest(extensions=EXTENSIONS) -> str:
    lines = ["# SCI extension delivery manifest: <name> <restart-units...>", "TARGET_BASE=2150"]
    for name in extensions:
        lines.append(name if not UNITS[name] else f"{name} {UNITS[name]}")
    return "\n".join(lines) + "\n"


def contents(tag: str = "v1") -> dict[str, bytes]:
    out = {}
    for name in EXTENSIONS:
        out[f"{name}.raw"] = f"{name} {tag}\n".encode()
        out[f"{name}-activation.service"] = (
            f"[Unit]\nDescription={name}\n[Service]\nType=oneshot\nRemainAfterExit=yes\n"
            f"ExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n"
        ).encode()
    return out


def run(cmd, **kwargs):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.release = root / "release"
        self.host = root / "host"
        self.bin = root / "bin"
        self.keys = root / "keys"
        self.log = root / "calls.log"
        self.fail_refresh = root / "fail-refresh"
        self.fail_unit = root / "fail-unit"

        for path in (self.release, self.host, self.bin, self.keys):
            path.mkdir(parents=True)

        self.key = self.keys / "signing.key"
        self.cert = self.keys / "signing.crt"
        self.pub = self.keys / "signing.pem"
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", "/CN=sci-activation-test", "-keyout", self.key, "-out", self.cert])
        run(["openssl", "pkey", "-in", self.key, "-pubout", "-out", self.pub])

        (self.host / "etc").mkdir()
        (self.host / "var/lib/extensions").mkdir(parents=True)
        (self.host / "etc/systemd/system").mkdir(parents=True)
        (self.host / "usr/lib/verity.d").mkdir(parents=True)
        (self.host / "etc/os-release").write_text('ID=gardenlinux\nIMAGE_VERSION="2150.9.0"\nVERSION_ID="2150.9.0"\n')
        shutil.copy(self.cert, self.host / "usr/lib/verity.d/verity.crt")

        (self.bin / "systemctl").write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            printf '%s\\n' "systemctl $*" >>"$FAKE_LOG"
            cmd=$1; shift
            if [ "$cmd" = restart ] && [ -f "$FAKE_FAIL_UNIT" ] && [ "$1" = libvirtd.service ]; then
                exit 1
            fi
            if [ "$cmd" = enable ]; then
                unit=$1
                wants=$FAKE_HOST_ROOT/etc/systemd/system/multi-user.target.wants
                mkdir -p "$wants"
                ln -sfn "/etc/systemd/system/$unit" "$wants/$unit"
            fi
            exit 0
        """))
        (self.bin / "systemd-sysext").write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            printf '%s\\n' "systemd-sysext $*" >>"$FAKE_LOG"
            [ -f "$FAKE_FAIL_REFRESH" ] && exit 1
            exit 0
        """))
        for name in ("systemctl", "systemd-sysext"):
            (self.bin / name).chmod(0o755)

        self.build_release(contents())

    def build_release(self, files: dict[str, bytes], sign_with: Path | None = None) -> None:
        for stale in self.release.iterdir():
            stale.unlink()
        for name, data in files.items():
            (self.release / name).write_bytes(data)
        shutil.copy(self.cert, self.release / "verity-run.crt")
        (self.release / "extensions.manifest").write_text(manifest())

        listed = sorted(files) + ["extensions.manifest", "verity-run.crt"]
        lines = []
        for name in listed:
            digest = hashlib.sha256((self.release / name).read_bytes()).hexdigest()
            lines.append(f"{digest}  {name}")
        (self.release / "SHA256SUMS").write_text("\n".join(lines) + "\n")
        run(["openssl", "dgst", "-sha256", "-sign", str(sign_with or self.key),
             "-out", str(self.release / "SHA256SUMS.sig"),
             str(self.release / "SHA256SUMS")])

    def env(self, extensions="sci-10-base sci-20-compute", **overrides) -> dict[str, str]:
        env = dict(os.environ)
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "HOST_ROOT": str(self.host),
            "SCI_RELEASE_URL": self.release.as_uri(),
            "SCI_PUBKEY_FILE": str(self.pub),
            "SCI_EXTENSIONS": extensions,
            "SCI_NSENTER": "0",
            "SCI_AGENT": "test-agent",
            "FAKE_LOG": str(self.log),
            "FAKE_HOST_ROOT": str(self.host),
            "FAKE_FAIL_REFRESH": str(self.fail_refresh),
            "FAKE_FAIL_UNIT": str(self.fail_unit),
        })
        env.pop("SCI_STATE_DIR", None)
        env.update(overrides)
        return env

    def run_consumer(self, **overrides):
        return subprocess.run(["bash", str(SCRIPT)], env=self.env(**overrides),
                              capture_output=True, text=True, timeout=30)

    def calls(self) -> str:
        return self.log.read_text() if self.log.exists() else ""

    def reset_log(self) -> None:
        self.log.write_text("")

    def deployed(self) -> list[str]:
        return sorted(p.name for p in (self.host / "var/lib/extensions").glob("*.raw"))

    def raw(self, name: str) -> bytes:
        return (self.host / "var/lib/extensions" / f"{name}.raw").read_bytes()

    def release_digest(self) -> str:
        return hashlib.sha256((self.release / "SHA256SUMS").read_bytes()).hexdigest()

    def cached_generations(self) -> list[str]:
        cache = self.host / "var/lib/sci-sysext/cache"
        return sorted(p.name for p in cache.iterdir() if p.is_dir())


class ConsumerTest(unittest.TestCase):
    def setUp(self):
        state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "helm-chart-tests"
        state.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="sci-activation-", dir=state))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.fx = Fixture(self.tmp)

    def test_deploys_only_the_selected_extensions(self):
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fx.deployed(), ["sci-10-base.raw", "sci-20-compute.raw"])

    def test_restarts_only_units_of_selected_extensions(self):
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.fx.calls()
        self.assertIn("systemctl restart libvirtd.service", calls)
        self.assertNotIn("openvswitch-switch.service", calls)
        self.assertNotIn("multipathd.service", calls)

    def test_enables_the_activation_shim(self):
        self.assertEqual(self.fx.run_consumer().returncode, 0)
        wants = self.fx.host / "etc/systemd/system/multi-user.target.wants"
        self.assertTrue((wants / "sci-10-base-activation.service").is_symlink())
        self.assertFalse((wants / "sci-21-network-activation.service").is_symlink())

    def test_converged_second_pass_makes_no_call(self):
        self.assertEqual(self.fx.run_consumer().returncode, 0)
        self.fx.reset_log()
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fx.calls(), "")
        self.assertNotIn("downloaded", result.stdout)

    def test_unknown_extension_is_refused_before_any_write(self):
        result = self.fx.run_consumer(extensions="sci-10-base sci-99-unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not deploy", result.stderr)
        self.assertEqual(self.fx.deployed(), [])

    def test_wrong_sums_digest_is_refused(self):
        result = self.fx.run_consumer(SCI_SUMS_DIGEST="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("digest mismatch", result.stderr)
        self.assertEqual(self.fx.deployed(), [])

    def test_signature_from_another_key_is_refused(self):
        other_key = self.fx.keys / "other.key"
        run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
             "-out", other_key])
        self.fx.build_release(contents(), sign_with=other_key)
        result = self.fx.run_consumer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not verify", result.stderr)
        self.assertEqual(self.fx.deployed(), [])

    def test_tampered_raw_is_refused(self):
        raw = self.fx.release / "sci-20-compute.raw"
        raw.write_bytes(b"tampered\n")
        result = self.fx.run_consumer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match its SHA256SUMS line", result.stderr)
        self.assertEqual(self.fx.deployed(), [])

    def test_missing_anchor_is_refused(self):
        (self.fx.host / "usr/lib/verity.d/verity.crt").unlink()
        result = self.fx.run_consumer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no certificate", result.stderr)
        self.assertEqual(self.fx.deployed(), [])

    def test_wrong_base_line_is_refused(self):
        (self.fx.host / "etc/os-release").write_text('ID=gardenlinux\nIMAGE_VERSION="1900.0.0"\nVERSION_ID="1900.0.0"\n')
        result = self.fx.run_consumer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release targets 2150", result.stderr)
        self.assertEqual(self.fx.deployed(), [])

    def test_unsupported_url_scheme_is_refused(self):
        result = self.fx.run_consumer(SCI_RELEASE_URL="ftp://example.invalid/sci")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must start with", result.stderr)

    def test_two_consumers_share_the_cache_and_do_not_remove(self):
        self.assertEqual(self.fx.run_consumer(extensions="sci-10-base sci-20-compute").returncode, 0)
        result = self.fx.run_consumer(extensions="sci-10-base sci-21-network")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fx.deployed(), [
            "sci-10-base.raw", "sci-20-compute.raw", "sci-21-network.raw",
        ])

    def test_failed_merge_restores_the_previous_raw(self):
        self.assertEqual(self.fx.run_consumer().returncode, 0)
        before = self.fx.raw("sci-10-base")

        self.fx.build_release(contents("v2"))
        self.fx.fail_refresh.touch()
        result = self.fx.run_consumer()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refresh", result.stderr)
        self.assertEqual(self.fx.raw("sci-10-base"), before)

    def test_does_not_collect_another_agents_cached_release(self):
        digests = []
        for tag in ("v1", "v2", "v3"):
            self.fx.build_release(contents(tag))
            digests.append(self.fx.release_digest())
            self.assertEqual(self.fx.run_consumer().returncode, 0)
        self.assertEqual(self.fx.cached_generations(), sorted(digests))

    def test_only_changed_raws_restart_their_units(self):
        self.assertEqual(self.fx.run_consumer().returncode, 0)
        self.fx.reset_log()
        files = contents()
        files["sci-10-base.raw"] = b"updated-base\n"
        self.fx.build_release(files)
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("systemctl restart libvirtd.service", self.fx.calls())

    def test_extensions_without_a_shim_converge(self):
        files = {name: data for name, data in contents().items() if name.endswith(".raw")}
        self.fx.build_release(files)
        self.assertEqual(self.fx.run_consumer().returncode, 0)
        self.fx.reset_log()
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fx.calls(), "")

    def test_required_unit_failure_blocks_the_agent_and_is_retried(self):
        self.fx.fail_unit.touch()
        result = self.fx.run_consumer()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.fx.fail_unit.unlink()
        self.fx.reset_log()
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl restart libvirtd.service", self.fx.calls())

    def test_base_gate_uses_the_machine_image_version(self):
        (self.fx.host / "etc/os-release").write_text('ID=gardenlinux\nVERSION_ID="13"\nIMAGE_VERSION="2150.9.0"\n')
        result = self.fx.run_consumer()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_activation_lives_in_each_chart_not_a_separate_component(self):
        self.assertFalse((ROOT / "openstack/sci-consumer").exists())
        nova = ROOT / "openstack/nova-hypervisor-agents/files/activate-sci-sysext.sh"
        neutron = ROOT / "openstack/neutron-hypervisor-agents/files/activate-sci-sysext.sh"
        self.assertEqual(nova.read_bytes(), neutron.read_bytes())

    def test_agents_download_concurrently_and_activate_a_safe_union(self):
        fixture = self.fx
        barrier = threading.Barrier(2)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.rsplit("/", 1)[-1]
                if name in ("sci-20-compute.raw", "sci-21-network.raw"):
                    try:
                        barrier.wait(timeout=10)
                    except threading.BrokenBarrierError:
                        self.send_error(503, "agent downloads were serialized")
                        return
                data = (fixture.release / name).read_bytes()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}"
        processes = []
        for agent, extensions in (("compute", "sci-10-base sci-20-compute"),
                                  ("network", "sci-10-base sci-21-network")):
            process = subprocess.Popen(
                ["bash", str(SCRIPT)],
                env=self.fx.env(extensions=extensions, SCI_AGENT=agent, SCI_RELEASE_URL=url),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            processes.append(process)
            self.addCleanup(lambda p=process: p.kill() if p.poll() is None else None)
        for process in processes:
            _, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(self.fx.deployed(), ["sci-10-base.raw", "sci-20-compute.raw", "sci-21-network.raw"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
