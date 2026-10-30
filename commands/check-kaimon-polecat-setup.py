"""Exercise setup on real linked worktrees, with a controlled prepare result."""
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout, redirect_stderr

SCRIPT = Path(__file__).with_name("kaimon-polecat-setup")
loader = importlib.machinery.SourceFileLoader("polecat_setup", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
setup = importlib.util.module_from_spec(spec)
loader.exec_module(setup)


class Setup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.worktree = self.root / ".gc/task/worktree"
        self.run_git(self.repo, "init", "-q")
        (self.repo / "Project.toml").write_text('[deps]\n')
        self.run_git(self.repo, "add", ".")
        self.run_git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "-qm", "fixture")
        self.run_git(self.repo, "worktree", "add", "--detach", str(self.worktree), "HEAD")
        self.profile = {"julia_bin": "/original/julia", "julia_version": "1.13.2",
                        "_file": str(self.root / "candidate/profile.json"),
                        "_directory": str(self.root / "candidate"), "profile_id": "candidate"}
        self.calls = []
        self.real_run = subprocess.run

    @staticmethod
    def run_git(directory, *args):
        return subprocess.check_output(["git", "-C", str(directory), *args], stderr=subprocess.DEVNULL, text=True).strip()

    def prepare_result(self, rejected=False):
        def run(argv, **kwargs):
            if Path(argv[0]).name != "kaimon-sysimage.py":
                return self.real_run(argv, **kwargs)
            self.calls.append(argv)
            if rejected:
                return subprocess.CompletedProcess(argv, 1, "", "incompatible deps\n")
            (self.worktree / "Manifest-v1.13.toml").write_text("# fixture generated lock\n")
            return subprocess.CompletedProcess(argv, 0, "prepared\n", "")
        return run

    def apply(self, rejected=False):
        with patch.object(setup.image, "load_profile", return_value=self.profile), \
             patch.object(setup.image, "runtime", return_value={"version": "1.13.2"}), \
             patch.object(setup.subprocess, "run", side_effect=self.prepare_result(rejected)), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            setup.setup(self.worktree, self.profile["_file"])

    def test_clean_idempotent_setup_and_direct_prepare(self):
        before = (self.worktree / "Project.toml").read_bytes()
        for _ in range(2):
            self.apply()
            self.assertEqual(self.run_git(self.worktree, "status", "--porcelain"), "")
            self.assertEqual((self.worktree / "Project.toml").read_bytes(), before)
        self.assertEqual(len(self.calls), 2)
        for argv in self.calls:
            self.assertTrue(argv[0].endswith("/kaimon-sysimage.py"))
            self.assertEqual(argv[1], "prepare")
            self.assertIn("--preserve-project", argv)
        self.assertEqual(tomllib.loads((self.worktree / "kaimon.toml").read_text())["city_sysimage"]["profile"], self.profile["_file"])
        for filename in ("kaimon.toml", "Manifest-v1.13.toml"):
            self.assertEqual(self.run_git(self.worktree, "check-ignore", filename), filename)

    def test_existing_launch_settings_and_original_binary_survive(self):
        recipe = self.worktree / "kaimon.toml"
        recipe.write_text('# keep comment\n[launch]\njulia_bin = "/caller/julia"\nthreads = "3,1"\nextra_flags = ["--check-bounds=yes"]\n[other]\nvalue = 42')
        self.apply()
        text = recipe.read_text()
        parsed = tomllib.loads(text)
        self.assertIn("# keep comment", text)
        self.assertEqual(parsed["launch"]["threads"], "3,1")
        self.assertEqual(parsed["launch"]["extra_flags"], ["--check-bounds=yes"])
        self.assertEqual(parsed["other"], {"value": 42})
        self.assertEqual(parsed["city_sysimage"]["julia_bin"], "/caller/julia")

    def test_rejected_setup_and_resume_use_normal_julia(self):
        with self.assertRaisesRegex(setup.image.Rejected, "continuing with normal Julia"):
            self.apply(rejected=True)
        self.assertFalse((self.worktree / "kaimon.toml").exists())
        self.apply()
        with self.assertRaises(setup.image.Rejected):
            self.apply(rejected=True)
        parsed = tomllib.loads((self.worktree / "kaimon.toml").read_text())
        self.assertEqual(parsed["city_sysimage"]["mode"], "off")
        self.assertEqual(parsed["city_sysimage"]["julia_bin"], "/original/julia")
        self.assertEqual(self.run_git(self.worktree, "status", "--porcelain"), "")

    def test_tracked_recipe_is_untouched(self):
        recipe = self.worktree / "kaimon.toml"
        recipe.write_text('[launch]\nthreads = "2"\n')
        self.run_git(self.worktree, "add", "kaimon.toml")
        before = recipe.read_bytes()
        with self.assertRaisesRegex(setup.image.Rejected, "tracked"):
            self.apply()
        self.assertEqual(recipe.read_bytes(), before)
        self.assertEqual(self.calls, [])

    def test_main_checkout_and_other_julia_version_are_untouched(self):
        with patch.object(setup.image, "load_profile", return_value=self.profile), self.assertRaisesRegex(setup.image.Rejected, "linked"):
            setup.setup(self.repo)
        recipe = self.worktree / "kaimon.toml"
        recipe.write_text('[launch]\njulia_version = "1.12"\n')
        before = recipe.read_bytes()
        with self.assertRaisesRegex(setup.image.Rejected, "caller Julia"):
            self.apply()
        self.assertEqual(recipe.read_bytes(), before)
        self.assertEqual(self.calls, [])

    def test_main_reports_rejection_without_failing_workspace_setup(self):
        output = io.StringIO()
        with patch.object(setup.sys, "argv", [str(SCRIPT)]), \
             patch.object(setup, "setup", side_effect=setup.image.Rejected("incompatible deps")), redirect_stderr(output):
            self.assertEqual(setup.main(), 0)
        self.assertIn("incompatible deps", output.getvalue())

    def test_explicit_off_and_artifact_are_untouched(self):
        recipe = self.worktree / "kaimon.toml"
        for setting in ('mode = "off"', 'artifact = "/caller/image"'):
            before = '[city_sysimage]\n' + setting + '\n'
            recipe.write_text(before)
            with self.assertRaises(setup.image.Rejected):
                self.apply()
            self.assertEqual(recipe.read_text(), before)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
