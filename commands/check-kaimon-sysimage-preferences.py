"""Light actual Julia preference controls; no package imports, images or managed gates.

Run with --julia EXACT_BINARY --scratch-root OWNED_DIRECTORY. Fixture images
exercise pre-exec selection only and are never passed to Julia.
"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("image", Path(__file__).with_name("kaimon-sysimage.py"))
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--julia", required=True)
parser.add_argument("--scratch-root", required=True)
args, remaining = parser.parse_known_args()
Path(args.scratch_root).mkdir(parents=True, exist_ok=True)
UUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
OTHER = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
PACKAGES = {"Dependency": {"uuid": UUID, "version": "1.0.0", "git-tree-sha1": "0" * 40}}


class Preferences(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.info = image.runtime(args.julia)
        assert cls.info["version"] == "1.13.2", cls.info["version"]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="preferences-", dir=args.scratch_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.target = self.root / "target"
        self.gate = self.root / "gate"
        for path in (self.target, self.gate):
            path.mkdir()
            (path / "Project.toml").write_text(
                f'[deps]\nDependency = "{UUID}"\nOther = "{OTHER}"\n')
        (self.target / "Manifest.toml").write_text(
            'julia_version = "1.13.2"\nmanifest_format = "2.0"\n'
            f'[[deps.Dependency]]\nuuid = "{UUID}"\nversion = "1.0.0"\ngit-tree-sha1 = "' + "0" * 40 + '"\n'
            f'[[deps.Other]]\nuuid = "{OTHER}"\nversion = "1.0.0"\ngit-tree-sha1 = "' + "1" * 40 + '"\n')
        # Compute Pkg's real root hash without resolving/installing fixture packages.
        image.run_julia(args.julia, '''import Pkg, TOML
file = joinpath(ARGS[1], "Manifest.toml")
m = TOML.parsefile(file)
m["project_hash"] = Pkg.Types.workspace_resolve_hash(Pkg.Types.EnvCache(joinpath(ARGS[1],"Project.toml")))
open(io->TOML.print(io,m;sorted=true),file,"w")''', self.target)
        self.manifest = (self.target / "Manifest.toml").read_bytes()
        self.environment = patch.dict(os.environ, {"JULIA_LOAD_PATH": "@:@stdlib"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def audit(self, stacks=None):
        return image.audit_preferences(args.julia, PACKAGES,
                                       stacks or [[str(self.target), str(self.gate), "@stdlib"]])

    def compatible(self):
        return image.check_project_compat(args.julia, self.target,
                                          dict(self.info, load_path=["@", "@stdlib"]),
                                          {"packages": PACKAGES}, [self.gate])

    def test_current_default_and_unchanged_manifest(self):
        self.compatible()
        self.assertEqual((self.target / "Manifest.toml").read_bytes(), self.manifest)

    def test_exported_preference_ignored_by_manifest_freshness_is_rejected(self):
        with (self.target / "Project.toml").open("a") as out:
            out.write('\n[preferences.Dependency]\nbackend = "fixture-secret"\n')
        image.check_project_compat(args.julia, self.target, self.info)
        with self.assertRaisesRegex(image.Rejected, "non-default preferences") as error:
            self.compatible()
        self.assertNotIn("fixture-secret", str(error.exception))
        self.assertEqual((self.target / "Manifest.toml").read_bytes(), self.manifest)

    def test_local_preference_ignored_by_manifest_freshness_is_rejected(self):
        (self.target / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
        image.check_project_compat(args.julia, self.target, self.info)
        with self.assertRaisesRegex(image.Rejected, "non-default preferences"):
            self.compatible()

    def test_bootstrap_preference_is_rejected(self):
        (self.gate / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
        with self.assertRaisesRegex(image.Rejected, "non-default preferences"):
            self.compatible()

    def test_unbaked_preferences_are_accepted(self):
        (self.target / "LocalPreferences.toml").write_text('[Other]\nbackend = "fixture-secret"\n')
        self.compatible()

    def test_julialocal_overrides_local_filename(self):
        (self.target / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
        (self.target / "JuliaLocalPreferences.toml").write_text('[Other]\nbackend = "fixture-secret"\n')
        self.compatible()

    def test_local_clear_of_exported_preference_is_accepted(self):
        with (self.target / "Project.toml").open("a") as out:
            out.write('\n[preferences.Dependency]\nbackend = "fixture-secret"\n')
        (self.target / "LocalPreferences.toml").write_text('[Dependency]\n__clear__ = ["backend"]\n')
        self.compatible()

    def test_ordered_load_stack_clear_and_reverse_order(self):
        (self.gate / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
        (self.target / "LocalPreferences.toml").write_text('[Dependency]\n__clear__ = ["backend"]\n')
        self.audit([[str(self.target), str(self.gate), "@stdlib"]])
        with self.assertRaisesRegex(image.Rejected, "non-default preferences"):
            self.audit([[str(self.gate), str(self.target), "@stdlib"]])

    def test_actual_base_wrapper_stack_preserved(self):
        (self.gate / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
        wrapper = self.root / "julia-wrapper"
        # All generated paths are owned fixture paths; quote for the shell.
        import shlex
        stack = f"{self.gate}:@:@stdlib"
        wrapper.write_text('#!/bin/sh\nexport JULIA_LOAD_PATH=' + shlex.quote(stack) +
                           '\nexec ' + shlex.quote(args.julia) + ' "$@"\n')
        wrapper.chmod(0o755)
        info = image.runtime(wrapper, self.target)
        self.assertEqual(info["load_path"], [str(self.gate), "@", "@stdlib"])
        with self.assertRaisesRegex(image.Rejected, "non-default preferences"):
            image.check_project_compat(wrapper, self.target, info, {"packages": PACKAGES}, [self.gate])

    def test_extension_uuid_preferences_are_rejected(self):
        extension_uuid = image.run_julia(args.julia,
            'print(Base.uuid5(Base.UUID(ARGS[1]),"DependencyExt"))', UUID).strip()
        with (self.target / "Project.toml").open("a") as out:
            out.write(f'DependencyExt = "{extension_uuid}"\n')
        (self.target / "LocalPreferences.toml").write_text('[DependencyExt]\nbackend = "fixture-secret"\n')
        packages = {"Dependency": dict(PACKAGES["Dependency"], extensions={"DependencyExt": "Other"})}
        with self.assertRaisesRegex(image.Rejected, "non-default preferences"):
            image.audit_preferences(args.julia, packages, [[str(self.target), "@stdlib"]])

    def test_native_build_preflight_without_construction(self):
        # Execute the actual builder prefix up to its construction boundary,
        # omitting the PackageCompiler import. No compiler or image is started.
        code = '''file, project = ARGS
prefix = first(split(read(file,String),"PackageCompiler.create_sysimage(";limit=2))
prefix = replace(prefix,"using PackageCompiler, TOML"=>"using TOML")
empty!(ARGS); append!(ARGS,[project,"unused-image","unused-workload","generic","Dependency"])
include_string(Main,prefix,file)
println("BUILD_PREFERENCE_PREFLIGHT_PASS")'''
        file = Path(__file__).with_name("kaimon-sysimage-build.jl").resolve()
        result = image.run_julia(args.julia, code, file, self.target)
        self.assertIn("BUILD_PREFERENCE_PREFLIGHT_PASS", result)
        (self.target / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
        with self.assertRaises(image.subprocess.CalledProcessError) as error:
            image.run_julia(args.julia, code, file, self.target)
        self.assertIn("non-default baked-package preferences", error.exception.stderr)
        self.assertNotIn("fixture-secret", error.exception.stderr)

    def test_pre_exec_selection_fallback_required_and_off(self):
        # Published-layout bytes are a selector fixture, never a Julia image.
        staging = self.root / "artifacts/staging"
        (staging / "dependencies").mkdir(parents=True)
        (staging / "dependencies/Manifest.toml").write_bytes(self.manifest)
        packages = image.entries(image.read_toml(staging / "dependencies/Manifest.toml"))
        preferences = image.audit_preferences(args.julia, packages, [[str(self.target), "@stdlib"]])
        (staging / "preferences.json").write_text(json.dumps(preferences))
        (staging / "image.dylib").write_bytes(b"selector fixture only")
        inputs = {name: image.sha(staging / name) for name in
                  ("dependencies/Manifest.toml", "preferences.json")}
        build = {"runtime": image.runtime_identity(self.info),
                 "platform": [image.sys.platform, image.platform.machine()], "cpu_target": "generic",
                 "preferences": image.preference_identity(packages), "inputs": inputs}
        identity = image.hashlib.sha256(image.canonical(build)).hexdigest()
        meta = {"schema": image.SCHEMA, "id": identity, "spec": build, "inputs": inputs,
                "packages": packages, "image_sha256": image.sha(staging / "image.dylib")}
        (staging / "metadata.json").write_text(json.dumps(meta))
        staging.rename(staging.parent / identity)
        gate_project = self.gate / "Project.toml"
        gate_project.write_text(f'name = "KaimonGate"\nuuid = "{image.GATE_UUID}"\n' + gate_project.read_text())
        (self.gate / "Manifest.toml").write_bytes(self.manifest)
        recipe = self.target / "kaimon.toml"
        template = ('[city_sysimage]\njulia_bin = ' + json.dumps(args.julia) +
                    '\nartifact_root = ' + json.dumps(str(staging.parent)) +
                    '\nbootstrap_projects = [' + json.dumps(str(self.gate)) + ']\nmode = "{}"\n')
        argv = [f"--project={self.target}", "-e", "1"]
        calls = []
        def execute(binary, flags):
            calls.append(flags)
        with patch.dict(os.environ, {}, clear=False), contextlib.redirect_stderr(io.StringIO()):
            recipe.write_text(template.format("auto"))
            self.assertEqual(image.launch(argv, execute), 0)
            self.assertTrue(any(flag.startswith("--sysimage=") for flag in calls.pop()))
            (self.target / "LocalPreferences.toml").write_text('[Dependency]\nbackend = "fixture-secret"\n')
            self.assertEqual(image.launch(argv, execute), 0)
            self.assertEqual(calls.pop(), [str(Path(args.julia).resolve()), *argv])
            self.assertIn("non-default preferences", os.environ["KAIMON_CITY_SYSIMAGE"])
            recipe.write_text(template.format("required"))
            self.assertEqual(image.launch(argv, execute), 78)
            self.assertFalse(calls)
            recipe.write_text(template.format("off"))
            os.environ["KAIMON_SYSIMAGE_PROFILE"] = str(self.root / "missing-profile")
            self.assertEqual(image.launch(argv, execute), 0)
            self.assertEqual(calls.pop(), [str(Path(args.julia).resolve()), *argv])

    def test_no_preference_values_in_audit_or_parse_errors(self):
        audit = self.audit()
        self.assertEqual(audit["effective_sha256"], image.preference_identity(PACKAGES)["effective_sha256"])
        (self.target / "LocalPreferences.toml").write_text('[Dependency]\nbackend = fixture-secret\n')
        with self.assertRaises(image.Rejected) as error:
            self.compatible()
        self.assertNotIn("fixture-secret", str(error.exception))

    def test_builtin_sysimage_module_bypasses_preference_cache_check(self):
        # This is a source-path control using the existing Julia base image,
        # not native acceptance of a new city image or a custom Preferences package.
        result = image.run_julia(args.julia, '''using TOML
id = Base.PkgId(Base.UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c"),"Random")
before = Base.root_module(id)
@assert Base.in_sysimage(id)
copy!(LOAD_PATH,[ARGS[1],"@stdlib"])
blob = "[unset]\\n\\\"" * string(id.uuid) * "\\\" = [\\\"probe\\\"]\\n"
@assert Base.stale_prefs(blob)
after = Base.require(id)
TOML.print(Dict("in_sysimage"=>Base.in_sysimage(id),"stale_prefs"=>Base.stale_prefs(blob),
                "same_module"=>before === after,"version"=>string(VERSION)))''', self.probe_project())
        observed = image.tomllib.loads(result)
        self.assertTrue(observed["stale_prefs"])
        self.assertTrue(observed["same_module"])
        print("BUILTIN_SYSIMAGE_PREF_CACHE_BYPASS_PASS", flush=True)

    def probe_project(self):
        path = self.root / "sysimage-probe"
        path.mkdir()
        (path / "Project.toml").write_text('[deps]\nRandom = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"\n')
        (path / "LocalPreferences.toml").write_text('[Random]\nprobe = true\n')
        return path


if __name__ == "__main__":
    unittest.main(argv=[__file__, *remaining], verbosity=2)
