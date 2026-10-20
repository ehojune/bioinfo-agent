#!/usr/bin/env python3
"""Hermetic contract tests: no pipeline, container, data download, or live asset edits."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch as mock_patch

HERE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


meta = module("run_meta", "run-meta.py")
repair = module("pipeline_patch", "apply-pipeline-patch.py")


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="run-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, content in {"samplesheet.csv": "sample,fastq_1\nsynthetic,fixture.fastq.gz\n",
                              "params.json": "{}\n", "cmd.sh": "# synthetic command\n",
                              "approval.md": "Synthetic fixture approval; no run executed.\n"}.items():
            (self.root / name).write_text(content)
        self.args = argparse.Namespace(
            run_dir=self.root, pipeline="nf-core/rnaseq", revision="3.18.0",
            engine_version=None, samplesheet="samplesheet.csv", params="params.json",
            command="cmd.sh", approval="approval.md")
        self.record = meta.init(self.args)

    def test_init_has_no_invented_success_or_measurements(self):
        self.assertEqual(self.record["execution"]["status"], "unknown")
        self.assertEqual(self.record["qc"]["verdict"], "NOT_ASSESSED")
        self.assertIsNone(self.record["resources"]["observed"]["wall_seconds"])
        meta.validate(self.record, self.root)

    def test_validation_does_not_modify_evidence(self):
        def snapshot():
            return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in self.root.iterdir() if p.is_file()}
        before = snapshot()
        meta.validate(self.record, self.root)
        self.assertEqual(snapshot(), before)

    def test_tampered_evidence_rejected(self):
        (self.root / "params.json").write_text('{"changed": true}')
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            meta.validate(self.record, self.root)

    def test_missing_evidence_rejected(self):
        (self.root / "cmd.sh").unlink()
        with self.assertRaises(OSError):
            meta.validate(self.record, self.root)

    def test_types_fields_and_bounds_fail_closed(self):
        edits = [
            lambda r: r.update(schema_version=True),
            lambda r: r.update(cleanup_authorized=True),
            lambda r: r["pipeline"].update(revision=""),
            lambda r: r["resources"]["observed"].update(work_peak_bytes=-1),
            lambda r: r["resources"]["observed"].update(memory_peak_bytes=1.5),
            lambda r: r["resources"]["observed"].update(wall_seconds=float("inf")),
            lambda r: r.update(created_at="2026-10-20T00:00:00"),
            lambda r: r["inputs"]["params"].update(sha256="invalid"),
        ]
        for edit in edits:
            record = copy.deepcopy(self.record)
            edit(record)
            with self.subTest(record=record), self.assertRaises(ValueError):
                meta.validate(record)

    def test_terminal_state_requires_matching_exit_and_evidence(self):
        for state, code in [("succeeded", None), ("failed", 0), ("cancelled", None),
                            ("unknown", 0), ("running", None)]:
            record = copy.deepcopy(self.record)
            record["execution"].update(status=state, exit_code=code)
            with self.subTest(state=state), self.assertRaises(ValueError):
                meta.validate(record)
        self.record["execution"].update(status="succeeded", exit_code=0,
                                        evidence=[self.record["inputs"]["command"]])
        meta.validate(self.record, self.root)
        # Successful execution does not imply QC PASS.
        self.assertEqual(self.record["qc"]["verdict"], "NOT_ASSESSED")

    def test_qc_verdict_requires_evidence(self):
        self.record["qc"]["verdict"] = "PASS"
        with self.assertRaisesRegex(ValueError, "QC verdict requires evidence"):
            meta.validate(self.record)

    def test_resource_metrics_require_evidence(self):
        self.record["resources"]["observed"]["wall_seconds"] = 1.25
        with self.assertRaisesRegex(ValueError, "measurements require evidence"):
            meta.validate(self.record)
        self.record["resources"]["evidence"] = [self.record["inputs"]["command"]]
        meta.validate(self.record, self.root)

    def test_paths_cannot_escape_or_use_windows_aliases(self):
        for path in ["../secret", "/tmp/secret", "a/../../secret", "C:/secret",
                     r"folder\secret", "nested/./file", "bad\nfile"]:
            record = copy.deepcopy(self.record)
            record["inputs"]["command"]["path"] = path
            with self.subTest(path=path), self.assertRaises(ValueError):
                meta.validate(record)

    def test_anchored_fields_reject_trailing_newline_without_file_checks(self):
        for field in ("run_id", "sha256"):
            record = copy.deepcopy(self.record)
            if field == "run_id":
                record["run_id"] += "\n"
            else:
                record["inputs"]["command"]["sha256"] += "\n"
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "invalid format"):
                meta.validate(record)

    def test_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "private"
            target.write_text("not part of the run")
            try:
                (self.root / "escape").symlink_to(target)
            except OSError:
                self.skipTest("symlink creation unavailable")
            with self.assertRaisesRegex(ValueError, "inside the run"):
                meta.artifact(self.root, "escape")

    def test_duplicate_keys_and_nonfinite_json_rejected(self):
        file = self.root / "bad.json"
        for text in ['{"status": "unknown", "status": "succeeded"}', '{"n": NaN}', '{"n": Infinity}']:
            file.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                meta.load_json(file)

    def test_unsupported_schema_feature_rejected(self):
        with self.assertRaisesRegex(ValueError, "unsupported schema"):
            meta.check_schema({}, {"dependentRequired": {}}, {})

    def test_cli_round_trip(self):
        output = subprocess.check_output([
            "python3", str(HERE / "run-meta.py"), "init", str(self.root),
            "--pipeline", "nf-core/rnaseq", "--revision", "3.18.0",
            "--samplesheet", "samplesheet.csv", "--params", "params.json",
            "--command", "cmd.sh", "--approval", "approval.md"], text=True)
        target = self.root / "run-meta.json"
        target.write_text(output)
        result = subprocess.check_output([
            "python3", str(HERE / "run-meta.py"), "validate", str(target), "--check-files"], text=True)
        self.assertEqual(json.loads(result), {"valid": True, "checked_files": True})


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pipeline-patch-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = json.loads(repair.MANIFEST.read_text())
        self.target = self.root / self.manifest["path"]
        self.target.parent.mkdir(parents=True)
        shutil.copyfile(HERE / "fixtures/cutandrun-3.2.2/main.nf", self.target)
        # Revision interrogation only is mocked; full upstream bytes and file writes are real.
        self.git = mock_patch.object(repair.subprocess, "check_output",
                                     return_value=self.manifest["revision"] + "\n")
        self.git.start()
        self.addCleanup(self.git.stop)

    def test_check_is_read_only_and_apply_is_idempotent(self):
        before = self.target.read_bytes()
        self.assertEqual(repair.patch(self.root, self.manifest), "applicable")
        self.assertEqual(before, self.target.read_bytes())
        self.assertEqual(repair.patch(self.root, self.manifest, True), "applied")
        self.assertEqual(repair.digest(self.target.read_bytes()), self.manifest["after_sha256"])
        self.assertEqual(repair.patch(self.root, self.manifest, True), "already-applied")

    def test_wrong_revision_rejected_even_for_exact_preimage(self):
        with mock_patch.object(repair.subprocess, "check_output", return_value="wrong\n"):
            with self.assertRaisesRegex(ValueError, "pinned"):
                repair.patch(self.root, self.manifest, True)
        self.assertEqual(repair.digest(self.target.read_bytes()), self.manifest["before_sha256"])

    def test_unknown_or_partial_preimage_preserved(self):
        for replacement in [b"\n// other local edit\n",
                            self.target.read_bytes().replace(b" optional true", b", optional: true", 1)]:
            self.target.write_bytes(replacement)
            with self.assertRaisesRegex(ValueError, "preimage"):
                repair.patch(self.root, self.manifest, True)
            self.assertEqual(self.target.read_bytes(), replacement)

    def test_symlink_target_rejected(self):
        other = self.root / "other.nf"
        self.target.rename(other)
        try:
            self.target.symlink_to(other)
        except OSError:
            self.skipTest("symlink creation unavailable")
        with self.assertRaisesRegex(ValueError, "symlink"):
            repair.patch(self.root, self.manifest, True)


@unittest.skipUnless(shutil.which("tmux"), "tmux required for detached lifecycle tests")
class StubTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stub-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "run with spaces"
        self.run.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "nextflow"
        fake.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\nsleep \"${BIOINFO_TEST_SLEEP:-0.15}\"\nexit \"${BIOINFO_TEST_EXIT:-0}\"\n")
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        socket_dir = self.root / "tmux"
        socket_dir.mkdir()
        self.env["TMUX_TMPDIR"] = str(socket_dir)
        self.env.pop("TMUX", None)
        self.addCleanup(lambda: subprocess.run(
            ["tmux", "kill-server"], env=self.env, capture_output=True))
        self.helper = HERE / "stub-gate.sh"

    def call(self, *args):
        return subprocess.run(["bash", str(self.helper), *map(str, args)],
                              env=self.env, text=True, capture_output=True)

    def wait_state(self, label):
        target = self.run / ".stub-gates" / label / "state"
        for _ in range(100):
            if target.exists() and not (self.run / ".stub-gates/active").exists():
                return target.read_text().strip()
            time.sleep(.05)
        self.fail("detached fixture did not finish")

    def test_detached_pass_preserves_argv_and_full_samplesheet(self):
        sheet = "full samplesheet;$(must-not-execute).csv"
        result = self.call("launch", self.run, "auto", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run", "--input", sheet)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.wait_state("auto"), "PASS")
        gate = self.run / ".stub-gates/auto"
        argv = (gate / "console.log").read_text().splitlines()
        self.assertIn(sheet, argv)
        self.assertIn("-stub-run", argv)
        self.assertEqual(self.call("status", self.run, "auto").stdout.strip(), "PASS")
        self.assertFalse((self.run / "must-not-execute").exists())
        self.assertEqual(self.call("launch", self.run, "auto", "--", "nextflow", "run",
                                   "nf-core/rnaseq", "-stub-run").returncode, 2)

    def test_interrupt_is_not_pass_or_stub_waiver(self):
        for code, expected in [(129, "INTERRUPTED"), (1, "FAILED")]:
            self.env["BIOINFO_TEST_EXIT"] = str(code)
            label = f"code-{code}"
            result = self.call("launch", self.run, label, "--", "nextflow", "run",
                               "nf-core/rnaseq", "-stub-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.wait_state(label), expected)

    def test_invalid_launch_does_not_create_gate(self):
        for args in [("nextflow", "run", "nf-core/rnaseq"),
                     ("bash", "-c", "nextflow run nf-core/rnaseq -stub-run"),
                     ("nextflow", "run", "nf-core/rnaseq", "-stub-run", "-log", "other"),
                     ("nextflow", "run", "nf-core/rnaseq", "-stub-run", "-preview"),
                     ("nextflow", "run", "nf-core/rnaseq", "-stub-run", "--help"),
                     ("nextflow", "run", "nf-core/rnaseq", "-stub-run", "false")]:
            result = self.call("launch", self.run, "invalid", "--", *args)
            self.assertEqual(result.returncode, 2)
            self.assertFalse((self.run / ".stub-gates/invalid").exists())
        self.assertEqual(self.call("status", self.run, "absent").stdout.strip(), "UNKNOWN")

    def test_concurrent_launch_refused(self):
        self.env["BIOINFO_TEST_SLEEP"] = "0.7"
        result = self.call("launch", self.run, "first", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.call("launch", self.run, "second", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run")
        self.assertEqual(result.returncode, 2)
        self.assertIn("another gate", result.stderr)
        self.assertFalse((self.run / ".stub-gates/second").exists())
        self.assertEqual(self.wait_state("first"), "PASS")

    def test_launcher_termination_does_not_release_runner_lock(self):
        self.env["BIOINFO_TEST_SLEEP"] = "1.2"
        real_tmux = shutil.which("tmux")
        wrapper = self.bin / "tmux"
        wrapper.write_text(
            f"#!/usr/bin/env bash\n{real_tmux} \"$@\"\nrc=$?\n"
            'if [[ $1 == new-session && $rc == 0 ]]; then kill -TERM "$PPID"; fi\nexit "$rc"\n')
        wrapper.chmod(0o755)
        result = self.call("launch", self.run, "interrupted-launcher", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run")
        wrapper.unlink()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.run / ".stub-gates/active/owner").exists())
        result = self.call("launch", self.run, "second", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.wait_state("interrupted-launcher"), "PASS")

    def test_runner_never_releases_a_different_lock_owner(self):
        self.env["BIOINFO_TEST_SLEEP"] = "0.5"
        result = self.call("launch", self.run, "owner-check", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        owner = self.run / ".stub-gates/active/owner"
        owner.write_text("different-owner\n")
        state = self.run / ".stub-gates/owner-check/state"
        for _ in range(100):
            if state.exists():
                break
            time.sleep(.05)
        self.assertTrue(state.exists())
        time.sleep(.05)
        self.assertEqual(owner.read_text(), "different-owner\n")

    def test_runner_signal_during_child_handoff_reaps_child_before_unlock(self):
        # Force the previously unhandled spawn/PID-assignment window, then the
        # known-PID/pre-readiness window. The injected signal uses only a builtin
        # so $! still refers to the actual child.
        real_tmux = shutil.which("tmux")
        (self.bin / "nextflow").write_text("#!/usr/bin/env bash\nexec sleep 5\n")
        for label, target in [
            ("before-pid", "child=$!\n"),
            ("before-ready", 'printf "ready\\n" > "$gate/ready"\n'),
        ]:
            gate = self.run / ".stub-gates" / label
            wrapper = self.bin / "tmux"
            injection = 'printf "%s\\n" "$!" > "$gate/test-child.pid"\nkill -TERM "$$"\n'
            wrapper.write_text(
                "#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\n"
                "if sys.argv[1] == 'new-session':\n"
                f"    p = Path({str(gate / 'runner.sh')!r})\n"
                f"    p.write_text(p.read_text().replace({target!r}, {injection + target!r}, 1))\n"
                f"os.execv({real_tmux!r}, [{real_tmux!r}] + sys.argv[1:])\n")
            wrapper.chmod(0o755)
            result = self.call("launch", self.run, label, "--", "nextflow", "run",
                               "nf-core/rnaseq", "-stub-run")
            wrapper.unlink()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(self.wait_state(label), "INTERRUPTED")
            self.assertFalse((gate / "ready").exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int((gate / "test-child.pid").read_text()), 0)

    def test_stale_server_contract_is_unset_only_in_new_session(self):
        server_env = dict(self.env, NXF_OFFLINE="true", NXF_WORKROOT="/stale/root",
                          BIOINFO_MAX_MEMORY="999 GB")
        subprocess.run(["tmux", "new-session", "-d", "-s", "keepalive", "sleep 20"],
                       env=server_env, check=True)
        for key in ("NXF_OFFLINE", "NXF_WORKROOT", "BIOINFO_MAX_MEMORY"):
            self.env.pop(key, None)
        self.env["SSL_CERT_FILE"] = "/current/ca.pem"
        (self.bin / "nextflow").write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"${NXF_OFFLINE-unset}\" \"${NXF_WORKROOT-unset}\" "
            "\"${BIOINFO_MAX_MEMORY-unset}\" \"${SSL_CERT_FILE-unset}\"\n")
        result = self.call("launch", self.run, "fresh-env", "--", "nextflow", "run",
                           "nf-core/rnaseq", "-stub-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.wait_state("fresh-env"), "PASS")
        self.assertEqual((self.run / ".stub-gates/fresh-env/console.log").read_text(),
                         "unset\nunset\nunset\n/current/ca.pem\n")
        # Existing server/session policy is not changed by starting this gate.
        original = subprocess.check_output(
            ["tmux", "show-environment", "-g", "NXF_OFFLINE"], env=self.env, text=True)
        self.assertEqual(original.strip(), "NXF_OFFLINE=true")


if __name__ == "__main__":
    unittest.main(verbosity=2)
