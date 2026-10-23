"""Focused compatibility and launch regression tests (no service or Julia needed)."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("sysimage", Path(__file__).with_name("kaimon-sysimage.py"))
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)

UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


class Images(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "editable worktree"
        self.project.mkdir()
        (self.project / "Project.toml").write_text('[deps]\nDependency = "' + UUID + '"\n')
        manifest = ('julia_version = "1.12.7"\nmanifest_format = "2.0"\n'
                    '[[deps.Dependency]]\nuuid = "' + UUID + '"\n'
                    'version = "1.2.3"\ngit-tree-sha1 = "frozen"\n')
        (self.project / "Manifest.toml").write_text(manifest)
        self.info = {"version": "1.12.7", "commit": "commit", "machine": "aarch64-apple-darwin",
                     "binary_sha256": "binary", "base_image_sha256": "base"}
        staging = self.root / "staging"
        staging.mkdir()
        (staging / "dependencies").mkdir()
        (staging / "dependencies/Manifest.toml").write_text(manifest)
        inputs = {"dependencies/Manifest.toml": image.sha(staging / "dependencies/Manifest.toml")}
        self.build_spec = {"runtime": self.info, "platform": [image.sys.platform, image.platform.machine()],
                           "cpu_target": "generic", "inputs": inputs}
        identity = image.hashlib.sha256(image.canonical(self.build_spec)).hexdigest()
        self.artifact = self.root / identity
        staging.rename(self.artifact)
        (self.artifact / "image.dylib").write_bytes(b"image")
        self.meta = {"schema": 1, "id": identity, "spec": self.build_spec, "inputs": inputs,
                     "packages": image.entries(image.read_toml(self.artifact / "dependencies/Manifest.toml")),
                     "image_sha256": image.sha(self.artifact / "image.dylib")}
        self.save()

    def save(self):
        (self.artifact / "metadata.json").write_text(json.dumps(self.meta))

    def validate(self, info=None):
        return image.validate_artifact(self.artifact, info or self.info, self.project)

    def test_compatible_project(self):
        self.assertEqual(self.validate()[0], self.artifact / "image.dylib")

    def test_incompatible_julia_patch_binary_and_base(self):
        for key in ("version", "binary_sha256", "base_image_sha256", "commit"):
            info = dict(self.info, **{key: "different"})
            with self.subTest(key=key), self.assertRaisesRegex(image.Rejected, "incompatible Julia"):
                self.validate(info)

    def test_requested_julia_cannot_silently_substitute(self):
        image.require_runtime(self.info, "1.12")
        image.require_runtime(self.info, "1.12.7")
        with self.assertRaisesRegex(image.Rejected, "requested Julia"):
            image.require_runtime(self.info, "1.13")

    def test_manifest_version_tree_and_path(self):
        manifest = self.project / "Manifest.toml"
        original = manifest.read_text()
        for old, new in [('1.2.3', '1.2.4'), ('frozen', 'newtree'),
                         ('version = "1.2.3"', 'path = "../development"\nversion = "1.2.3"')]:
            manifest.write_text(original.replace(old, new))
            with self.subTest(new=new), self.assertRaises(image.Rejected):
                self.validate()

    def test_editable_package_itself_and_project_override(self):
        project = self.project / "Project.toml"
        for content in [f'name = "Dependency"\nuuid = "{UUID}"\n',
                        '[sources.Dependency]\npath = "../editable"\n']:
            project.write_text(content)
            with self.assertRaises(image.Rejected):
                self.validate()

    def test_checksum_and_stale_input_rejection(self):
        (self.artifact / "image.dylib").write_bytes(b"corrupt")
        with self.assertRaisesRegex(image.Rejected, "checksum"):
            self.validate()
        (self.artifact / "image.dylib").write_bytes(b"image")
        with (self.artifact / "dependencies/Manifest.toml").open("a") as stream:
            stream.write("\n# tampered\n")
        with self.assertRaisesRegex(image.Rejected, "stale/tampered"):
            self.validate()

    def test_stale_identity_and_package_metadata(self):
        self.meta["spec"]["cpu_target"] = "native"
        self.save()
        with self.assertRaisesRegex(image.Rejected, "stale artifact"):
            self.validate()
        self.meta["spec"]["cpu_target"] = "generic"
        self.meta["packages"]["Dependency"]["version"] = "9.0.0"
        self.save()
        with self.assertRaisesRegex(image.Rejected, "provenance"):
            self.validate()

    def test_transitive_and_weak_dependency_graph(self):
        entry = lambda name, **kw: {"uuid": name, "version": "1", "git-tree-sha1": name, **kw}
        manifest = {"deps": {"Root": [entry("root", deps=["Hard"], weakdeps={"Weak": "weak"})],
                             "Hard": [entry("hard")], "Weak": [entry("weak")]}}
        graph = image.external_graph(manifest, ["Root"], {"name": "Editable"})
        self.assertEqual(set(graph), {"Root", "Hard", "Weak"})
        manifest["deps"]["Hard"][0]["path"] = "../editable"
        with self.assertRaisesRegex(image.Rejected, "editable/path"):
            image.external_graph(manifest, ["Root"], {})

    def test_version_specific_manifest(self):
        special = self.project / "Manifest-v1.12.toml"
        special.write_text((self.project / "Manifest.toml").read_text().replace('1.2.3', '9.0.0'))
        with self.assertRaisesRegex(image.Rejected, "version mismatch"):
            self.validate()

    def run_launch(self, mode="auto", compatible=True, extra=()):
        recipe = self.project / "kaimon.toml"
        recipe.write_text('[launch]\nthreads = "2,1"\nextra_flags = ["--check-bounds=yes"]\n'
                          '[city_sysimage]\njulia_bin = "/original/julia"\n'
                          f'mode = "{mode}"\nartifact_root = {json.dumps(str(self.root))}\n')
        before = recipe.read_bytes()
        calls = []
        info = self.info if compatible else dict(self.info, version="1.13.2")
        argv = ["-i", "-t", "2,1", "--check-bounds=yes", f"--project={self.project}",
                *extra, "--startup-file=no", "-e", 'using Gate; state = "$literal"']
        with patch.dict(os.environ, {}, clear=True), patch.object(image, "runtime", return_value=info), \
             patch.object(image, "check_project_compat"):
            code = image.launch(argv, execute=lambda binary, flags: calls.append((binary, flags)))
        self.assertEqual(recipe.read_bytes(), before)
        return code, calls, argv

    def test_preserve_recipe_project_and_flags(self):
        code, calls, argv = self.run_launch()
        self.assertEqual(code, 0)
        self.assertEqual(calls[0][1], ["/original/julia", f"--sysimage={self.artifact / 'image.dylib'}", *argv])

    def test_fallback_and_required(self):
        code, calls, argv = self.run_launch(compatible=False)
        self.assertEqual(calls[0][1], ["/original/julia", *argv])
        code, calls, argv = self.run_launch(mode="required", compatible=False)
        self.assertEqual(code, 78)
        self.assertFalse(calls)

    def test_rollback_and_explicit_image_preserved(self):
        for mode, extra in [("off", ()), ("auto", ("--sysimage=/explicit/image",))]:
            with self.subTest(mode=mode):
                code, calls, argv = self.run_launch(mode=mode, extra=extra)
                self.assertEqual(calls[0][1], ["/original/julia", *argv])

    def test_kaimon_run_tests_without_project_flag(self):
        self.run_launch()
        script = self.root / "kaimon-test-runner.jl"
        script.write_text("# test runner activates its own environment\n")
        argv = ["--startup-file=no", str(script), str(self.project), "", "false"]
        calls = []
        with patch.dict(os.environ, {}, clear=True), patch.object(image, "runtime") as runtime:
            image.launch(argv, execute=lambda binary, flags: calls.append((binary, flags)))
        runtime.assert_not_called()
        self.assertEqual(calls, [("/original/julia", ["/original/julia", *argv])])

    def test_generic_no_project_passthrough(self):
        argv = ["--startup-file=no", "-e", "1 + 1"]
        calls = []
        with patch.dict(os.environ, {"KAIMON_SYSIMAGE_JULIA": "/original/julia"}, clear=True):
            image.launch(argv, execute=lambda binary, flags: calls.append(flags))
        self.assertEqual(calls, [["/original/julia", *argv]])

    def test_extra_union_member_and_bootstrap_overlap(self):
        # The target need not use every package in a shared union image.
        (self.project / "Manifest.toml").write_text('manifest_format = "2.0"\n[deps]\n')
        self.validate()
        gate = self.root / "gate"
        gate.mkdir()
        (gate / "Project.toml").write_text('[deps]\nDependency = "' + UUID + '"\n')
        (gate / "Manifest.toml").write_text((self.artifact / "dependencies/Manifest.toml").read_text())
        image.validate_artifact(self.artifact, self.info, self.project, [gate])
        (gate / "Manifest.toml").write_text((gate / "Manifest.toml").read_text().replace('1.2.3', '1.2.4'))
        with self.assertRaisesRegex(image.Rejected, "bootstrap environment.*version mismatch"):
            image.validate_artifact(self.artifact, self.info, self.project, [gate])


if __name__ == "__main__":
    unittest.main()
