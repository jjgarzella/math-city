#!/Users/jj-agents/.homebrew/opt/python@3.14/bin/python3.14
"""Pinned dependency images; opt-in Kaimon wrapper, with no daemon mutation.

Requires Python >= 3.11. Artifacts and build logs belong outside tracked source.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib

HERE = Path(__file__).resolve().parent
CITY = Path(os.environ.get("GC_CITY", "/Users/Shared/Developer/ai/city/math-city"))
DEFAULT_ROOT = CITY / ".gc/kaimon-sysimages/artifacts"
DEFAULT_PROFILE = CITY / ".gc/kaimon-sysimages/current/profile.json"
GATE_UUID = "5ee84a8c-75bd-412f-a7b8-4e6463aa635f"
# These are editable city packages, even when one project pins a registry release.
EDITABLE = {"DeRham", "NewtonExperiments", "GPUFiniteFieldMatrices", "EdgeIdeals",
            "MMPSingularities", "GPUPolynomials", "CudaNTTs", "GradedRingUtilities"}
SCHEMA = 1
PREFERENCE_POLICY = "empty-baked-preferences-v1"


class Rejected(ValueError):
    pass


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_toml(path):
    with Path(path).open("rb") as stream:
        return tomllib.load(stream)


def load_profile(path=None):
    explicit = bool(path or os.environ.get("KAIMON_SYSIMAGE_PROFILE"))
    file = Path(path or os.environ.get("KAIMON_SYSIMAGE_PROFILE", str(DEFAULT_PROFILE))).resolve()
    if not file.exists():
        if explicit:
            raise Rejected(f"requested city profile is missing: {file}")
        return None
    profile = json.loads(file.read_text())
    if not isinstance(profile, dict) or profile.get("schema") != SCHEMA:
        raise Rejected("unsupported city image profile schema")
    for key in ("artifact", "artifact_id"):
        if not isinstance(profile.get(key), str) or not profile[key]:
            raise Rejected(f"city profile is missing {key}")
    if "profile_id" in profile:
        payload = {k: v for k, v in profile.items() if k != "profile_id"}
        if hashlib.sha256(canonical(payload)).hexdigest() != profile["profile_id"]:
            raise Rejected("stale city profile identity")
    artifact = Path(profile["artifact"]).resolve()
    if artifact.name != profile["artifact_id"]:
        raise Rejected("profile artifact identity/path mismatch")
    root = Path(profile.get("artifact_root", str(artifact.parent))).resolve()
    if root != artifact.parent:
        raise Rejected("profile artifact root/path mismatch")
    for name, digest in profile.get("files", {}).items():
        candidate = (file.parent / name).resolve()
        if not candidate.is_relative_to(file.parent) or sha(candidate) != digest:
            raise Rejected(f"stale city profile input: {name}")
    profile.update(artifact=str(artifact), artifact_root=str(root),
                   _directory=str(file.parent), _file=str(file))
    return profile


def activate_profile(profile_file):
    profile = load_profile(profile_file)
    if Path(profile["_file"]).name != "profile.json":
        raise Rejected("activation requires the published profile.json filename")
    current = CITY / ".gc/kaimon-sysimages/current"
    current.parent.mkdir(parents=True, exist_ok=True)
    if current.exists() and not current.is_symlink():
        raise Rejected("current profile is not a managed symlink; refusing to replace its directory")
    temporary = current.with_name(".current-" + os.urandom(8).hex())
    temporary.symlink_to(profile["_directory"], target_is_directory=True)
    temporary.replace(current)
    print(json.dumps({"profile": profile["_file"], "artifact": profile["artifact"],
                      "artifact_id": profile["artifact_id"], "current": str(current)}, indent=2))


def publish_profile(args):
    artifact = Path(args.artifact).resolve()
    union_manifest = Path(args.union_manifest).resolve()
    info = runtime(args.julia, union_manifest.parent)
    bootstrap = effective_bootstrap_projects(union_manifest.parent, info, configured=args.bootstrap_project)
    _, meta = validate_artifact(artifact, info, union_manifest.parent, bootstrap)
    audit_preferences(args.julia, meta["packages"],
                      preference_stacks(union_manifest.parent, info, bootstrap))
    if sha(union_manifest) != meta["source_manifest_sha256"]:
        raise Rejected("profile union Manifest differs from recorded build source")
    if sha(union_manifest.parent / "Project.toml") != meta["source_project_sha256"]:
        raise Rejected("profile union Project differs from recorded build source")
    root = CITY / ".gc/kaimon-sysimages/profiles"
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".publishing-", dir=root))
    sources = {"Manifest.toml": union_manifest, "Project.toml": union_manifest.parent / "Project.toml",
               "source-paths.toml": Path(args.path_map).resolve()}
    for name, path in sources.items():
        shutil.copyfile(path, staging / name)
    if sha(staging / "Manifest.toml") != meta["source_manifest_sha256"] or sha(staging / "Project.toml") != meta["source_project_sha256"]:
        raise Rejected("profile build source changed while copying")
    payload = {"schema": SCHEMA, "artifact_id": meta["id"], "artifact": str(artifact),
               "artifact_root": str(artifact.parent), "julia_bin": info["binary"],
               "julia_version": info["version"], "bootstrap_projects": list(map(str, bootstrap)),
               "files": {name: sha(staging / name) for name in sources}}
    profile_id = hashlib.sha256(canonical(payload)).hexdigest()
    payload["profile_id"] = profile_id
    (staging / "profile.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    final = root / profile_id
    if final.exists():
        load_profile(final / "profile.json")
        shutil.rmtree(staging)
    else:
        staging.rename(final)
    # Publication alone leaves the active profile untouched. Activation/rollback
    # is a separate explicit atomic pointer change after review/native gates.
    print(json.dumps({"profile": str(final / "profile.json"), "artifact_id": meta["id"]}, indent=2))


def selection_configuration(root=None, profile_file=None, artifact=None):
    root = root if root is not None else os.environ.get("KAIMON_SYSIMAGE_ROOT")
    profile = load_profile(profile_file)
    if artifact:
        path = Path(artifact).resolve()
        profile = dict(profile or {}, artifact=str(path), artifact_id=path.name,
                       artifact_root=str(path.parent))
    resolved_root = Path(root).resolve() if root else Path(profile["artifact_root"] if profile else DEFAULT_ROOT)
    if profile and resolved_root != Path(profile["artifact_root"]):
        if profile_file or artifact:
            raise Rejected("explicit profile/artifact disagrees with explicit artifact root")
        profile = None  # an explicit isolated cache root does not inherit another profile
    return resolved_root, profile


def effective_bootstrap_projects(project, info, profile=None, configured=()):
    """Locate the actual managed gate from the target/LOAD_PATH, not a safety opt-in."""
    candidates = []
    config = read_toml(Path(project) / "Project.toml")
    if config.get("uuid") == GATE_UUID:
        candidates.append(Path(project))
    if config.get("deps", {}).get("KaimonGate") == GATE_UUID:
        entry = entries(read_toml(manifest_path(project, info["version"]))).get("KaimonGate", {})
        if "path" in entry:
            candidates.append(Path(project) / entry["path"])
    # A configured base wrapper may rewrite LOAD_PATH; its runtime probe reports
    # that stack too. Validate it in addition to the managed parent's stack.
    load_paths = list(info.get("load_path", [])) + os.environ.get("JULIA_LOAD_PATH", "").split(os.pathsep)
    for item in load_paths:
        if item and not item.startswith("@"):
            candidates.append(Path(item))
    candidates += [Path(p) for p in (profile or {}).get("bootstrap_projects", [])]
    candidates += [Path(p) for p in configured]
    gate = []
    for path in candidates:
        file = path / "Project.toml"
        if file.is_file() and read_toml(file).get("uuid") == GATE_UUID:
            resolved = path.resolve()
            if resolved not in gate:
                gate.append(resolved)
    if not gate:
        # Only inspect this known installed package directory, never registry secrets.
        installed = CITY / ".gc/kaimon-canary/julia_depot/packages/KaimonGate"
        if installed.is_dir():
            for path in installed.iterdir():
                file = path / "Project.toml"
                if file.is_file() and read_toml(file).get("uuid") == GATE_UUID:
                    gate.append(path.resolve())
    if not gate:
        raise Rejected("cannot locate actual KaimonGate bootstrap environment; refusing unchecked image")
    return gate


def manifest_path(project, version):
    """Match Julia's preference for a version-specific manifest."""
    series = ".".join(version.split(".")[:2])
    for name in (f"JuliaManifest-v{series}.toml", f"Manifest-v{series}.toml",
                 "JuliaManifest.toml", "Manifest.toml"):
        candidate = Path(project) / name
        if candidate.is_file():
            return candidate
    raise Rejected(f"no pinned Manifest for Julia {series} in {project}")


def entries(manifest):
    result = {}
    for name, values in manifest.get("deps", {}).items():
        if len(values) != 1:
            raise Rejected(f"ambiguous manifest package {name}")
        result[name] = values[0]
    return result


def external_graph(manifest, packages, project):
    """Conservatively include present weak deps/extensions and all hard deps."""
    all_entries = entries(manifest)
    selected = {}
    pending = list(packages)
    editable = EDITABLE | {project.get("name", "")}
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        if name not in all_entries:
            raise Rejected(f"manifest lacks dependency {name}")
        entry = all_entries[name]
        if name in editable or "path" in entry:
            raise Rejected(f"editable/path dependency cannot be baked: {name}")
        # A non-stdlib source must have an immutable tree identity.
        if "repo-url" in entry and "git-tree-sha1" not in entry:
            raise Rejected(f"unpinned repository source: {name}")
        selected[name] = entry
        pending.extend(entry.get("deps", []))
        weak = entry.get("weakdeps", {})
        pending.extend(n for n in weak if n in all_entries)
    return selected


def run_julia(binary, code, *args, env=None, preserve_load_path=False, project=None):
    env = dict(os.environ if env is None else env)
    env.pop("JULIA_PROJECT", None)
    if not preserve_load_path:
        env["JULIA_LOAD_PATH"] = "@stdlib"
    project_flags = [f"--project={project}"] if project else []
    completed = subprocess.run([str(binary), "--startup-file=no", "--history-file=no",
                                *project_flags, "-e", code, *map(str, args)],
                               check=True, capture_output=True, text=True, env=env)
    return completed.stdout


def runtime(binary, project=None):
    code = '''original_load_path = copy(LOAD_PATH)
pushfirst!(LOAD_PATH, "@stdlib")
using TOML
TOML.print(Dict("version"=>string(VERSION), "machine"=>Sys.MACHINE,
 "commit"=>string(Base.GIT_VERSION_INFO.commit),
 "binary"=>realpath(joinpath(Sys.BINDIR, "julia")),
 "load_path"=>original_load_path,
 "base_image"=>unsafe_string(Base.JLOptions().image_file)))'''
    data = tomllib.loads(run_julia(binary, code, preserve_load_path=True, project=project))
    for key in ("binary", "base_image"):
        data[key + "_sha256"] = sha(data[key])
    return data


def runtime_identity(data):
    return {k: v for k, v in data.items() if k not in ("binary", "base_image", "load_path")}


def require_runtime(info, requested):
    if not requested:
        return
    parts = requested.split(".")
    if not all(part.isdigit() for part in parts) or not 1 <= len(parts) <= 3:
        raise Rejected(f"cannot verify requested Julia version {requested!r}")
    actual = info["version"].split(".")
    if actual[:len(parts)] != parts:
        raise Rejected(f"requested Julia {requested} but launcher selected {info['version']}")


def preference_stacks(project, info, stack_projects=()):
    """Audit ordered caller, actual base-wrapper, and managed bootstrap stacks."""
    defaults = ["@", "@v#.#", "@stdlib"]
    caller = []
    raw = os.environ.get("JULIA_LOAD_PATH")
    for entry in ([] if raw == "" else (raw.split(os.pathsep) if raw is not None else defaults)):
        for item in defaults if not entry else [entry]:
            item = os.path.expanduser(item)
            if item not in caller:
                caller.append(item)
    actual = list(info.get("load_path", caller))
    managed = actual + [str(path) for path in stack_projects if str(path) not in actual]
    stacks = []
    for stack in (caller, actual, managed):
        stack = [str(Path(project).resolve()) if item == "@" else item for item in stack]
        if stack not in stacks:
            stacks.append(stack)
    return stacks


def preference_identity(packages):
    ids = sorted({entry["uuid"] for entry in packages.values()})
    extensions = sorted([entry["uuid"], name] for entry in packages.values()
                        for name in entry.get("extensions", {}))
    empty = {"packages": {id: {} for id in ids}, "extensions": [[*ext, {}] for ext in extensions]}
    return {"schema": 1, "policy": PREFERENCE_POLICY, "queried_uuids": ids,
            "extensions": extensions, "effective_sha256": hashlib.sha256(canonical(empty)).hexdigest()}


def preference_arguments(packages, stacks):
    ids = sorted({entry["uuid"] for entry in packages.values()})
    request = "stacks = " + json.dumps(stacks, ensure_ascii=False)
    request += "\nextensions = " + json.dumps(preference_identity(packages)["extensions"], ensure_ascii=False)
    return [len(ids), *ids, request]


def require_empty_preferences(audit, packages):
    if any(audit.get(key) != value for key, value in preference_identity(packages).items()):
        raise Rejected("invalid or incompatible compile-time preference identity")
    if audit.get("failed"):
        raise Rejected("cannot audit baked-package preferences")
    if len(audit.get("queried_extension_uuids", [])) != len(preference_identity(packages)["extensions"]):
        raise Rejected("incomplete extension preference audit")
    contexts = audit.get("contexts")
    if not isinstance(contexts, list) or not contexts:
        raise Rejected("missing effective preference audit")
    by_uuid = {entry["uuid"]: name for name, entry in packages.items()}
    for context in contexts:
        if context.get("nonempty_uuids"):
            names = ", ".join(sorted(by_uuid.get(id, id) for id in context["nonempty_uuids"]))
            raise Rejected(f"non-default preferences for baked package(s) {names}; "
                           "use normal Julia (city_sysimage mode=off); this image requires empty preferences")
        if context.get("empty") is not True:
            raise Rejected("compile-time preferences were not audited empty")


def freeze_preference_audit(audit, staging):
    # Temporary staging names must not make otherwise identical build IDs vary.
    def freeze(value):
        if isinstance(value, dict):
            return {freeze(key): freeze(item) for key, item in value.items()}
        if isinstance(value, list):
            return [freeze(item) for item in value]
        if isinstance(value, str) and value.startswith(str(staging) + os.sep):
            return "$ARTIFACT/" + value[len(str(staging)) + 1:]
        return value
    return freeze(audit)


def audit_preferences(binary, packages, stacks, *, env=None, script=None):
    script = script or HERE / "kaimon-sysimage-preferences.jl"
    try:
        output = run_julia(binary, "include(popfirst!(ARGS)); TOML.print(preference_audit(ARGS);sorted=true)",
                           script, *preference_arguments(packages, stacks), env=env)
    except subprocess.CalledProcessError as error:
        raise Rejected("cannot audit baked-package preferences") from error
    audit = dict(preference_identity(packages), **tomllib.loads(output))
    require_empty_preferences(audit, packages)
    return audit


def dependency_closure(pins, roots):
    selected = {}
    pending = list(roots)
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        if name not in pins:
            raise Rejected(f"bootstrap Manifest lacks {name}")
        selected[name] = pins[name]
        pending.extend(pins[name].get("deps", []))
    return selected


def validate_project(project, info, metadata, *, bootstrap=False):
    """Reject overlapping baked sources; extra union members may be absent.

    Bootstrap environments are validated only through their actual direct/hard
    dependency closure, never their unrelated server Manifest entries.
    """
    project = Path(project).resolve()
    config = read_toml(project / "Project.toml")
    pins = entries(read_toml(manifest_path(project, info["version"])))
    if bootstrap:
        pins = dependency_closure(pins, config.get("deps", {}))
    baked = metadata["packages"]
    by_uuid = {entry["uuid"]: (name, entry) for name, entry in pins.items()}
    for name, expected in baked.items():
        if config.get("uuid") == expected["uuid"]:
            raise Rejected(f"project itself is baked: {name}")
        override = config.get("sources", {}).get(name, {})
        if override:
            # An explicit immutable source is also how a reviewed compatibility
            # fork is recorded. Accept only the very same full Git revision in
            # Project, Manifest and image; paths and floating refs stay refused.
            revision = expected.get("repo-rev", "")
            locked = by_uuid.get(expected["uuid"], (None, {}))[1]
            source = {"url": expected.get("repo-url"), "rev": revision}
            if not (source["url"] and len(revision) == 40 and
                    all(c in "0123456789abcdef" for c in revision.lower()) and
                    expected.get("git-tree-sha1") and override == source and
                    locked.get("repo-url") == source["url"] and
                    locked.get("repo-rev") == revision):
                raise Rejected(f"Project source override for baked dependency {name}")
        if expected["uuid"] not in by_uuid:
            continue
        target_name, actual = by_uuid[expected["uuid"]]
        if target_name != name or "path" in actual:
            raise Rejected(f"local development override/name mismatch: {name}")
        for key in ("version", "git-tree-sha1"):
            if actual.get(key) != expected.get(key):
                raise Rejected(f"Manifest {key} mismatch: {name}")
    return project


def validate_artifact(directory, info, project, stack_projects=()):
    directory = Path(directory).resolve()
    meta = json.loads((directory / "metadata.json").read_text())
    if meta.get("schema") != SCHEMA:
        raise Rejected("unknown artifact schema")
    spec_hash = hashlib.sha256(canonical(meta["spec"])).hexdigest()
    if meta["id"] != spec_hash or directory.name != spec_hash:
        raise Rejected("stale artifact identity")
    if runtime_identity(info) != meta["spec"]["runtime"]:
        raise Rejected("incompatible Julia binary/build/base sysimage")
    if meta["spec"]["platform"] != [sys.platform, platform.machine()]:
        raise Rejected("incompatible runtime platform")
    if meta["spec"]["cpu_target"] != "generic":
        raise Rejected("unsupported CPU target; rebuild with generic")
    if meta["inputs"] != meta["spec"]["inputs"]:
        raise Rejected("stale build input inventory")
    for name, digest in meta["inputs"].items():
        path = directory / name
        if not path.is_file() or sha(path) != digest:
            raise Rejected(f"stale/tampered build input: {name}")
    frozen = entries(read_toml(directory / "dependencies/Manifest.toml"))
    if meta["packages"] != frozen:
        raise Rejected("package provenance differs from frozen build Manifest")
    if (meta["spec"].get("preferences") != preference_identity(frozen) or
            "preferences.json" not in meta["inputs"]):
        raise Rejected("image lacks an audited compile-time preference policy; rebuild required")
    preferences = json.loads((directory / "preferences.json").read_text())
    require_empty_preferences(preferences, frozen)
    image = directory / "image.dylib"
    if sha(image) != meta["image_sha256"]:
        raise Rejected("image checksum mismatch")
    validate_project(project, info, meta)
    for environment in stack_projects:
        try:
            validate_project(environment, info, meta, bootstrap=True)
        except Rejected as error:
            raise Rejected(f"bootstrap environment {environment}: {error}") from error
    return image, meta


def select_image(root, project, info, stack_projects=(), profile=None):
    """Only published hash directories are candidates; staging dirs stay invisible."""
    failures = []
    if profile:
        candidates = [Path(profile["artifact"]) / "metadata.json"]
    else:
        candidates = sorted(p for p in Path(root).glob("*/metadata.json")
                            if len(p.parent.name) == 64)
    selected = None
    for path in candidates:
        try:
            image, meta = validate_artifact(path.parent, info, project, stack_projects)
            if profile and meta["id"] != profile["artifact_id"]:
                raise Rejected("selected metadata does not match intended profile artifact")
            if selected is not None:
                failures.append("multiple compatible artifacts without an active profile; selection is ambiguous")
                return None, None, failures
            selected = (image, meta)
        except (Rejected, OSError, KeyError, ValueError) as error:
            failures.append(f"{path.parent.name[:12]}: {error}")
    return (*selected, failures) if selected else (None, None, failures)


def julia_arguments(args):
    project = None
    explicit_image = False
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("--", "-e", "--eval", "-E", "--print", "-L", "--load"):
            break
        if arg in ("--project",):
            i += 1
            if i >= len(args):
                raise Rejected("--project requires an explicit path")
            project = args[i]
        elif arg.startswith("--project="):
            project = arg.partition("=")[2]
        elif arg in ("-J", "--sysimage") or arg.startswith(("-J", "--sysimage=")):
            explicit_image = True
        i += 1
    if not project or project.startswith("@"):
        return None, explicit_image
    return Path(project).resolve(), explicit_image


def test_project_hint(args):
    """Kaimon run_tests passes script.jl, exact project, pattern, verbose.

    This hint chooses the original binary/recipe only. Never inject an image:
    the script activates its own test environment after Julia has started.
    """
    for index, value in enumerate(args[:-1]):
        if value.endswith(".jl") and Path(value).is_file():
            candidate = Path(args[index + 1])
            if (candidate / "Project.toml").is_file():
                return candidate.resolve()
            break
    return None


def launch(args, execute=os.execv):
    project, explicit_image = julia_arguments(args)
    recipe_project = project or test_project_hint(args)
    recipe_path = recipe_project / "kaimon.toml" if recipe_project else None
    document = read_toml(recipe_path) if recipe_path and recipe_path.exists() else {}
    recipe = document.get("city_sysimage", {})
    mode = os.environ.get("KAIMON_SYSIMAGE_MODE", recipe.get("mode", "auto"))
    if mode not in ("off", "auto", "required"):
        raise Rejected(f"invalid city_sysimage mode: {mode}")
    base_binary = os.environ.get("KAIMON_SYSIMAGE_JULIA", recipe.get("julia_bin", ""))
    profile_error = None
    root, profile = DEFAULT_ROOT, None
    if mode != "off" or not base_binary:
        try:
            root, profile = selection_configuration(
                os.environ.get("KAIMON_SYSIMAGE_ROOT", recipe.get("artifact_root")),
                recipe.get("profile"), recipe.get("artifact"))
        except (Rejected, OSError, ValueError, KeyError) as error:
            profile_error = error
    binary = base_binary or (profile or {}).get("julia_bin", "")
    if not binary:
        raise Rejected("set [city_sysimage].julia_bin to the original Julia binary/wrapper")
    binary = str(Path(binary).expanduser().resolve())
    if Path(binary) == Path(__file__).resolve():
        raise Rejected("recursive sysimage launcher")
    flags = list(args)
    status = "off" if mode == "off" else "explicit caller image" if explicit_image else "no exact project"
    requested = recipe.get("julia_version", document.get("launch", {}).get("julia_version", ""))
    info = None
    if requested:
        info = runtime(binary, project)
        try:
            require_runtime(info, requested)
        except Rejected as error:
            os.environ["KAIMON_CITY_SYSIMAGE"] = "rejected: " + str(error)
            print(f"[city-sysimage] {error}; refusing runtime substitution", file=sys.stderr)
            return 78
    if project is None:
        print("[city-sysimage] no exact --project; forwarding original Julia arguments", file=sys.stderr)
    cache_policy = any(flag in ("--compiled-modules=no", "--compiled-modules=existing") for flag in args)
    if cache_policy and not explicit_image:
        status = "off: caller cache policy"
        if mode == "required":
            os.environ["KAIMON_CITY_SYSIMAGE"] = status
            print("[city-sysimage] required image conflicts with caller cache policy", file=sys.stderr)
            return 78
    if project is not None and mode != "off" and not explicit_image and not cache_policy:
        try:
            if profile_error:
                raise Rejected(str(profile_error))
            info = info or runtime(binary, project)
            stack_projects = effective_bootstrap_projects(project, info, profile, recipe.get("bootstrap_projects", []))
            image, metadata, failures = select_image(root, project, info, stack_projects, profile)
            if image is None:
                raise Rejected("; ".join(failures) or "no published compatible dependency image")
            # Julia validates direct Project compat with its own version grammar.
            check_project_compat(binary, project, info, metadata, stack_projects)
            flags.insert(0, f"--sysimage={image}")
            status = metadata["id"]
            print(f"[city-sysimage] selected {metadata['id']} ({info['version']})", file=sys.stderr)
        except (Rejected, OSError, ValueError, subprocess.CalledProcessError) as error:
            status = "rejected: " + str(error)
            print(f"[city-sysimage] {status}; " + ("required image unavailable" if mode == "required" else "normal Julia fallback"), file=sys.stderr)
            if mode == "required":
                os.environ["KAIMON_CITY_SYSIMAGE"] = status
                return 78
    os.environ["KAIMON_CITY_SYSIMAGE"] = status
    execute(binary, [binary, *flags])
    return 0


def check_project_compat(binary, project, info, metadata=None, stack_projects=()):
    code = '''import Pkg, TOML, SHA
Pkg.is_manifest_current(ARGS[1]) === true || error("stale Project/Manifest; prepare or resolve before image selection")
manifest = TOML.parsefile(ARGS[2])
m = manifest["deps"]
projects = [joinpath(ARGS[1], "Project.toml")]
recorded = get(manifest,"city_path_project_hashes",Dict())
for (file,digest) in get(manifest,"city_workspace_project_hashes",Dict())
    bytes2hex(SHA.sha256(read(joinpath(ARGS[1],file)))) == digest ||
        error("stale workspace Project hash: " * file)
end
for (package,entries) in m
    e = only(entries)
    haskey(e,"path") || continue
    source_project = joinpath(ARGS[1],e["path"],"Project.toml")
    haskey(recorded,package) || error("missing path-source Project hash: " * package)
    receipt = recorded[package]
    receipt["uuid"] == e["uuid"] && receipt["path"] == e["path"] &&
        receipt["sha256"] == bytes2hex(SHA.sha256(read(source_project))) ||
        error("stale path-source Project hash: " * package)
    push!(projects,source_project)
end
for file in unique(projects)
    p = Pkg.Types.read_project(file)
    for (name, compat) in p.compat
        if name == "julia"
            VERSION in compat.val || error("Project Julia compat mismatch: " * file)
        elseif haskey(p.deps, name) && haskey(m, name)
            e = only(m[name])
            haskey(e, "version") && !(VersionNumber(e["version"]) in compat.val) &&
                error("Project/Manifest compat mismatch: " * name * " in " * file)
        end
    end
end'''
    arguments = [project, manifest_path(project, info["version"])]
    if metadata is not None:
        # Import Pkg safely first; preference resolution then uses the actual
        # caller/base-wrapper/bootstrap stacks in this same lightweight process.
        code += "\ntry; include(ARGS[3]); TOML.print(preference_audit(ARGS[4:end]);sorted=true); " \
                "catch; error(\"cannot audit baked-package preferences\"); end"
        arguments += [HERE / "kaimon-sysimage-preferences.jl",
                      *preference_arguments(metadata["packages"], preference_stacks(project, info, stack_projects))]
    try:
        output = run_julia(binary, code, *arguments)
    except subprocess.CalledProcessError as error:
        raise Rejected(error.stderr.strip()) from error
    if metadata is not None:
        audit = dict(preference_identity(metadata["packages"]), **tomllib.loads(output))
        require_empty_preferences(audit, metadata["packages"])
        return audit


def inventory(root):
    report = {}
    names = ["DeRham.jl", "NewtonExperiments", "GPUFiniteFieldMatrices.jl", "EdgeIdeals.jl",
             "MMPSingularities.jl", "GPUPolynomials.jl", "CudaNTTs.jl", "Nemo.jl"]
    for name in names:
        directory = Path(root) / name
        item = {"path": str(directory), "files": {}, "manifests": {}}
        for path in sorted(directory.glob("*toml")):
            if path.name in ("Project.toml", "kaimon.toml") or path.name.startswith("Manifest"):
                data = read_toml(path)
                item["files"][path.name] = sha(path)
                if path.name.startswith("Manifest"):
                    item["manifests"][path.name] = data
                else:
                    item[path.stem] = data
        report[name] = item
    return report


def prepare(args):
    project = Path(args.project).resolve()
    owner = Path(args.owned_root).resolve()
    if not project.is_relative_to(owner) or owner == Path("/"):
        raise Rejected("project must be inside the explicitly supplied task-owned root")
    if not any(part in (".gc", "worktrees") for part in owner.parts):
        raise Rejected("prepare is limited to isolated city task/worktree directories")
    shared_roots = {CITY.resolve(), *(CITY.resolve() / name for name in
                    (".gc", ".gc/worktrees", "worktrees", ".gc/agents", ".gc/kaimon-sysimages"))}
    if owner in shared_roots or owner.name in (".gc", "worktrees"):
        raise Rejected("owned root must name one task, not a shared city/worktree container")
    manifest = Path(args.union_manifest).resolve()
    info = runtime(args.julia)
    source_version = read_toml(manifest)["julia_version"]
    if source_version != info["version"]:
        raise Rejected(f"union Manifest Julia {source_version} differs from {info['version']}")
    series = ".".join(info["version"].split(".")[:2])
    files = [project / "Project.toml", project / f"Manifest-v{series}.toml"]
    if (project / f"JuliaManifest-v{series}.toml").exists():
        raise Rejected("existing JuliaManifest versioned file would override generated Manifest")
    for path in files:
        if path.is_symlink():
            raise Rejected(f"refusing symlinked preparation target: {path}")
    # Keep exact byte backups outside repository source; restore on any failure.
    backup_root = CITY / ".gc/kaimon-sysimages/prepare-backups"
    backup_root.mkdir(parents=True, exist_ok=True)
    receipts = backup_root / "receipts"
    receipts.mkdir(exist_ok=True)
    receipt = receipts / (hashlib.sha256(str(project).encode()).hexdigest() + ".json")
    if files[1].exists() and not args.replace_existing:
        if not receipt.exists():
            raise Rejected("existing versioned Manifest has no tool receipt; explicit --replace-existing is required")
        previous = json.loads(receipt.read_text())
        if previous.get("project") != str(project) or previous.get("manifest_sha256") != sha(files[1]):
            raise Rejected("existing versioned Manifest differs from tool receipt; preserve it or use explicit --replace-existing")
    backup = Path(tempfile.mkdtemp(prefix="alignment-", dir=backup_root))
    before = {p: p.read_bytes() if p.exists() else None for p in files}
    disposition = {
        "project": str(project), "union_manifest": str(manifest),
        "union_manifest_sha256": sha(manifest), "julia": info,
        "changes": "align local source paths explicitly and write version-specific union Manifest",
        "files": {str(p): value is not None for p,value in before.items()}, "status": "pending"}
    (backup / "disposition.json").write_text(json.dumps(disposition, indent=2) + "\n")
    for path, value in before.items():
        if value is not None:
            (backup / path.name).write_bytes(value)
    print(f"Aligning owned Project sources and {files[1]}; exact rollback backup: {backup}", flush=True)
    try:
        setup_env = os.environ.copy()
        setup_env.pop("JULIA_PROJECT", None)
        setup_env["JULIA_LOAD_PATH"] = "@stdlib"
        subprocess.run([args.julia, "--startup-file=no",
                        str(HERE / "kaimon-sysimage-prepare.jl"), str(project), str(manifest),
                        str(Path(args.path_map).resolve()) if args.path_map else "", str(owner)],
                       check=True, env=setup_env)
        check_project_compat(args.julia, project, info)
        if args.artifact:
            validate_artifact(args.artifact, info, project)
    except BaseException:
        for path, value in before.items():
            if value is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(value)
        disposition["status"] = "failed; original target bytes restored"
        (backup / "disposition.json").write_text(json.dumps(disposition, indent=2) + "\n")
        raise
    result = {"project": str(project), "manifest": str(files[1]), "project_sha256": sha(files[0]),
              "manifest_sha256": sha(files[1]), "rollback_backup": str(backup), "status": "prepared"}
    project_diff = "".join(difflib.unified_diff(before[files[0]].decode().splitlines(True),
                                             files[0].read_text().splitlines(True),
                                             fromfile="original/Project.toml", tofile="prepared/Project.toml"))
    (backup / "Project.diff").write_text(project_diff)
    result["project_diff"] = str(backup / "Project.diff")
    disposition.update(result)
    (backup / "disposition.json").write_text(json.dumps(disposition, indent=2) + "\n")
    temporary = receipt.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(receipt)
    print(json.dumps(result, indent=2))


def write_dependencies(directory, source, graph, packages):
    directory.mkdir()
    lines = ["[deps]"]
    lines.extend(f'{json.dumps(n)} = {json.dumps(graph[n]["uuid"])}' for n in packages)
    lines.append("\n[compat]")
    lines.extend(f'{json.dumps(n)} = {json.dumps("=" + graph[n]["version"].split("+")[0])}'
                 for n in packages if "version" in graph[n])
    (directory / "Project.toml").write_text("\n".join(lines) + "\n")


def build(args):
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    project = Path(args.project).resolve()
    info = runtime(args.julia)
    source_path = manifest_path(project, info["version"])
    source = read_toml(source_path)
    packages = sorted(set(args.packages.split(",")))
    graph = external_graph(source, packages, read_toml(project / "Project.toml"))
    staging = Path(tempfile.mkdtemp(prefix=".building-", dir=root))
    started = time.monotonic()
    # Always keep task-owned logs on failure; never publish an incomplete artifact.
    print(f"staging={staging}", flush=True)
    dependencies = staging / "dependencies"
    write_dependencies(dependencies, source, graph, packages)
    # Copy complete selected tables, including nested extension/weakdep tables.
    text = source_path.read_text()
    import re
    chunks = re.split(r"(?=^\[\[deps\.)", text, flags=re.MULTILINE)
    kept = []
    for chunk in chunks[1:]:
        match = re.match(r'\[\[deps\.([^\]]+)\]\]', chunk)
        if match and match[1].strip('"') in graph:
            kept.append(chunk)
    header = f'julia_version = {json.dumps(source["julia_version"])}\nmanifest_format = "2.0"\n\n'
    (dependencies / "Manifest.toml").write_text(header + "".join(kept))
    tools = staging / "tools"
    tools.mkdir()
    (tools / "Project.toml").write_text(
        '[deps]\nPackageCompiler = "9b87118b-4619-50d2-8e1e-99f35a4d4d9d"\n'
        f'\n[compat]\nPackageCompiler = "={args.packagecompiler}"\n')
    if args.tools_manifest:
        shutil.copyfile(args.tools_manifest, tools / "Manifest.toml")
    for filename in ("kaimon-sysimage-build.jl", "kaimon-sysimage-workload.jl",
                     "kaimon-sysimage-preferences.jl"):
        shutil.copyfile(HERE / filename, staging / filename)
    env = os.environ.copy()
    # Do not write compilation/install output to a service-owned depot.
    depot = Path(args.depot).resolve() if args.depot else root / "depot"
    depot.mkdir(parents=True, exist_ok=True)
    env["JULIA_DEPOT_PATH"] = str(depot) + os.pathsep + env.get("JULIA_DEPOT_PATH", "")
    pref_script = staging / "kaimon-sysimage-preferences.jl"
    # Reject source preferences before instantiation can discard them.
    audit_preferences(args.julia, graph, preference_stacks(project, info), env=env, script=pref_script)
    with (staging / "build.log").open("w") as log:
        def command(argv):
            subprocess.run(list(map(str, argv)), env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        for environment in (tools, dependencies):
            command([args.julia, "--startup-file=no", f"--project={environment}", "-e",
                     "import Pkg; Pkg.instantiate(;allow_autoprecomp=false)"])
        tools_pins = entries(read_toml(tools / "Manifest.toml"))
        if tools_pins["PackageCompiler"]["version"] != args.packagecompiler:
            raise Rejected("PackageCompiler version differs from requested pin")
        # PackageCompiler 2.4.3 traces/serializes with [dependencies, @stdlib].
        preferences = audit_preferences(args.julia, graph, [[str(dependencies), "@stdlib"]],
                                        env=env, script=pref_script)
        (staging / "preferences.json").write_text(json.dumps(freeze_preference_audit(preferences, staging),
                                                           indent=2, sort_keys=True) + "\n")
        inputs = {str(p.relative_to(staging)): sha(p) for p in [
            tools / "Project.toml", tools / "Manifest.toml", dependencies / "Project.toml",
            dependencies / "Manifest.toml", staging / "kaimon-sysimage-build.jl",
            staging / "kaimon-sysimage-workload.jl", pref_script, staging / "preferences.json"]}
        spec = {"schema": SCHEMA, "runtime": runtime_identity(info),
                "platform": [sys.platform, platform.machine()], "cpu_target": "generic",
                "roots": packages, "inputs": inputs, "packagecompiler": args.packagecompiler,
                "preferences": preference_identity(graph)}
        identity = hashlib.sha256(canonical(spec)).hexdigest()
        (staging / "build-spec.json").write_text(json.dumps({"id": identity, "spec": spec},
                                                          indent=2, sort_keys=True) + "\n")
        final = root / identity
        if final.exists():
            validate_artifact(final, info, dependencies)
            print(f"existing={final}")
            shutil.rmtree(staging)
            return
        command([args.julia, "--startup-file=no", f"--project={tools}",
                 staging / "kaimon-sysimage-build.jl", dependencies, staging / "image.dylib",
                 staging / "kaimon-sysimage-workload.jl", "generic", *packages])
        # Inspect exactly what Julia serialized, not just the requested roots.
        probe = '''using TOML
d = Dict{String,Any}()
for (id, mod) in Base.loaded_modules
    id.uuid === nothing && continue
    path = pathof(mod)
    path === nothing && continue
    occursin("/stdlib/", path) && continue
    d[string(id.uuid)] = Dict("name"=>id.name, "uuid"=>string(id.uuid), "path"=>path,
                     "version"=>string(something(Base.pkgversion(mod), "")))
end
TOML.print(d)'''
        loaded = subprocess.run([args.julia, "--startup-file=no", f"--sysimage={staging / 'image.dylib'}",
                                 f"--project={dependencies}", "-e", probe],
                                check=True, env=env, capture_output=True, text=True)
        baked = tomllib.loads(loaded.stdout)
        final_preferences = audit_preferences(args.julia, graph, [[str(dependencies), "@stdlib"]],
                                              env=env, script=pref_script)
        if final_preferences != preferences:
            raise Rejected("effective build preference inputs changed during compilation")
        for entry in baked.values():
            name = entry["name"]
            # Extension modules have deterministic IDs of their own; record them
            # but validate their owning package and weak deps through the full graph.
            if name not in graph and not any(name in e.get("extensions", {}) for e in graph.values()):
                raise Rejected(f"unexpected package baked outside pinned graph: {name}")
        for name, digest in inputs.items():
            if sha(staging / name) != digest:
                raise Rejected(f"build mutated frozen input: {name}")
        metadata = {"schema": SCHEMA, "id": identity, "spec": spec, "inputs": inputs,
                    "packages": entries(read_toml(dependencies / "Manifest.toml")),
                    "loaded_modules": baked, "image_sha256": sha(staging / "image.dylib"),
                    "size_bytes": (staging / "image.dylib").stat().st_size,
                    "build_seconds": time.monotonic() - started,
                    "build_depot": str(depot),
                    "source_project": str(project), "source_manifest_sha256": sha(source_path),
                    "source_project_sha256": sha(project / "Project.toml"), "julia": info}
        (staging / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    # Same-filesystem rename publishes the image and provenance together atomically.
    staging.rename(final)
    print(f"published={final}\nsize_bytes={metadata['size_bytes']}\nbuild_seconds={metadata['build_seconds']:.3f}")


def main():
    if Path(sys.argv[0]).name == "kaimon-sysimage-julia":
        return launch(sys.argv[1:])
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    inv = sub.add_parser("inventory")
    inv.add_argument("--projects-root", required=True)
    inv.add_argument("--output", required=True)
    builder = sub.add_parser("build")
    builder.add_argument("--project", required=True)
    builder.add_argument("--julia", required=True)
    builder.add_argument("--packages", required=True)
    builder.add_argument("--root")
    builder.add_argument("--packagecompiler", default="2.4.3")
    builder.add_argument("--tools-manifest", help="replay an artifact's pinned tools/Manifest.toml")
    builder.add_argument("--depot", help="owned isolated build cache, independent of normal-load diagnostics")
    alignment = sub.add_parser("prepare")
    alignment.add_argument("--project", required=True)
    alignment.add_argument("--union-manifest")
    alignment.add_argument("--julia")
    alignment.add_argument("--artifact", help="require the prepared target to pass this artifact's compatibility checks")
    alignment.add_argument("--profile", help="published profile override, including deliberate rollback")
    alignment.add_argument("--owned-root", required=True)
    alignment.add_argument("--path-map", help="TOML mapping of editable dependency names to owned paths")
    alignment.add_argument("--replace-existing", action="store_true",
                           help="explicitly back up and replace a versioned Manifest without a matching tool receipt")
    for name in ("check", "select"):
        check = sub.add_parser(name)
        check.add_argument("--project", required=True)
        check.add_argument("--julia", required=True)
        check.add_argument("--root")
        check.add_argument("--profile")
        check.add_argument("--artifact", help="explicit artifact override instead of current profile")
        check.add_argument("--bootstrap-project", action="append", default=[])
        check.add_argument("--requested-julia", default="")
    publication = sub.add_parser("publish-profile")
    publication.add_argument("--artifact", required=True)
    publication.add_argument("--union-manifest", required=True)
    publication.add_argument("--path-map", required=True)
    publication.add_argument("--julia", required=True)
    publication.add_argument("--bootstrap-project", action="append", default=[])
    activation = sub.add_parser("activate")
    activation.add_argument("--profile", required=True)
    args = parser.parse_args()
    if args.command == "inventory":
        Path(args.output).write_text(json.dumps(inventory(args.projects_root), indent=2, sort_keys=True) + "\n")
    elif args.command == "build":
        if not args.root:
            active = load_profile()
            args.root = (active or {}).get("artifact_root", str(DEFAULT_ROOT))
        build(args)
    elif args.command == "prepare":
        profile = load_profile(args.profile)
        profile_root = Path(profile["_directory"]) if profile else DEFAULT_PROFILE.parent
        if args.path_map and Path(args.path_map).absolute() == DEFAULT_PROFILE.parent / "source-paths.toml":
            args.path_map = str(profile_root / "source-paths.toml")
        if not args.union_manifest:
            args.union_manifest = str(profile_root / "Manifest.toml")
        if not args.julia or not args.artifact:
            args.julia = args.julia or (profile or {}).get("julia_bin", "")
            args.artifact = args.artifact or (profile or {}).get("artifact")
        if not args.julia:
            raise Rejected("no published city profile; supply exact --julia and --union-manifest")
        prepare(args)
    elif args.command == "publish-profile":
        publish_profile(args)
    elif args.command == "activate":
        activate_profile(args.profile)
    else:
        root, profile = selection_configuration(args.root, args.profile, args.artifact)
        info = runtime(args.julia, args.project)
        require_runtime(info, args.requested_julia)
        bootstrap = effective_bootstrap_projects(args.project, info, profile, args.bootstrap_project)
        image, metadata, failures = select_image(root, args.project, info, bootstrap, profile)
        if image is None:
            raise Rejected("; ".join(failures) or "no image available")
        check_project_compat(args.julia, args.project, info, metadata, bootstrap)
        if args.command == "select":
            print(image)
        else:
            print(json.dumps({"image": str(image), "id": metadata["id"], "runtime": info}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Rejected, OSError, subprocess.CalledProcessError) as error:
        print(f"[city-sysimage] {error}", file=sys.stderr)
        sys.exit(1)
