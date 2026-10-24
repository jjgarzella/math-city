"""Exercise the resolver using native iteration metadata and read-only CLI stubs."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RESOLVER = Path(os.environ.get(
    "PHASE_RESOLVER", Path(__file__).resolve().parents[1] / "lib/resolve-phase-bead.sh"
))
ROOT = {"id": "review-root", "metadata": {"gc.kind": "workflow"}}
PHASE = {
    "id": "analyze-phase",
    "metadata": {
        "gc.kind": "task",
        "gc.step_id": "review-pipeline.analyze",
        "gc.root_bead_id": "review-root",
        "gc.scope_role": "member",
        "gc.scope_ref": "mol-review-loop-standard.review-loop.iteration.2",
        "gc.step_ref": "mol-review-loop-standard.review-loop.iteration.2.review-pipeline.analyze",
        "gc.iteration": "2",
    },
}


class PhaseResolverTest(unittest.TestCase):
    def resolve(self, phase=None, root=None, *, fallback=False,
                expected_root="review-root", expected_step="review-pipeline.analyze",
                suffix="analyze"):
        phase = copy.deepcopy(PHASE if phase is None else phase)
        root = copy.deepcopy(ROOT if root is None else root)
        with tempfile.TemporaryDirectory(prefix="phase-resolver-") as name:
            directory = Path(name)
            (directory / "beads.json").write_text(json.dumps({phase["id"]: phase, root["id"]: root}))
            # Reject any command other than show: resolver validation must not
            # mutate or close a bead, even when metadata resembles a phase.
            (directory / "bd").write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "assert sys.argv[1] == 'show', sys.argv\n"
                "data=json.load(open(os.environ['PHASE_DATA']))\n"
                "print(json.dumps([data[sys.argv[2]]]))\n"
            )
            (directory / "gc").write_text(
                "#!/usr/bin/env bash\n"
                "[ \"$*\" = 'hook current --id-only' ] || exit 99\n"
                "printf '%s\\n' analyze-phase\n"
            )
            for command in ("bd", "gc"):
                (directory / command).chmod(0o755)
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       PHASE_DATA=str(directory / "beads.json"))
            env.pop("GC_BEAD_ID", None)
            if not fallback:
                env["GC_BEAD_ID"] = phase["id"]
            result = subprocess.run(
                ["bash", "-c", '. "$1"; review_phase_resolve "$4" "$2" "$3" || exit $?; '
                 'printf "RESOLVED=%s:%s:%s\\n" "$REVIEW_PHASE_BEAD_ID" '
                 '"$REVIEW_PHASE_ROOT_ID" "$REVIEW_PHASE_STEP_ID"',
                 "resolver-test", str(RESOLVER), expected_root, expected_step, suffix],
                env=env, text=True, capture_output=True,
            )
        return result

    def assert_refused(self, phase=None, root=None, **kwargs):
        result = self.resolve(phase, root, **kwargs)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn("RESOLVED=", result.stdout)

    def test_native_iteration_task(self):
        for suffix in ("analyze", "quality", "synthesis", "apply-fixes", "test"):
            phase = copy.deepcopy(PHASE)
            phase["metadata"]["gc.step_id"] = "review-pipeline." + suffix
            phase["metadata"]["gc.step_ref"] = phase["metadata"]["gc.scope_ref"] + ".review-pipeline." + suffix
            with self.subTest(suffix=suffix):
                result = self.resolve(phase, suffix=suffix, expected_step="review-pipeline." + suffix)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("RESOLVED=analyze-phase:review-root:review-pipeline." + suffix, result.stdout)

    def test_current_claim_fallback(self):
        result = self.resolve(fallback=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_phase_kinds(self):
        for kind in (None, "", "step", "phase"):
            with self.subTest(kind=kind):
                phase = copy.deepcopy(PHASE)
                phase["metadata"] = {"gc.step_id": "review-pipeline.analyze", "gc.root_bead_id": "review-root"}
                if kind is not None:
                    phase["metadata"]["gc.kind"] = kind
                result = self.resolve(phase)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_control_kinds_refused_even_with_phase_identity(self):
        for kind in ("workflow", "scope", "control", "unknown"):
            with self.subTest(kind=kind):
                phase = copy.deepcopy(PHASE)
                phase["metadata"]["gc.kind"] = kind
                self.assert_refused(phase)

    def test_task_requires_all_scope_fields(self):
        for field in ("gc.root_bead_id", "gc.scope_role", "gc.scope_ref", "gc.step_ref"):
            with self.subTest(field=field):
                phase = copy.deepcopy(PHASE)
                del phase["metadata"][field]
                self.assert_refused(phase)

    def test_task_control_or_wrong_scope_identity_refused(self):
        for key, value in (("gc.scope_role", "body"), ("gc.scope_role", "control"),
                           ("gc.step_ref", "other-scope.review-pipeline.analyze"),
                           ("gc.control_for", "logical-task"),
                           ("gc.logical_bead_id", "logical-task"),
                           ("gc.root_bead_id", "analyze-phase")):
            with self.subTest(key=key, value=value):
                phase = copy.deepcopy(PHASE)
                phase["metadata"][key] = value
                self.assert_refused(phase)

    def test_wrong_phase_and_expected_root_refused(self):
        self.assert_refused(expected_root="other-root")
        self.assert_refused(expected_step="other.analyze")
        phase = copy.deepcopy(PHASE)
        phase["metadata"]["gc.step_id"] = "review-pipeline.quality"
        self.assert_refused(phase)

    def test_task_requires_workflow_root(self):
        for kind in (None, "task", "scope", "control"):
            with self.subTest(kind=kind):
                root = copy.deepcopy(ROOT)
                root["metadata"] = {} if kind is None else {"gc.kind": kind}
                self.assert_refused(root=root)


if __name__ == "__main__":
    unittest.main()
