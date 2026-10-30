"""Adversarial integration tests for `kaimon-sysimage.py prepare` (mc-xf9j5.4).

Black-box: each case runs the real CLI with the exact Julia runtime against a
small fixture lock carved from the common union lock, inside a temporary
fixture city. Nothing outside the temporary directory is written; packages are
read from the union depot, offline. Requires Python >= 3.11 and Julia 1.13.2.

  KAIMON_SYSIMAGE_PY      selector/CLI under test (default: sibling kaimon-sysimage.py)
  KAIMON_PREPARE_JULIA    exact Julia binary (default: juliaup 1.13.2)
  KAIMON_UNION_MANIFEST   common lock (default: mc-xf9j5 union-resolver/Manifest.toml)
  KAIMON_UNION_DEPOT      read-only depot holding the locked packages
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

CITY = Path(os.environ.get("GC_CITY", "/Users/Shared/Developer/ai/city/math-city"))
TASK = CITY / ".gc/kaimon-sysimages/mc-xf9j5"
CLI = Path(os.environ.get("KAIMON_SYSIMAGE_PY", Path(__file__).with_name("kaimon-sysimage.py")))
JULIA = Path(os.environ.get("KAIMON_PREPARE_JULIA", Path.home() / ".julia/juliaup/"
             "julia-1.13.2+0.aarch64.apple.darwin14/Julia-1.13.app/Contents/Resources/julia/bin/julia"))
UNION = Path(os.environ.get("KAIMON_UNION_MANIFEST", TASK / "union-resolver/Manifest.toml"))
DEPOT = Path(os.environ.get("KAIMON_UNION_DEPOT", TASK / "union-depot"))

TARGET_UUID = "0b7c3a59-5f0e-4d58-9a43-2a6f0c9e1d01"
CITY_DEP_UUID = "0b7c3a59-5f0e-4d58-9a43-2a6f0c9e1d02"
OTHER_DEP_UUID = "0b7c3a59-5f0e-4d58-9a43-2a6f0c9e1d03"
# CUDA_Driver_jll carries .pkg/select_artifacts.jl: exercises Pkg's artifact-selector subprocess.
EXTERNALS = ["Primes", "Combinatorics", "CUDA_Driver_jll"]

spec = importlib.util.spec_from_file_location("sysimage", CLI)
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)


def toml_value(value):
    if isinstance(value, list):
        return "[" + ", ".join(json.dumps(v) for v in value) + "]"
    return json.dumps(value)


def write_manifest(path, julia_version, entries):
    """Minimal writer for flat Manifest entries with optional nested tables."""
    lines = [f"julia_version = {json.dumps(julia_version)}", 'manifest_format = "2.0"', ""]
    for name in sorted(entries):
        entry = entries[name]
        lines.append(f"[[deps.{name}]]")
        tables = {k: v for k, v in entry.items() if isinstance(v, dict)}
        lines.extend(f"{k} = {toml_value(v)}" for k, v in sorted(entry.items()) if k not in tables)
        for key, table in sorted(tables.items()):
            lines.append(f"\n    [deps.{name}.{key}]")
            lines.extend(f"    {k} = {toml_value(v)}" for k, v in sorted(table.items()))
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


def package(directory, name, uuid, deps, version="0.1.0", sources=None):
    (directory / "src").mkdir(parents=True)
    text = f'name = "{name}"\nuuid = "{uuid}"\nversion = "{version}"\n\n[deps]\n'
    text += "".join(f'{n} = "{u}"\n' for n, u in deps.items())
    if sources:
        text += "\n[sources]\n" + "".join(f"{n} = {s}\n" for n, s in sources.items())
    (directory / "Project.toml").write_text(text)
    (directory / "src" / f"{name}.jl").write_text(f"module {name}\nmarker() = {json.dumps(str(directory))}\nend\n")


@unittest.skipUnless(JULIA.is_file() and UNION.is_file() and DEPOT.is_dir(), "exact runtime/lock unavailable")
class Prepare(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        union = image.entries(image.read_toml(UNION))
        cls.julia_version = image.read_toml(UNION)["julia_version"]
        closure = image.dependency_closure(union, EXTERNALS)
        cls.locked = {n: union[n] for n in closure}
        cls.uuid = {n: e["uuid"] for n, e in cls.locked.items()}

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.city = Path(temp.name).resolve() / "fixture-city"
        self.owned = self.city / ".gc/owned-task"
        canonical = self.city / "math-code-projects"
        # Editable city packages live at canonical (non-owned) paths in the lock.
        package(canonical / "CityDep", "CityDep", CITY_DEP_UUID, {"Primes": self.uuid["Primes"]})
        package(canonical / "OtherDep", "OtherDep", OTHER_DEP_UUID, {"Combinatorics": self.uuid["Combinatorics"]})
        lock = {n: dict(e) for n, e in self.locked.items()}
        lock["CityDep"] = {"deps": ["Primes"], "path": str(canonical / "CityDep"),
                           "uuid": CITY_DEP_UUID, "version": "0.1.0"}
        lock["OtherDep"] = {"deps": ["Combinatorics"], "path": str(canonical / "OtherDep"),
                            "uuid": OTHER_DEP_UUID, "version": "0.1.0"}
        self.lock = self.city / "union/Manifest.toml"
        self.lock.parent.mkdir(parents=True)
        write_manifest(self.lock, self.julia_version, lock)
        self.canonical_dep = canonical / "CityDep"
        self.owned_dep = self.owned / "CityDep"
        package(self.owned_dep, "CityDep", CITY_DEP_UUID, {"Primes": self.uuid["Primes"]})
        self.target = self.owned / "Target"
        package(self.target, "Target", TARGET_UUID,
                {"Primes": self.uuid["Primes"], "CityDep": CITY_DEP_UUID})
        with (self.target / "Project.toml").open("a") as stream:
            # Comment and ordering are part of the original bytes that must survive.
            stream.write('\n# pinned by authors\n[compat]\nPrimes = "0.5"\njulia = "1.10"\n')
        # Legacy manifest: older pins plus a foreign absolute dev path.
        write_manifest(self.target / "Manifest.toml", "1.12.7", {
            "Primes": {"deps": ["IntegerMathUtils"], "git-tree-sha1": "0" * 40,
                       "uuid": self.uuid["Primes"], "version": "0.5.0"},
            "IntegerMathUtils": dict(self.locked["IntegerMathUtils"]),
            "CityDep": {"path": "/nonexistent/foreign/CityDep", "uuid": CITY_DEP_UUID, "version": "0.1.0"}})
        self.depot = self.city / "depot"
        self.depot.mkdir()

    # -- helpers ---------------------------------------------------------------
    def snapshot(self, directory=None):
        directory = directory or self.target
        return {p.name: p.read_bytes() for p in sorted(directory.iterdir()) if p.is_file()}

    def path_map(self, mapping):
        path = self.owned / "path-map.toml"
        path.write_text("".join(f"{n} = {json.dumps(str(p))}\n" for n, p in mapping.items()))
        return path

    def prepare(self, path_map=None, project=None, owned_root=None, lock=None, extra=()):
        argv = [sys.executable, str(CLI), "prepare", "--project", str(project or self.target),
                "--union-manifest", str(lock or self.lock), "--julia", str(JULIA),
                "--owned-root", str(owned_root or self.owned)]
        if path_map:
            argv += ["--path-map", str(path_map)]
        argv += list(extra)
        env = dict(os.environ, GC_CITY=str(self.city), JULIA_PKG_OFFLINE="true",
                   JULIA_PKG_PRECOMPILE_AUTO="0", JULIA_LOAD_PATH="@:@stdlib",
                   # Trailing empty entry keeps Julia's bundled stdlib caches (not a clean-depot gate).
                   JULIA_DEPOT_PATH=os.pathsep.join([str(self.depot), str(DEPOT), str(Path.home() / ".julia"), ""]))
        env.pop("JULIA_PROJECT", None)
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=600)
        result.log = f"rc={result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        return result

    def output(self):
        return image.entries(image.read_toml(self.target / f"Manifest-v{self.series}.toml"))

    @property
    def series(self):
        return ".".join(self.julia_version.split(".")[:2])

    def report(self, result):
        return json.loads(result.stdout[result.stdout.index("{"):])

    def assert_refused_unchanged(self, result, before):
        self.assertNotEqual(result.returncode, 0, result.log)
        self.assertEqual(self.snapshot(), before, "refusal must leave every project file byte-identical")

    def assert_pinned_to_lock(self, pins):
        for name, expected in self.locked.items():
            if name in pins and "git-tree-sha1" in expected:
                actual = pins[name]
                self.assertNotIn("path", actual, name)
                self.assertEqual((actual["version"], actual["git-tree-sha1"]),
                                 (expected["version"], expected["git-tree-sha1"]), name)

    # -- acceptance ------------------------------------------------------------
    def test_explicit_owned_source_frozen_pins_and_legacy_manifest_preserved(self):
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        pins = self.output()
        self.assert_pinned_to_lock(pins)
        self.assertEqual(Path(pins["CityDep"]["path"]).resolve(), self.owned_dep.resolve())
        self.assertEqual(self.snapshot()["Manifest.toml"], before["Manifest.toml"])
        self.assertNotIn("Target", pins, "root package must stay the active project, not a manifest dep")

    def test_selector_accepts_prepared_project_against_locked_graph(self):
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        info = {"version": self.julia_version}
        baked = {n: e for n, e in self.locked.items() if "git-tree-sha1" in e}
        image.validate_project(self.target, info, {"packages": baked})

    def test_original_project_bytes_unchanged_or_exactly_recoverable(self):
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        if self.snapshot()["Project.toml"] == before["Project.toml"]:
            return
        backup = Path(self.report(result)["rollback_backup"])
        self.assertEqual((backup / "Project.toml").read_bytes(), before["Project.toml"])

    def test_project_changes_are_minimal_and_reported(self):
        """Transparency: only [sources] may differ logically; an exact Project.diff and
        byte backup are recorded (reformatting is accepted by the coordinator)."""
        before = (self.target / "Project.toml").read_text()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        after = (self.target / "Project.toml").read_text()
        if after == before:
            return
        report = self.report(result)
        diff = Path(report["project_diff"]).read_text()
        if "# pinned by authors" not in after:
            self.assertIn("# pinned by authors", diff, "Project.diff omits a removed author line")
        self.assertIn(str(self.owned_dep), diff, "Project.diff omits the source replacement")
        self.assertEqual((Path(report["rollback_backup"]) / "Project.toml").read_text(), before)
        old, new = tomllib.loads(before), tomllib.loads(after)
        old.pop("sources", None), new.pop("sources", None)
        self.assertEqual(old, new, "only [sources] may change")
        self.assertIn("CityDep", result.stdout + result.stderr, "source change must be reported precisely")

    def test_explicit_rollback_restores_original_bytes(self):
        before = self.snapshot()
        first = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(first.returncode, 0, first.log)
        second = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(second.returncode, 0, second.log)
        # Documented rollback: restore the FIRST backup, delete files it marks absent.
        backup = Path(self.report(first)["rollback_backup"])
        disposition = json.loads((backup / "disposition.json").read_text())
        for name, existed in disposition["files"].items():
            path = Path(name)
            if existed:
                shutil.copyfile(backup / path.name, path)
            else:
                path.unlink(missing_ok=True)
        self.assertEqual(self.snapshot(), before)

    def test_unmapped_editable_dependency_never_uses_canonical_path(self):
        before = self.snapshot()
        result = self.prepare()
        if result.returncode != 0:
            self.assertEqual(self.snapshot(), before)
            return
        text = (self.target / f"Manifest-v{self.series}.toml").read_text()
        text += (self.target / "Project.toml").read_text()
        self.assertNotIn(str(self.canonical_dep), text,
                         "canonical dev path silently propagated into owned worktree")

    def test_unrelated_union_editables_not_copied(self):
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        pins = self.output()
        self.assertNotIn("OtherDep", pins, "unrelated union member (canonical path) copied into output")
        self.assertNotIn("Combinatorics", pins, "unused locked packages should not be installed")

    def test_user_local_source_path_retained(self):
        local = self.owned / "my-local-CityDep"
        package(local, "CityDep", CITY_DEP_UUID, {"Primes": self.uuid["Primes"]})
        with (self.target / "Project.toml").open("a") as stream:
            stream.write('\n[sources]\nCityDep = {path = "../my-local-CityDep"}\n')
        before = self.snapshot()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.log)
        self.assertEqual(self.snapshot()["Project.toml"], before["Project.toml"],
                         "user-specified [sources] path rewritten")
        self.assertEqual((self.target / self.output()["CityDep"]["path"]).resolve(), local.resolve())

    def test_equivalent_explicit_path_preserves_relative_declaration(self):
        with (self.target / "Project.toml").open("a") as stream:
            stream.write('\n[sources]\nCityDep = {path = "../CityDep"}\n')
        before = (self.target / "Project.toml").read_bytes()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}), extra=("--preserve-project",))
        self.assertEqual(result.returncode, 0, result.log)
        self.assertEqual((self.target / "Project.toml").read_bytes(), before)

    def pinned_source(self):
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.owned_dep), *args], text=True).strip()
        git("init", "-q")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "add", ".")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "-qm", "fixture")
        git("tag", "v0.1.0")
        url = self.owned_dep.as_uri()
        git("remote", "add", "origin", url)
        with (self.target / "Project.toml").open("a") as stream:
            stream.write(f'\n[sources]\nCityDep = {{url = "{url}", rev = "v0.1.0"}}\n')
        lock = image.entries(image.read_toml(self.lock))
        lock["CityDep"].pop("path")
        lock["CityDep"].update({"repo-url": url, "repo-rev": "v0.1.0",
                               "git-tree-sha1": git("rev-parse", "HEAD^{tree}")})
        write_manifest(self.lock, self.julia_version, lock)

    def test_exact_pinned_checkout_preserves_source_and_resumes(self):
        self.pinned_source()
        before = (self.target / "Project.toml").read_bytes()
        for _ in range(2):
            result = self.prepare(extra=("--preserve-project",))
            self.assertEqual(result.returncode, 0, result.log)
            self.assertEqual((self.target / "Project.toml").read_bytes(), before)
            self.assertNotIn("path", self.output()["CityDep"])
            self.assertEqual(self.output()["CityDep"]["repo-rev"], "v0.1.0")

    def test_path_override_of_pinned_source_is_refused_without_writes(self):
        self.pinned_source()
        before = self.snapshot()
        mapping = self.path_map({"CityDep": self.owned_dep})
        self.assert_refused_unchanged(self.prepare(mapping), before)

    def test_preserve_project_rolls_back_source_rewrite(self):
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}), extra=("--preserve-project",))
        self.assert_refused_unchanged(result, before)

    def test_city_root_stays_editable_when_union_pins_its_git_source(self):
        self.pinned_source()
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace('name = "Target"', 'name = "GPUFiniteFieldMatrices"'))
        lock = image.entries(image.read_toml(self.lock))
        lock["GPUFiniteFieldMatrices"] = {"uuid": TARGET_UUID, "version": "0.1.0",
                                          "git-tree-sha1": "f" * 40, "deps": ["CityDep", "Primes"]}
        write_manifest(self.lock, self.julia_version, lock)
        result = self.prepare(extra=("--preserve-project",))
        self.assertEqual(result.returncode, 0, result.log)
        self.assertNotIn("GPUFiniteFieldMatrices", self.output())

    def test_compat_violation_refused_without_changes(self):
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace('Primes = "0.5"', 'Primes = "0.4"'))
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(result, before)

    def test_julia_compat_violation_refused(self):
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace('julia = "1.10"', 'julia = "1.10.0 - 1.12"'))
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(result, before)

    def test_path_map_cannot_override_locked_external(self):
        fake = self.owned / "Primes"
        package(fake, "Primes", self.uuid["Primes"], {})
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep, "Primes": fake}))
        self.assert_refused_unchanged(result, before)

    def test_path_map_identity_mismatch_refused(self):
        wrong = self.owned / "Wrong"
        package(wrong, "Wrong", "0b7c3a59-5f0e-4d58-9a43-2a6f0c9e1d09", {})
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": wrong}))
        self.assert_refused_unchanged(result, before)

    def test_foreign_versioned_manifest_not_overwritten(self):
        foreign = self.target / f"Manifest-v{self.series}.toml"
        write_manifest(foreign, self.julia_version, {k: v for k, v in self.locked.items() if k == "Combinatorics"})
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(result, before)

    def test_repeated_prepare_accepts_own_receipt(self):
        first = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(first.returncode, 0, first.log)
        output = self.snapshot()[f"Manifest-v{self.series}.toml"]
        second = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(second.returncode, 0, second.log)
        self.assertEqual(self.snapshot()[f"Manifest-v{self.series}.toml"], output, "repeat is not idempotent")

    def test_replace_existing_is_explicit_and_reversible(self):
        foreign = self.target / f"Manifest-v{self.series}.toml"
        write_manifest(foreign, self.julia_version, {k: v for k, v in self.locked.items() if k == "Combinatorics"})
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}), extra=["--replace-existing"])
        self.assertEqual(result.returncode, 0, result.log)
        backup = Path(self.report(result)["rollback_backup"])
        self.assertEqual((backup / foreign.name).read_bytes(), before[foreign.name])
        # Roll back to the foreign file; its bytes no longer match the receipt.
        foreign.write_bytes(before[foreign.name])
        (self.target / "Project.toml").write_bytes(before["Project.toml"])
        self.assertEqual(self.snapshot(), before)
        again = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(again, before)

    def test_receipt_does_not_cover_project_edits_silently(self):
        """Receipt matches the manifest, but the Project changed afterwards: no silent overwrite of intent."""
        first = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(first.returncode, 0, first.log)
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace('Primes = "0.5"', 'Primes = "0.5.1"'))
        second = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(second.returncode, 0, second.log)
        self.assertIn('Primes = "0.5.1"', project.read_text(), "author compat edit lost on re-prepare")

    def test_tampered_generated_output_refused_on_repeat(self):
        first = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(first.returncode, 0, first.log)
        output = self.target / f"Manifest-v{self.series}.toml"
        output.write_text(output.read_text().replace(self.locked["Primes"]["version"], "0.5.0", 1))
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(result, before)

    def test_malformed_generated_output_refused_on_repeat(self):
        first = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(first.returncode, 0, first.log)
        output = self.target / f"Manifest-v{self.series}.toml"
        output.write_text(output.read_text()[:-200] + "\n[[deps.Broken\n")
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(result, before)

    def test_project_outside_owned_root_refused(self):
        outside = self.city / "math-code-projects/CityDep"
        before = self.snapshot(outside)
        result = self.prepare(project=outside)
        self.assertNotEqual(result.returncode, 0, result.log)
        self.assertEqual(self.snapshot(outside), before)

    def test_owned_root_must_be_task_scoped(self):
        """A shared container as owner would cover other actors' worktrees.

        The refusal must come from the ownership guard itself, before any backup or
        Julia helper runs; an incidental downstream failure does not count.
        """
        backups = self.city / ".gc/kaimon-sysimages/prepare-backups"
        for container in (".gc", ".gc/worktrees", "worktrees", ".gc/agents"):
            with self.subTest(container=container):
                root = self.city / container
                target = root / "other-actor" / "Target"
                if not target.exists():
                    shutil.copytree(self.target, target)
                before = self.snapshot(target)
                existing = set(backups.glob("alignment-*")) if backups.is_dir() else set()
                result = self.prepare(self.path_map({"CityDep": self.owned_dep}), project=target, owned_root=root)
                self.assertNotEqual(result.returncode, 0, result.log)
                self.assertIn("owned root", result.stderr.lower(), "refused for an unrelated reason:\n" + result.log)
                self.assertEqual(self.snapshot(target), before)
                after = set(backups.glob("alignment-*")) if backups.is_dir() else set()
                self.assertEqual(after, existing, "guard ran after backup/helper work began")

    def test_runtime_mismatch_refused(self):
        stale = self.city / "union/Manifest-1.12.toml"
        stale.write_text(self.lock.read_text().replace(self.julia_version, "1.12.7", 1))
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}), lock=stale)
        self.assert_refused_unchanged(result, before)

    def test_inconsistent_legacy_manifest_does_not_block_owned_output(self):
        """A stale legacy Manifest.toml is preserved, never used to run the tool itself."""
        legacy = self.target / "Manifest.toml"
        legacy.write_text(legacy.read_text().replace('[[deps.IntegerMathUtils]]', '[[deps.Removed]]'))
        before = self.snapshot()["Manifest.toml"]
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        self.assertEqual(self.snapshot()["Manifest.toml"], before)

    # -- selection freshness after preparation ---------------------------------
    def fake_artifact(self):
        """Published-layout artifact with the real runtime identity and locked externals baked."""
        info = image.runtime(JULIA)
        root = self.city / "artifacts"
        staging = root / "staging"
        (staging / "dependencies").mkdir(parents=True)
        baked = {n: e for n, e in self.locked.items() if n in ("Primes", "IntegerMathUtils")}
        write_manifest(staging / "dependencies/Manifest.toml", self.julia_version, baked)
        inputs = {"dependencies/Manifest.toml": image.sha(staging / "dependencies/Manifest.toml")}
        preferences = dict(image.preference_identity(baked),
                           contexts=[{"empty": True, "nonempty_uuids": []}])
        (staging / "preferences.json").write_text(json.dumps(preferences))
        inputs["preferences.json"] = image.sha(staging / "preferences.json")
        spec = {"schema": image.SCHEMA, "preferences": image.preference_identity(baked),
                "runtime": image.runtime_identity(info),
                "platform": [sys.platform, image.platform.machine()], "cpu_target": "generic",
                "roots": ["Primes"], "inputs": inputs}
        identity = image.hashlib.sha256(image.canonical(spec)).hexdigest()
        (staging / "image.dylib").write_bytes(b"fixture image")
        meta = {"schema": image.SCHEMA, "id": identity, "spec": spec, "inputs": inputs,
                "packages": image.entries(image.read_toml(staging / "dependencies/Manifest.toml")),
                "image_sha256": image.sha(staging / "image.dylib")}
        (staging / "metadata.json").write_text(json.dumps(meta))
        staging.rename(root / identity)
        return root

    def fixture_gate(self):
        """Stand-in managed KaimonGate bootstrap env; its locked Primes overlap is validated."""
        gate = self.city / "gate"
        if not gate.is_dir():
            gate.mkdir()
            (gate / "Project.toml").write_text(
                f'name = "KaimonGate"\nuuid = "{image.GATE_UUID}"\nversion = "0.0.0"\n\n'
                f'[deps]\nPrimes = "{self.uuid["Primes"]}"\n')
            write_manifest(gate / f"Manifest-v{self.series}.toml", self.julia_version,
                           {n: self.locked[n] for n in ("Primes", "IntegerMathUtils")})
        return gate

    def select(self, root):
        argv = [sys.executable, str(CLI), "select", "--project", str(self.target),
                "--julia", str(JULIA), "--root", str(root),
                "--bootstrap-project", str(self.fixture_gate())]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=300,
                                env=dict(os.environ, GC_CITY=str(self.city)))
        result.log = f"rc={result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        return result

    def prepared_with_artifact(self):
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        root = self.fake_artifact()
        fresh = self.select(root)
        self.assertEqual(fresh.returncode, 0, fresh.log)
        return root

    def assert_stale_rejected(self, root):
        """Selection must refuse BEFORE a Kaimon auto-instantiate could re-resolve pins."""
        before = self.snapshot()
        result = self.select(root)
        self.assertNotEqual(result.returncode, 0, "stale manifest selected:\n" + result.log)
        self.assertEqual(self.snapshot(), before, "selection must not repair or mutate the project")

    def test_selection_rejects_root_dependency_added_after_prepare(self):
        root = self.prepared_with_artifact()
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace(
            "[deps]\n", f'[deps]\nCombinatorics = "{self.uuid["Combinatorics"]}"\n', 1))
        self.assert_stale_rejected(root)

    def test_selection_rejects_root_compat_edit_after_prepare(self):
        # Still satisfied by the pinned version, but the recorded project_hash is stale.
        root = self.prepared_with_artifact()
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace('Primes = "0.5"', 'Primes = "0.5.1"'))
        self.assert_stale_rejected(root)

    def test_selection_rejects_root_sources_edit_after_prepare(self):
        root = self.prepared_with_artifact()
        moved = self.owned / "moved-CityDep"
        package(moved, "CityDep", CITY_DEP_UUID, {"Primes": self.uuid["Primes"]})
        with (self.target / "Project.toml").open("a") as stream:
            stream.write(f'\n[sources]\nCityDep = {{path = {json.dumps(str(moved))}}}\n')
        self.assert_stale_rejected(root)

    def test_selection_rejects_path_dependency_project_edit_after_prepare(self):
        """Pkg.is_manifest_current hashes only the root; a path dependency's deps can go stale."""
        root = self.prepared_with_artifact()
        project = self.owned_dep / "Project.toml"
        project.write_text(project.read_text().replace(
            "[deps]\n", f'[deps]\nCombinatorics = "{self.uuid["Combinatorics"]}"\n', 1))
        self.assert_stale_rejected(root)

    def test_selection_rejects_path_dependency_compat_violation_after_prepare(self):
        root = self.prepared_with_artifact()
        with (self.owned_dep / "Project.toml").open("a") as stream:
            stream.write('\n[compat]\nPrimes = "0.4"\n')
        self.assert_stale_rejected(root)

    def test_selection_allows_ordinary_source_edits(self):
        root = self.prepared_with_artifact()
        for directory, name in ((self.target, "Target"), (self.owned_dep, "CityDep")):
            source = directory / "src" / f"{name}.jl"
            source.write_text(source.read_text() + "edited() = 42\n")
        (self.owned_dep / "src/extra.jl").write_text("helper() = 1\n")
        result = self.select(root)
        self.assertEqual(result.returncode, 0, result.log)

    def test_selection_validates_bootstrap_gate_overlap(self):
        """Negative control: the fixture gate is really checked, not a bypass."""
        root = self.prepared_with_artifact()
        manifest = self.fixture_gate() / f"Manifest-v{self.series}.toml"
        manifest.write_text(manifest.read_text().replace(self.locked["Primes"]["git-tree-sha1"], "0" * 40))
        self.assert_stale_rejected(root)
        self.assertIn("bootstrap", self.select(root).stderr.lower(), "rejected for an unrelated reason")

    def test_selection_independent_of_unrelated_canonical_projects(self):
        """Edits in an unrelated canonical checkout must not invalidate an owned target."""
        root = self.prepared_with_artifact()
        unrelated = self.city / "math-code-projects/OtherDep/Project.toml"
        unrelated.write_text(unrelated.read_text() + '\n[compat]\nCombinatorics = "1"\n')
        result = self.select(root)
        self.assertEqual(result.returncode, 0, result.log)

    def test_transitive_unmapped_editable_never_uses_canonical_path(self):
        """CityDep -> OtherDep: an editable reached transitively needs an explicit choice too."""
        project = self.owned_dep / "Project.toml"
        project.write_text(project.read_text().replace(
            "[deps]\n", f'[deps]\nOtherDep = "{OTHER_DEP_UUID}"\n', 1))
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        if result.returncode != 0:
            self.assertEqual(self.snapshot(), before)
            return
        text = (self.target / f"Manifest-v{self.series}.toml").read_text()
        self.assertNotIn(str(self.city / "math-code-projects/OtherDep"), text,
                         "transitive editable resolved to canonical path without explicit selection")

    def add_workspace_member(self, deps):
        with (self.target / "Project.toml").open("a") as stream:
            stream.write('\n[workspace]\nprojects = ["test"]\n')
        member = self.target / "test"
        member.mkdir()
        (member / "Project.toml").write_text("[deps]\n" + "".join(f'{n} = "{u}"\n' for n, u in deps.items()))

    def test_workspace_member_dependencies_pinned_to_lock(self):
        self.add_workspace_member({"Combinatorics": self.uuid["Combinatorics"]})
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        pins = self.output()
        self.assertIn("Combinatorics", pins, "workspace member dependency dropped from closure")
        self.assert_pinned_to_lock(pins)
        self.assertNotIn("OtherDep", pins)

    def test_workspace_member_unmapped_editable_refused_unchanged(self):
        self.add_workspace_member({"OtherDep": OTHER_DEP_UUID})
        before = self.snapshot()
        member = (self.target / "test/Project.toml").read_bytes()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        if result.returncode == 0:
            text = (self.target / f"Manifest-v{self.series}.toml").read_text()
            self.assertNotIn(str(self.city / "math-code-projects/OtherDep"), text,
                             "workspace member editable resolved to canonical path without explicit selection")
            return
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.target / "test/Project.toml").read_bytes(), member)

    def test_workspace_member_project_edit_stales_selection(self):
        self.add_workspace_member({"Combinatorics": self.uuid["Combinatorics"]})
        root = self.prepared_with_artifact()
        member = self.target / "test/Project.toml"
        member.write_text(member.read_text() + '\n[compat]\nCombinatorics = "1.1"\n')
        self.assert_stale_rejected(root)

    def test_artifact_selector_dependency_prepares(self):
        """Pkg runs .pkg/select_artifacts.jl in a child inheriting the ACTIVE project;
        preparation must succeed with such a dependency (real DeRham/MMP regression)."""
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace(
            "[deps]\n", f'[deps]\nCUDA_Driver_jll = "{self.uuid["CUDA_Driver_jll"]}"\n', 1))
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assertEqual(result.returncode, 0, result.log)
        pins = self.output()
        self.assertIn("CUDA_Driver_jll", pins)
        self.assert_pinned_to_lock(pins)

    def test_artifact_selector_with_broken_existing_manifest(self):
        """Safe bootstrap before repair and target activation after it, together."""
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace(
            "[deps]\n", f'[deps]\nCUDA_Driver_jll = "{self.uuid["CUDA_Driver_jll"]}"\n', 1))
        broken = self.target / f"Manifest-v{self.series}.toml"
        write_manifest(broken, self.julia_version, {k: v for k, v in self.locked.items() if k == "Combinatorics"})
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}), extra=["--replace-existing"])
        self.assertEqual(result.returncode, 0, result.log)
        self.assertEqual((Path(self.report(result)["rollback_backup"]) / broken.name).read_bytes(), before[broken.name])
        self.assertIn("CUDA_Driver_jll", self.output())

    def test_new_dependency_outside_lock_refused(self):
        project = self.target / "Project.toml"
        project.write_text(project.read_text().replace(
            "[deps]\n", '[deps]\nUnroll = "36e64239-2ab9-4580-84fb-56737a503d36"\n', 1))
        before = self.snapshot()
        result = self.prepare(self.path_map({"CityDep": self.owned_dep}))
        self.assert_refused_unchanged(result, before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
