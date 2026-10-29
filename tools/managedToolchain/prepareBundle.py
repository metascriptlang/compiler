#!/usr/bin/env python3
"""Assemble a full engine and runtime bundle from a prepared engine and a local Zig.

    prepareBundle.py --engine ENGINE_DIR --zig ZIG --output NEW_DIR [--target T ...]
    prepareBundle.py --bundle BUNDLE_DIR --shared-runtime OVERLAY_DIR [--shared-runtime ...] --output NEW_DIR

The engine is the verified component from prepareEngine.py. The bundle keeps its contents at the
root (bin/, lib/, notices/) and adds `runtime/`, the payload prepareRuntime.py writes with the
engine reached by `..`; the x86_64-windows-gnu and aarch64-windows-gnu runtimes are `runtime/windows/`, from
prepareWindowsRuntime.py, with the engine reached by `../..`. HOST, VERSION, FILES.sha256 and IDENTITY are rewritten over every file of
the bundle, and the source engine's identity is recorded in notices/bundle-provenance.json.

The x86_64-linux-gnu.2.31 and x86_64-windows-gnu runtimes also get the C++ overlay of prepareCppRuntime.py merged
into `runtime/`; the aarch64 and wasm32-wasi runtimes stay C only, and the receipt names them under `cOnlyTargets`.

`--bundle` adds the GNU shared-object profiles of prepareRuntime.py --shared to a prepared bundle without preparing
anything again: NEW_DIR is a clone of BUNDLE_DIR (never changed) plus the `<target>.so.cfg` and `<target>.so/` of each
OVERLAY_DIR under `runtime/`, one `runtime/notices/runtime-shared-provenance.json` that joins the overlays' receipts,
and a contract rewritten over every file. Every overlay must name the bundle's own runtime receipt, Zig and engine.

The bundle is a local proof, not an upstream-controlled build, and never certifies redistribution.
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw

ENGINE_RELATIVE = ".."
LINUX_ARCH_RUNTIME = re.compile(r"^(.+)-x86_64(\..+)$")
LINUX_TARGET = re.compile(r"^-target (x86_64-\S*linux\S*)$", re.MULTILINE)
SHARED_RECEIPT_KIND = "local-zig-runtime-shared-proof"
SHARED_RECEIPT_COMMON = ("kind", "statement", "redistributionCertified", "zig", "producerHost", "engineVersion",
                         "engineRelative", "baseRuntimeProvenanceSha256")


def splitTargets(targets):
    """(targets prepareRuntime.py makes, Windows targets prepareWindowsRuntime.py makes; none when no Windows
    target is named and others are). No target selects every target."""
    windows = [t for t in targets if t in pw.TARGETS]
    return [t for t in targets if t not in pw.TARGETS], windows if windows or not targets else []


def addTargetRuntimeDirectories(root, host, version, runtime):
    """On a Linux engine, give each x86_64 target triple a runtime directory the way clang looks for it:
    lib/clang/MAJOR/lib/TRIPLE/libclang_rt.NAME.EXT beside the distribution's lib/linux/libclang_rt.NAME-x86_64.EXT.
    The triples are the ones the runtime configs name, because clang spells the directory from -target.
    Returns the directories made, relative to root."""
    if host != pe.LINUX_X64:
        return []
    triples = set()
    for name in sorted(os.listdir(runtime)):
        path = os.path.join(runtime, name)
        if name.endswith(".cfg") and os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                triples.update(LINUX_TARGET.findall(f.read()))
    if not triples:
        return []
    flat = os.path.join(root, "lib", "clang", version.split(".")[0], "lib", "linux")
    sources = {}
    for name in sorted(os.listdir(flat)):
        match = LINUX_ARCH_RUNTIME.match(name)
        if match and os.path.isfile(os.path.join(flat, name)):
            sources[match.group(1) + match.group(2)] = name
    if not sources:
        raise pe.EngineError("engine has no x86_64 runtime files in %s for %s" % (flat, ", ".join(sorted(triples))))
    made = []
    for triple in sorted(triples):
        directory = os.path.join(os.path.dirname(flat), triple)
        os.makedirs(directory)
        for target, name in sources.items():
            shutil.copy2(os.path.join(flat, name), os.path.join(directory, target))
        made.append(os.path.relpath(directory, root))
    return made


def writeBundleProvenance(root, engineIdentity, host, version, hasRuntime, hasWindows, cppTargets=(), cOnlyTargets=(),
                          targetRuntimeDirectories=()):
    receipt = {
        "kind": "local-bundle-assembly",
        "statement": "Engine copied unchanged, runtime prepared by prepareRuntime.py; the contract files "
                     "were rewritten over the whole bundle. Not an upstream-controlled build.",
        "redistributionCertified": False,
        "host": host, "engineVersion": version, "engineRelative": ENGINE_RELATIVE,
        "sourceEngineIdentity": engineIdentity,
        "engineProvenance": "notices/provenance.json",
        "engineProvenanceSha256": pe.sha256File(os.path.join(root, "notices", "provenance.json")),
    }
    if hasRuntime:
        receipt["runtimeProvenance"] = "runtime/notices/runtime-provenance.json"
    if hasWindows:
        receipt["windowsRuntimeProvenance"] = "runtime/windows/notices/" + pw.PROVENANCE
    if cppTargets:
        receipt["cppRuntimeProvenance"] = "runtime/" + pc.PROVENANCE
        receipt["cppTargets"] = list(cppTargets)
        receipt["cOnlyTargets"] = list(cOnlyTargets)
    if targetRuntimeDirectories:
        receipt["targetRuntimeDirectories"] = list(targetRuntimeDirectories)
    pe.writeText(os.path.join(root, "notices", "bundle-provenance.json"),
                 json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def readSharedOverlay(overlay):
    """The receipt of a prepareRuntime.py --shared overlay, after its files are checked to be exactly the ones
    the receipt names: each target's config, its directory of inputs and aliases, and the receipt itself."""
    path = os.path.join(overlay, pr.SHARED_PROVENANCE)
    if not os.path.isfile(path) or os.path.islink(path):
        raise pe.EngineError("overlay %s has no %s" % (overlay, pr.SHARED_PROVENANCE))
    with open(path, encoding="utf-8") as f:
        receipt = json.load(f)
    if set(receipt) != set(SHARED_RECEIPT_COMMON) | {"targets"} or receipt["kind"] != SHARED_RECEIPT_KIND:
        raise pe.EngineError("overlay %s receipt is not a %s receipt" % (overlay, SHARED_RECEIPT_KIND))
    if receipt["redistributionCertified"] is not False:
        raise pe.EngineError("overlay %s certifies redistribution; a local proof never does" % overlay)
    if not receipt["targets"]:
        raise pe.EngineError("overlay %s names no target" % overlay)
    files, directories, seen = {pr.SHARED_PROVENANCE}, {"notices"}, []
    for record in receipt["targets"]:
        target = record.get("target")
        if target not in pr.SHARED_TARGETS or target in seen:
            raise pe.EngineError("overlay %s names target %r twice or outside %s" % (
                overlay, target, ", ".join(pr.SHARED_TARGETS)))
        seen.append(target)
        directory = pr.sharedDirectory(target)
        if (record.get("directory"), record.get("config")) != (directory, directory + ".cfg"):
            raise pe.EngineError("overlay %s: %s is not laid out as %s and %s.cfg" % (overlay, target, directory, directory))
        includes = record.get("includeDirectories")
        if not isinstance(includes, list) or not all(isinstance(d, str) for d in includes):
            raise pe.EngineError("overlay %s: %s includeDirectories is not a list of names" % (overlay, target))
        for name in includes:
            pr.checkName(name)
        inputs = [pr.checkName(i["name"]) for i in record["inputs"]]
        aliases = [pr.checkName(a["alias"]) for a in record["libraryAliases"]]
        if len(set(inputs + aliases)) != len(inputs + aliases):
            raise pe.EngineError("overlay %s: %s names a file twice" % (overlay, directory))
        directories.add(directory)
        files.update([directory + ".cfg"] + [directory + "/" + n for n in inputs + aliases])
    found, foundDirectories = set(), set()
    for directory, dirnames, filenames in os.walk(overlay):
        for name in dirnames:
            full = os.path.join(directory, name)
            if os.path.islink(full):
                raise pe.EngineError("overlay %s has a directory symlink %s" % (overlay, name))
            foundDirectories.add(os.path.relpath(full, overlay))
        found.update(os.path.relpath(os.path.join(directory, n), overlay) for n in filenames)
    if found != files or foundDirectories != directories:
        raise pe.EngineError("overlay %s holds %s, not exactly the files its receipt names" % (
            overlay, sorted((found ^ files) | (foundDirectories ^ directories))))
    for record in receipt["targets"]:
        directory = os.path.join(overlay, record["directory"])
        if os.path.islink(directory + ".cfg") or not os.path.isfile(directory + ".cfg"):
            raise pe.EngineError("overlay %s: %s.cfg is not a regular file" % (overlay, record["directory"]))
        for item in record["inputs"]:
            file = os.path.join(directory, item["name"])
            if (os.path.islink(file) or not os.path.isfile(file) or pe.sha256File(file) != item["sha256"]
                    or os.path.getsize(file) != item["bytes"]):
                raise pe.EngineError("overlay %s: %s/%s differs from its record" % (overlay, record["directory"], item["name"]))
        pr.verifyLibraryAliases(directory, record["libraryAliases"])
    return receipt


def coalesceSharedReceipts(receipts):
    """One receipt for the targets of all receipts, which must agree on every field but the targets, and name each
    target once, in the order of pr.SHARED_TARGETS."""
    first = receipts[0]
    for receipt in receipts[1:]:
        different = [k for k in SHARED_RECEIPT_COMMON if receipt[k] != first[k]]
        if different:
            raise pe.EngineError("overlay receipts differ in %s" % ", ".join(different))
    records = [r for receipt in receipts for r in receipt["targets"]]
    names = [r["target"] for r in records]
    if len(set(names)) != len(names):
        raise pe.EngineError("target %s is in two overlays" % sorted(n for n in names if names.count(n) > 1)[0])
    joined = {k: first[k] for k in SHARED_RECEIPT_COMMON}
    joined["targets"] = sorted(records, key=lambda r: list(pr.SHARED_TARGETS).index(r["target"]))
    return joined


def augmentBundle(bundle, overlays, output):
    """Clone the verified bundle with the shared-object overlays added under runtime/. Everything the
    bundle holds stays byte for byte; only its bundle receipt gains the shared entries and the contract is rewritten."""
    bundle, output = os.path.abspath(bundle), os.path.abspath(output)
    overlays = [os.path.abspath(o) for o in overlays]
    if not overlays or len(set(overlays)) != len(overlays):
        raise pe.EngineError("--shared-runtime needs each overlay once, at least one")
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    if pe.containsPath(bundle, output):
        raise pe.EngineError("output %s is inside the bundle" % output)
    host, version, _ = pe.verifyEngine(bundle)
    runtime = os.path.join(bundle, "runtime")
    with open(os.path.join(bundle, "notices", "bundle-provenance.json"), encoding="utf-8") as f:
        bundleReceipt = json.load(f)
    baseReceipt = os.path.join(runtime, "notices", "runtime-provenance.json")
    if "runtimeProvenance" not in bundleReceipt or not os.path.isfile(baseReceipt):
        raise pe.EngineError("bundle %s has no prepared runtime to add shared profiles to" % bundle)
    if "sharedRuntimeProvenance" in bundleReceipt:
        raise pe.EngineError("bundle %s already has shared profiles" % bundle)
    with open(baseReceipt, encoding="utf-8") as f:
        base = json.load(f)
    receipts = [readSharedOverlay(o) for o in overlays]
    expected = {"baseRuntimeProvenanceSha256": pe.sha256File(baseReceipt), "zig": base["zig"], "producerHost": host,
                "engineVersion": version, "engineRelative": ENGINE_RELATIVE}
    for overlay, receipt in zip(overlays, receipts):
        different = [k for k, v in expected.items() if receipt[k] != v]
        if different:
            raise pe.EngineError("overlay %s does not belong to this bundle: %s differ" % (overlay, ", ".join(different)))
    joined = coalesceSharedReceipts(receipts)
    for record in joined["targets"]:
        if record["target"] not in [t["target"] for t in base["targets"]]:
            raise pe.EngineError("bundle runtime was not prepared for %s" % record["target"])
        missing = [d for d in record["includeDirectories"] if not os.path.isdir(os.path.join(runtime, "include", "libc", d))]
        if missing:
            raise pe.EngineError("bundle runtime has no include/libc/%s for %s" % (missing[0], record["target"]))
        taken = [n for n in (record["directory"], record["config"]) if os.path.lexists(os.path.join(runtime, n))]
        if taken or os.path.lexists(os.path.join(runtime, pr.SHARED_PROVENANCE)):
            raise pe.EngineError("bundle runtime already has %s; it is never replaced" % ", ".join(taken or [pr.SHARED_PROVENANCE]))
    os.makedirs(os.path.dirname(output), exist_ok=True)
    clone = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        shutil.copytree(bundle, clone, symlinks=True, dirs_exist_ok=True)
        for overlay, receipt in zip(overlays, receipts):
            for record in receipt["targets"]:
                shutil.copytree(os.path.join(overlay, record["directory"]), os.path.join(clone, "runtime", record["directory"]),
                                symlinks=True)
                shutil.copy(os.path.join(overlay, record["config"]), os.path.join(clone, "runtime", record["config"]))
        pe.writeText(os.path.join(clone, "runtime", pr.SHARED_PROVENANCE), json.dumps(joined, indent=2, sort_keys=True) + "\n")
        bundleReceipt.update({"baseBundleIdentity": pe.readLine(bundle, "IDENTITY", "[0-9a-f]{64}"),
                              "sharedRuntimeProvenance": "runtime/" + pr.SHARED_PROVENANCE,
                              "sharedTargets": [r["target"] for r in joined["targets"]]})
        pe.writeText(os.path.join(clone, "notices", "bundle-provenance.json"),
                     json.dumps(bundleReceipt, indent=2, sort_keys=True) + "\n")
        pe.writeContract(clone, host, version)
        pe.verifyEngine(clone)
        os.chmod(clone, 0o755)
        pr.renameNoReplace(clone, output)
    except BaseException:
        shutil.rmtree(clone, ignore_errors=True)
        raise
    return output


def prepareBundle(engine, zig, output, targets):
    engine, output = os.path.abspath(engine), os.path.abspath(output)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    host, version, _ = pe.verifyEngine(engine)
    if os.path.lexists(os.path.join(engine, "runtime")):
        raise pe.EngineError("engine %s already has a runtime entry; --engine takes the component alone" % engine)
    if pe.containsPath(engine, output):
        raise pe.EngineError("output %s is inside the engine" % output)
    with open(os.path.join(engine, "IDENTITY"), encoding="utf-8") as f:
        engineIdentity = f.read().strip()
    os.makedirs(os.path.dirname(output), exist_ok=True)
    clone = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        shutil.copytree(engine, clone, symlinks=True, dirs_exist_ok=True)
        others, windows = splitTargets(targets)
        runtime = os.path.join(clone, "runtime")
        hasRuntime = bool(others) or not targets
        if hasRuntime:
            pr.prepareRuntime(zig, engine, runtime, others, ENGINE_RELATIVE)
        else:
            os.makedirs(runtime)
        hasWindows = bool(windows) or not targets
        if hasWindows:
            pw.prepareWindowsRuntime(zig, engine, os.path.join(runtime, "windows"), windows or None)
        targetDirectories = addTargetRuntimeDirectories(clone, host, version, runtime) if hasRuntime else []
        prepared = ((others or list(pr.TARGETS)) if hasRuntime else []) + ((windows or list(pw.TARGETS)) if hasWindows else [])
        cppTargets = [t for t in pc.TARGETS if t in prepared]
        if cppTargets:
            pc.addCppRuntime(zig, engine, runtime, cppTargets)
        writeBundleProvenance(clone, engineIdentity, host, version, hasRuntime, hasWindows, cppTargets,
                              [t for t in prepared if t not in cppTargets], targetDirectories)
        pe.writeContract(clone, host, version)
        pe.verifyEngine(clone)
        os.chmod(clone, 0o755)
        pr.renameNoReplace(clone, output)
    except BaseException:
        shutil.rmtree(clone, ignore_errors=True)
        raise
    return output


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine")
    parser.add_argument("--zig")
    parser.add_argument("--output", required=True)
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--bundle")
    parser.add_argument("--shared-runtime", action="append", default=[])
    args = parser.parse_args(argv)
    if args.bundle:
        if args.engine or args.zig or args.target or not args.shared_runtime:
            parser.error("--bundle takes --shared-runtime and --output only")
    elif args.shared_runtime or not (args.engine and args.zig):
        parser.error("--engine and --zig are required, and --shared-runtime needs --bundle")
    try:
        if args.bundle:
            output = augmentBundle(args.bundle, args.shared_runtime, args.output)
        else:
            output = prepareBundle(args.engine, args.zig, args.output, args.target)
    except pe.EngineError as error:
        print("prepareBundle: error: %s" % error, file=sys.stderr)
        return 1
    with open(os.path.join(output, "IDENTITY"), encoding="utf-8") as f:
        identity = f.read().strip()
    print("bundle written to %s" % output)
    print("files=%d identity=%s" % (len(pe.listFiles(output)), identity))
    print("redistribution NOT certified; local proof")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
