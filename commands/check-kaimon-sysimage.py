"""Focused compatibility and launch regression tests (no service or Julia needed)."""
import importlib.util
import contextlib
import io
import json
import os
import shutil
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
        preferences = dict(image.preference_identity({"Dependency": {"uuid": UUID}}),
                           contexts=[{"empty": True, "nonempty_uuids": []}])
        (staging / "preferences.json").write_text(json.dumps(preferences))
        inputs["preferences.json"] = image.sha(staging / "preferences.json")
        self.build_spec = {"preferences": image.preference_identity({"Dependency": {"uuid": UUID}}),
                           "runtime": self.info, "platform": [image.sys.platform, image.platform.machine()],
                           "cpu_target": "generic", "inputs": inputs}
        identity = image.hashlib.sha256(image.canonical(self.build_spec)).hexdigest()
        self.artifact = self.root / identity
        staging.rename(self.artifact)
        (self.artifact / "image.dylib").write_bytes(b"image")
        self.meta = {"schema": 1, "id": identity, "spec": self.build_spec, "inputs": inputs,
                     "packages": image.entries(image.read_toml(self.artifact / "dependencies/Manifest.toml")),
                     "image_sha256": image.sha(self.artifact / "image.dylib")}
        self.save()
        self.gate = self.root / "actual-gate"
        self.gate.mkdir()
        (self.gate / "Project.toml").write_text(
            'name = "KaimonGate"\nuuid = "' + image.GATE_UUID + '"\nversion = "1.4.0"\n'
            '[deps]\nDependency = "' + UUID + '"\n')
        (self.gate / "Manifest.toml").write_text(manifest)

    def save(self):
        (self.artifact / "metadata.json").write_text(json.dumps(self.meta))

    def validate(self, info=None):
        return image.validate_artifact(self.artifact, info or self.info, self.project)

    def test_legacy_image_requires_rebuild(self):
        del self.meta["spec"]["preferences"]
        identity = image.hashlib.sha256(image.canonical(self.meta["spec"])).hexdigest()
        new_path = self.root / identity
        self.artifact.rename(new_path)
        self.artifact = new_path
        self.meta["id"] = identity
        self.save()
        with self.assertRaisesRegex(image.Rejected, "preference policy"):
            self.validate()

    def test_off_and_explicit_image_ignore_broken_profile(self):
        for extra, mode in [((), "off"), (("--sysimage=/caller/image",), "auto")]:
            self.run_launch(mode=mode, extra=extra)
            calls = []
            with patch.dict(os.environ, {"KAIMON_SYSIMAGE_PROFILE": str(self.root / "absent")}, clear=True), \
                 patch.object(image, "runtime") as probe:
                image.launch([f"--project={self.project}", *extra],
                             execute=lambda binary, flags: calls.append(flags))
            probe.assert_not_called()
            self.assertEqual(len(calls), 1)
            self.assertFalse(any("--sysimage=" in arg and "caller" not in arg for arg in calls[0]))

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

    def test_immutable_git_source_matches_project_manifest_and_image(self):
        revision = "e" * 40
        tree = "a" * 40
        url = "file:///owned/compatibility-fork"
        entry = dict(self.meta["packages"]["Dependency"], **{
            "git-tree-sha1": tree, "repo-url": url, "repo-rev": revision})
        metadata = {"packages": {"Dependency": entry}}
        project = self.project / "Project.toml"
        manifest = self.project / "Manifest.toml"
        def write_source(source, locked=None):
            project.write_text(f'[deps]\nDependency = "{UUID}"\n[sources.Dependency]\n' +
                               "".join(f'{k} = {json.dumps(v)}\n' for k,v in source.items()))
            values = entry if locked is None else locked
            manifest.write_text('julia_version = "1.12.7"\nmanifest_format = "2.0"\n[[deps.Dependency]]\n' +
                                "".join(f'{k} = {json.dumps(v)}\n' for k,v in values.items()))
        matching = {"url": url, "rev": revision}
        write_source(matching)
        self.assertEqual(image.validate_project(self.project, self.info, metadata), self.project)
        for source in ({"path": "../editable"}, {"url": url},
                       {"url": url, "rev": "main"}, {"url": url, "rev": "f" * 40},
                       {"url": url + "-other", "rev": revision},
                       dict(matching, path="../editable")):
            write_source(source)
            with self.subTest(source=source), self.assertRaisesRegex(image.Rejected, "source override"):
                image.validate_project(self.project, self.info, metadata)
        for key, value in (("repo-url", url + "-other"), ("repo-rev", "f" * 40),
                           ("git-tree-sha1", "b" * 40), ("path", "../editable")):
            write_source(matching, dict(entry, **{key:value}))
            with self.subTest(manifest_key=key), self.assertRaises(image.Rejected):
                image.validate_project(self.project, self.info, metadata)
        floating = dict(entry, **{"repo-rev": "main"})
        write_source({"url": url, "rev": "main"}, floating)
        with self.assertRaisesRegex(image.Rejected, "source override"):
            image.validate_project(self.project, self.info, {"packages": {"Dependency": floating}})

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

    def run_launch(self, mode="auto", compatible=True, extra=(), script=None):
        recipe = self.project / "kaimon.toml"
        recipe.write_text('[launch]\nthreads = "2,1"\nextra_flags = ["--check-bounds=yes"]\n'
                          '[city_sysimage]\njulia_bin = "/original/julia"\n'
                          f'mode = "{mode}"\nartifact_root = {json.dumps(str(self.root))}\n')
        before = recipe.read_bytes()
        calls = []
        info = self.info if compatible else dict(self.info, version="1.13.2")
        argv = ["-i", "-t", "2,1", "--check-bounds=yes", f"--project={self.project}",
                *extra, "--startup-file=no", "-e", script or 'using Gate; state = "$literal"']
        def execute(binary, flags):
            calls.append((binary, flags))
            self.launch_status = os.environ.get("KAIMON_CITY_SYSIMAGE")
        with patch.dict(os.environ, {"JULIA_LOAD_PATH": str(self.gate)}, clear=True), patch.object(image, "runtime", return_value=info), \
             patch.object(image, "check_project_compat"):
            code = image.launch(argv, execute=execute)
        self.assertEqual(recipe.read_bytes(), before)
        return code, calls, argv

    def test_preserve_recipe_project_and_flags(self):
        code, calls, argv = self.run_launch()
        self.assertEqual(code, 0)
        self.assertEqual(calls[0][1], ["/original/julia", f"--sysimage={self.artifact / 'image.dylib'}", *argv])

    def managed_script(self, restart="true"):
        quote = json.dumps(str(self.project), ensure_ascii=False).replace("$", "\\$")
        return (f"cd({quote})\nimport Pkg\ntry; using Revise; catch; end\n"
                "using KaimonGate\nPkg.instantiate(; io=devnull)\n"
                f'@async KaimonGate.serve(force=true, allow_mirror=true, allow_restart={restart}, spawned_by="agent")\n')

    def test_managed_neutral_instantiate_before_image_preserves_flags(self):
        for restart in ("false", "true"):
            script = self.managed_script(restart)
            with patch.object(image, "run_julia") as neutral:
                code, calls, original = self.run_launch(script=script)
            self.assertEqual(code, 0)
            neutral.assert_called_once()
            positional, kwargs = neutral.call_args
            self.assertEqual(positional[0], "/original/julia")
            self.assertIn("Pkg.instantiate(; io=devnull, allow_autoprecomp=false)", positional[1])
            self.assertIn("cd(ARGS[1])", positional[1])
            self.assertEqual(positional[2], self.project)
            self.assertEqual(kwargs, {"project": self.project, "preserve_load_path": True})
            # Only the verified operation is replaced; every caller flag stays.
            argv = calls[0][1]
            self.assertEqual(argv[:-1], ["/original/julia", f"--sysimage={self.artifact / 'image.dylib'}", *original[:-1]])
            self.assertEqual(argv[-1].replace("# Pkg.instantiate completed in neutral prelaunch Julia.",
                                            "Pkg.instantiate(; io=devnull)"), script)

    def test_managed_unknown_bootstrap_never_runs_neutral_or_rewrites(self):
        for script in (self.managed_script().replace("io=devnull", "verbose=true"),
                       self.managed_script().replace("using KaimonGate\n", "using OtherGate\n"),
                       self.managed_script() + "dangerous_side_effect()\n"):
            with patch.object(image, "run_julia") as neutral:
                _, calls, argv = self.run_launch(script=script)
            neutral.assert_not_called()
            self.assertEqual(calls[0][1], ["/original/julia", *argv])
            self.assertIn("unrecognized managed bootstrap", self.launch_status)

    def test_managed_instantiate_failure_does_not_load_image(self):
        for mode in ("auto", "required"):
            failure = image.subprocess.CalledProcessError(1, ["julia"], stderr="missing artifact")
            with patch.object(image, "run_julia", side_effect=failure):
                code, calls, argv = self.run_launch(mode=mode, script=self.managed_script())
            if mode == "required":
                self.assertEqual(code, 78)
                self.assertEqual(calls, [])
            else:
                self.assertEqual(calls[0][1], ["/original/julia", *argv])

    def test_managed_instantiate_cannot_silently_update_lock_or_project(self):
        for file in (self.project / "Project.toml", self.project / "Manifest.toml"):
            old = file.read_bytes()
            def change(*args, **kwargs):
                file.write_bytes(old + b"\n# changed during instantiate\n")
            with patch.object(image, "run_julia", side_effect=change):
                _, calls, argv = self.run_launch(script=self.managed_script())
            self.assertEqual(calls[0][1], ["/original/julia", *argv])
            self.assertIn("changed during neutral instantiation", self.launch_status)
            file.write_bytes(old)

    def test_managed_revalidates_artifact_after_instantiate(self):
        def corrupt(*args, **kwargs):
            (self.artifact / "image.dylib").write_bytes(b"changed during instantiate")
        with patch.object(image, "run_julia", side_effect=corrupt):
            _, calls, argv = self.run_launch(script=self.managed_script())
        self.assertEqual(calls[0][1], ["/original/julia", *argv])
        self.assertIn("checksum mismatch", self.launch_status)

    def test_off_explicit_and_test_cache_flags_do_not_preinstantiate(self):
        for mode, extra in (("off", ()), ("auto", ("--sysimage=/caller",)),
                            ("auto", ("--compiled-modules=no",)),
                            ("auto", ("--compiled-modules=existing",))):
            with patch.object(image, "run_julia") as neutral:
                _, calls, argv = self.run_launch(mode=mode, extra=extra, script=self.managed_script())
            neutral.assert_not_called()
            self.assertEqual(calls[0][1], ["/original/julia", *argv])

    def test_managed_rechecks_freshness_sources_and_preferences_after_instantiate(self):
        script = self.managed_script()
        for message in ("stale path-source Project hash", "nonempty baked-package preferences"):
            with patch.object(image, "run_julia") as neutral, \
                 patch.object(image, "check_project_compat", side_effect=image.Rejected(message)) as check:
                with self.assertRaisesRegex(image.Rejected, message):
                    image.neutral_managed_bootstrap("/original/julia", self.project, script,
                                                   self.info, self.meta, self.artifact, [self.gate])
            neutral.assert_called_once()
            check.assert_called_once_with("/original/julia", self.project, self.info, self.meta, [self.gate])

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

    def test_active_profile_controls_selection_and_rollback(self):
        second_meta = json.loads(json.dumps(self.meta))
        second_meta["spec"]["variant"] = "second compatible artifact"
        second_id = image.hashlib.sha256(image.canonical(second_meta["spec"])).hexdigest()
        second = self.root / second_id
        shutil.copytree(self.artifact, second)
        second_meta["id"] = second_id
        (second / "metadata.json").write_text(json.dumps(second_meta))
        profile_file = self.root / "current-profile.json"
        for intended in (second, self.artifact):
            profile_file.write_text(json.dumps({"schema": 1, "artifact": str(intended),
                                               "artifact_id": intended.name}))
            root, profile = image.selection_configuration(str(self.root), str(profile_file))
            selected, metadata, failures = image.select_image(root, self.project, self.info, profile=profile)
            self.assertEqual(selected, intended / "image.dylib")
        selected, _, failures = image.select_image(self.root, self.project, self.info)
        self.assertIsNone(selected)
        self.assertTrue(any("ambiguous" in f for f in failures))

    def test_wrapper_checks_actual_gate_by_default_and_exports_status(self):
        self.run_launch()
        self.assertEqual(self.launch_status, self.meta["id"])
        gate_manifest = self.gate / "Manifest.toml"
        gate_manifest.write_text(gate_manifest.read_text().replace('1.2.3', '1.2.4'))
        code, calls, argv = self.run_launch()
        self.assertEqual(calls[0][1], ["/original/julia", *argv])
        self.assertIn("bootstrap environment", self.launch_status)
        self.run_launch(mode="off")
        self.assertEqual(self.launch_status, "off")

    def test_atomic_activation_and_rollback_point_to_published_profile(self):
        files = []
        for name in ("first", "rollback"):
            directory = self.root / "profiles" / name
            directory.mkdir(parents=True)
            file = directory / "profile.json"
            file.write_text(json.dumps({"schema": 1, "artifact": str(self.artifact),
                                        "artifact_id": self.artifact.name}))
            files.append(file)
        current = self.root / ".gc/kaimon-sysimages/current"
        with patch.object(image, "CITY", self.root), patch.object(image, "DEFAULT_PROFILE", current / "profile.json"), \
             patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            for file in files:
                image.activate_profile(str(file))
                self.assertTrue(current.is_symlink())
                self.assertEqual(current.resolve(), file.parent)
                root, profile = image.selection_configuration()
                self.assertEqual(profile["_file"], str(file))
                self.assertEqual(root, self.root)

    def test_wrapper_enforces_requested_runtime(self):
        self.run_launch()
        recipe = self.project / "kaimon.toml"
        recipe.write_text(recipe.read_text().replace('[launch]', '[launch]\njulia_version = "1.13.2"'))
        calls = []
        with patch.dict(os.environ, {}, clear=True), patch.object(image, "runtime", return_value=self.info):
            code = image.launch([f"--project={self.project}", "-e", "1"], execute=lambda *args: calls.append(args))
            self.assertIn("requested Julia", os.environ["KAIMON_CITY_SYSIMAGE"])
        self.assertEqual(code, 78)
        self.assertFalse(calls)


if __name__ == "__main__":
    unittest.main()
