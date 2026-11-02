#!/usr/bin/env python3
"""Assemble a full engine and runtime bundle from a prepared engine and a local Zig.

    prepareBundle.py --engine ENGINE_DIR --zig ZIG --output NEW_DIR [--target T ...] [--windows-runtime RUNTIME_DIR]
    prepareBundle.py --bundle BUNDLE_DIR --shared-runtime OVERLAY_DIR [--shared-runtime ...] --output NEW_DIR

The engine is the verified component from prepareEngine.py. The bundle keeps its contents at the
root (bin/, lib/, notices/) and adds `runtime/`, the payload prepareRuntime.py writes with the
engine reached by `..`; the x86_64-windows-gnu and aarch64-windows-gnu runtimes are `runtime/windows/`, from
prepareWindowsRuntime.py, with the engine reached by `../..`; the aarch64-macos and x86_64-macos runtimes are `runtime/darwin/`, from
prepareDarwinRuntime.py, with the engine reached by `../..` too. HOST, VERSION, FILES.sha256 and IDENTITY are rewritten over every file of
the bundle, and the source engine's identity is recorded in notices/bundle-provenance.json.

The GNU Linux targets get their shared C bases before the C++ overlay is prepared. Both Linux CPUs, both
macOS CPUs and x86_64 Windows get the C++ overlay merged into `runtime/`; the other targets are recorded under `cOnlyTargets`.

`--bundle` adds the GNU shared-object profiles of prepareRuntime.py --shared to a prepared bundle without preparing
anything again: NEW_DIR is a clone of BUNDLE_DIR (never changed) plus the `<target>.so.cfg` and `<target>.so/` of each
OVERLAY_DIR under `runtime/`, one `runtime/notices/runtime-shared-provenance.json` that joins the overlays' receipts,
and a contract rewritten over every file. Every overlay must name the bundle's own runtime receipt, Zig and engine.

`--windows-runtime RUNTIME_DIR` takes the Windows targets from a prepared source runtime instead of preparing them
with Zig: the root that prepareWindowsSourceRuntime.py, prepareWindowsSourceCppRuntime.py and
prepareWindowsSanitizerRuntime.py leave merged, with their three receipts. Their targets must be exactly the selected
Windows targets, and only the files the receipts declare (and the header tree) are copied into `runtime/`, after which
the compiler-rt archives of the C runtime and of the sanitizer assets are installed into the engine copy's
lib/clang/MAJOR through the two producers' own installResource. The Windows targets then carry the source C++ overlay and
are not given the Zig one; the other targets are unchanged. No Zig is needed when every --target is a Windows one.
The bundle's contract covers every one of these files, the sanitizer DLL included, which stays an asset beside its
target's bin directory.

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
import prepareDarwinRuntime as pd
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSanitizerRuntime as san
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws

ENGINE_RELATIVE = ".."
LINUX_ARCH_RUNTIME = re.compile(r"^(.+)-(x86_64|aarch64)(\..+)$")
LINUX_TARGET = re.compile(r"^-target ((?:x86_64|aarch64)-[^\s-]+-linux[0-9.]*-gnu[0-9.]*)$", re.MULTILINE)
SOURCE_TREES = ("windows", "windows-sanitizers")
SOURCE_HEADERS = "windows/include/libc/" + pws.HEADER_DIRECTORY
SHARED_RECEIPT_KIND = "local-zig-runtime-shared-proof"
SHARED_RECEIPT_COMMON = ("kind", "statement", "redistributionCertified", "zig", "producerHost", "engineVersion",
                         "engineRelative", "baseRuntimeProvenanceSha256")


def splitTargets(targets):
    """(targets prepareRuntime.py makes, Windows targets prepareWindowsRuntime.py makes, macOS targets
    prepareDarwinRuntime.py makes; the last two are the ones named, so none when only others are). No target
    selects every target."""
    windows = [t for t in targets if t in pw.TARGETS]
    darwin = [t for t in targets if t in pd.TARGETS]
    return [t for t in targets if t not in pw.TARGETS and t not in pd.TARGETS], windows, darwin


def addTargetRuntimeDirectories(root, host, version, runtime):
    """Give matching-architecture GNU target triples the Linux engine's native runtime artifacts under
    lib/clang/MAJOR/lib/TRIPLE/libclang_rt.NAME.EXT. Other ABIs never use these glibc artifacts.
    Returns the directories made, relative to root."""
    arch = {pe.LINUX_X64: "x86_64", pe.LINUX_ARM64: "aarch64"}.get(host)
    if arch is None:
        return []
    triples = set()
    for name in sorted(os.listdir(runtime)):
        path = os.path.join(runtime, name)
        if name.endswith(".cfg") and os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                triples.update(t for t in LINUX_TARGET.findall(f.read()) if t.startswith(arch + "-"))
    if not triples:
        return []
    flat = os.path.join(root, "lib", "clang", version.split(".")[0], "lib", "linux")
    sources = {}
    for name in sorted(os.listdir(flat)):
        match = LINUX_ARCH_RUNTIME.match(name)
        if match and match.group(2) == arch and os.path.isfile(os.path.join(flat, name)):
            sources[match.group(1) + match.group(3)] = name
    if not sources:
        raise pe.EngineError("engine has no %s runtime files in %s for %s" % (arch, flat, ", ".join(sorted(triples))))
    made = []
    for triple in sorted(triples):
        directory = os.path.join(os.path.dirname(flat), triple)
        os.makedirs(directory)
        for target, name in sources.items():
            shutil.copy2(os.path.join(flat, name), os.path.join(directory, target))
        made.append(os.path.relpath(directory, root).replace(os.sep, "/"))
    return made


def writeBundleProvenance(root, engineIdentity, host, version, hasRuntime, hasWindows, cppTargets=(), cOnlyTargets=(),
                          targetRuntimeDirectories=(), hasDarwin=False, sharedTargets=(), windowsSource=None):
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
    if hasDarwin:
        receipt["darwinRuntimeProvenance"] = "runtime/darwin/notices/" + pd.PROVENANCE
    sourceTargets = windowsSource["targets"] if windowsSource else []
    if windowsSource:
        c, cpp, sanitizer = windowsSource["sha256"]
        receipt.update({"windowsSourceTargets": list(sourceTargets), "windowsRuntimeProvenanceSha256": c,
                        "windowsSourceCppRuntimeProvenance": "runtime/" + pwc.PROVENANCE,
                        "windowsSourceCppRuntimeProvenanceSha256": cpp,
                        "windowsSanitizerRuntimeProvenance": "runtime/" + san.PROVENANCE,
                        "windowsSanitizerRuntimeProvenanceSha256": sanitizer})
    if any(t not in sourceTargets for t in cppTargets):
        receipt["cppRuntimeProvenance"] = "runtime/" + pc.PROVENANCE
    if cppTargets:
        receipt["cppTargets"] = list(cppTargets)
        receipt["cOnlyTargets"] = list(cOnlyTargets)
    if sharedTargets:
        receipt["sharedRuntimeProvenance"] = "runtime/" + pr.SHARED_PROVENANCE
        receipt["sharedTargets"] = list(sharedTargets)
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
            foundDirectories.add(os.path.relpath(full, overlay).replace(os.sep, "/"))
        found.update(os.path.relpath(os.path.join(directory, n), overlay).replace(os.sep, "/") for n in filenames)
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


def sourceReceipts(source, targets, version, major):
    """((C, C++, sanitizer) receipts, their sha256 in that order) of the prepared source Windows runtime at `source`,
    once each describes its files, all three cover exactly `targets`, and all use this engine's version and
    llvm-project commit. Their producer hosts remain recorded, not a target-compatibility gate."""
    llvmRev = pws.pinnedRevisions(version)[1]
    (base, baseDigest), (cpp, cppDigest) = san.inputReceipts(source, targets, version, major, llvmRev)
    sanitizer, sanitizerDigest = pwc.readJson(source, san.PROVENANCE)
    problem = san.receiptProblem(sanitizer, source, source)
    if problem:
        raise pe.EngineError(problem)
    for name, receipt in (("C", base), ("C++", cpp), ("sanitizer", sanitizer)):
        if sorted(receipt["targets"]) != sorted(targets):
            raise pe.EngineError("%s receipt targets %s are not exactly the selected %s" % (name, receipt["targets"], targets))
        if receipt.get("engineVersion") != version:
            raise pe.EngineError("%s receipt was produced for engine %s, not %s" % (
                name, receipt.get("engineVersion"), version))
        if not isinstance(receipt.get("producerHost"), str) or not receipt["producerHost"].strip():
            raise pe.EngineError("%s receipt has no producer host provenance" % name)
        if receipt.get("redistributionCertified") is not False:
            raise pe.EngineError("%s receipt certifies redistribution; a local proof never does" % name)
        if name != "C" and receipt.get("cohort") != "llvm-%s-source" % version:
            raise pe.EngineError("%s receipt cohort %r is not llvm-%s-source" % (name, receipt.get("cohort"), version))
    recorded = (sanitizer.get("sources") or {}).get("llvm-project") or {}
    found = (recorded.get("rev"), recorded.get("version"), recorded.get("major"))
    if found != (llvmRev, version, major):
        raise pe.EngineError("the sanitizer runtime was built from llvm-project %s (LLVM %s, major %s), not %s (LLVM %s, "
                             "major %s)" % (found + (llvmRev, version, major)))
    return (base, cpp, sanitizer), (baseDigest, cppDigest, sanitizerDigest)


def sourceDeclared(base, cpp, sanitizer):
    """Every file of the source runtime the three receipts declare, as runtime-relative paths: the C variants with their
    configs, the builtins, the notices, and the files of the C++ and sanitizer overlays, with the three receipts. A path
    declared twice or with an unsafe component is an error, and so is a variant set that is not exactly each selected
    target as an executable and a DLL, a config of another name and include directories that are not the producer's."""
    variants, targets = base.get("variants") or [], base["targets"]
    if sorted((v["target"], v["variant"]) for v in variants) != sorted((t, v) for t in targets for v in pws.SOURCE_VARIANTS):
        raise pe.EngineError("the C receipt variants are not exactly %s as %s" % (targets, ", ".join(pws.SOURCE_VARIANTS)))
    if base.get("includeDirectories") != [pws.HEADER_DIRECTORY]:
        raise pe.EngineError("the C receipt include directories %r are not %r" % (base.get("includeDirectories"),
                                                                                  [pws.HEADER_DIRECTORY]))
    declared = ["windows/notices/" + pws.PROVENANCE, pwc.PROVENANCE, san.PROVENANCE]
    for variant in variants:
        if variant.get("config") != pws.variantConfig(variant["target"], variant["variant"]):
            raise pe.EngineError("the C receipt names the config %r for %s %s" % (
                variant.get("config"), variant["target"], variant["variant"]))
        declared += ["windows/%s/%s" % (variant["directory"], pr.checkName(r["name"])) for r in variant.get("files") or []]
        declared.append("windows/" + variant["config"])
    declared += ["windows/%s/%s" % (pws.RESOURCE_DIRECTORY, r["path"]) for r in base["resourceFiles"]]
    for relative in base.get("notices") or []:
        if not isinstance(relative, str) or not relative.startswith("notices/"):
            raise pe.EngineError("the C receipt notice %r is not under notices/" % (relative,))
        for part in relative.split("/"):
            pr.checkName(part)
        declared.append("windows/" + relative)
    declared += [r["path"] for r in cpp["files"]] + [r["path"] for r in sanitizer["files"]]
    seen = set()
    for relative in declared:
        if relative in seen:
            raise pe.EngineError("the receipts declare %s twice" % relative)
        seen.add(relative)
    return declared


def sourceInventory(source, declared):
    """The files to copy from `source`: every declared file and the header tree. Every file under its `windows` and
    `windows-sanitizers` directories must be one of them and every declared file there must exist, with no link,
    reparse point or unsafe name anywhere under them. Nothing is opened."""
    found = set()
    for tree in SOURCE_TREES:
        found.update(tree + "/" + name for name in san.installFiles(os.path.join(source, tree)))
    headers = {p for p in found if p.startswith(SOURCE_HEADERS + "/")}
    if not headers:
        raise pe.EngineError("%s has no header tree at %s" % (source, SOURCE_HEADERS))
    inside = [p for p in declared if p.split("/")[0] in SOURCE_TREES]
    unknown, lacking = sorted(found - set(inside) - headers), sorted(set(inside) - found)
    if unknown:
        raise pe.EngineError("%s holds files the receipts do not declare: %s" % (source, ", ".join(unknown[:5])))
    if lacking:
        raise pe.EngineError("the receipts declare files %s lacks: %s" % (source, ", ".join(lacking[:5])))
    return sorted(set(inside) | headers) + [p for p in declared if p.split("/")[0] not in SOURCE_TREES]


def checkSourceWindows(source, targets, version, major):
    """(the files to copy, the sha256 of the three receipts) of the source Windows runtime at `source` for exactly
    `targets`, once its receipts, files and C configs are proven as they are, with nothing written."""
    receipts, digests = sourceReceipts(source, targets, version, major)
    files = sourceInventory(source, sourceDeclared(*receipts))
    for variant in receipts[0]["variants"]:
        relative = "windows/" + variant["config"]
        with open(os.path.join(source, *relative.split("/")), encoding="utf-8", newline="") as f:
            written = f.read()
        if written != pws.renderSourceConfig(variant["target"], variant["variant"], [pws.HEADER_DIRECTORY], major):
            raise pe.EngineError("%s is not the config the source C producer writes" % relative)
    return files, digests


def addSourceWindowsRuntime(source, clone, files, digests, targets, version, major):
    """Copy the checked files of the source Windows runtime into clone/runtime, which must hold none of them, prove the
    copy is the same files under the same receipts, then install the C runtime's builtins and the sanitizer archives
    into the clone's own lib/clang/MAJOR with the producers' installers, the C runtime's first. `source` is only read."""
    runtime = os.path.join(clone, "runtime")
    taken = [f for f in files if os.path.lexists(os.path.join(runtime, *f.split("/")))]
    if taken:
        raise pe.EngineError("%s already has %s; the source Windows runtime replaces nothing" % (runtime, ", ".join(taken[:5])))
    hashes = {f: pe.sha256File(os.path.join(source, *f.split("/"))) for f in files}
    for relative in files:
        destination = os.path.join(runtime, *relative.split("/"))
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copy2(os.path.join(source, *relative.split("/")), destination, follow_symlinks=False)
    if checkSourceWindows(runtime, targets, version, major) != (files, digests) or hashes != {
            f: pe.sha256File(os.path.join(runtime, *f.split("/"))) for f in files}:
        raise pe.EngineError("the source Windows runtime changed while it was copied")
    resource = os.path.join(clone, "lib", "clang", major)
    pws.installResource(os.path.join(runtime, "windows"), resource)
    san.installResource(runtime, resource)


def prepareBundle(engine, zig, output, targets, windowsRuntime=None):
    engine, output = os.path.abspath(engine), os.path.abspath(output)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    others, windows, darwin = splitTargets(targets)
    if zig is None and not (windowsRuntime and targets and not others and not darwin):
        raise pe.EngineError("--zig is required, except for explicit Windows targets with --windows-runtime")
    if windowsRuntime and targets and not windows:
        raise pe.EngineError("--windows-runtime serves no Windows target: %s" % ", ".join(targets))
    host, version, _ = pe.verifyEngine(engine)
    major = version.split(".")[0]
    if os.path.lexists(os.path.join(engine, "runtime")):
        raise pe.EngineError("engine %s already has a runtime entry; --engine takes the component alone" % engine)
    if pe.containsPath(engine, output):
        raise pe.EngineError("output %s is inside the engine" % output)
    sourceTargets, source = [], None
    if windowsRuntime:
        source = os.path.abspath(windowsRuntime)
        if not os.path.isdir(source) or pe.isLinkLike(source):
            raise pe.EngineError("source Windows runtime %s is not a directory" % source)
        if pe.containsPath(source, output):
            raise pe.EngineError("output %s is inside the source Windows runtime" % output)
        if pe.containsPath(source, engine):
            raise pe.EngineError("the engine %s is inside the source Windows runtime" % engine)
        if pe.containsPath(engine, source):
            raise pe.EngineError("the source Windows runtime %s is inside the engine" % source)
        sourceTargets = pw.selectWindowsTargets(windows or None)
        inputs = lambda: (pc.treeDigest(engine), pc.treeDigest(source))
        before = inputs()
        files, digests = checkSourceWindows(source, sourceTargets, version, major)
    with open(os.path.join(engine, "IDENTITY"), encoding="utf-8") as f:
        engineIdentity = f.read().strip()
    os.makedirs(os.path.dirname(output), exist_ok=True)
    clone = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        shutil.copytree(engine, clone, symlinks=True, dirs_exist_ok=True)
        runtime = os.path.join(clone, "runtime")
        hasRuntime = bool(others) or not targets
        if hasRuntime:
            pr.prepareRuntime(zig, engine, runtime, others, ENGINE_RELATIVE)
        else:
            os.makedirs(runtime)
        hasWindows = bool(windows) or not targets
        if hasWindows and not sourceTargets:
            pw.prepareWindowsRuntime(zig, engine, os.path.join(runtime, "windows"), windows or None)
        hasDarwin = bool(darwin) or not targets
        if hasDarwin:
            pd.prepareDarwinRuntime(zig, engine, os.path.join(runtime, "darwin"), darwin or None)
        prepared = ((others or list(pr.TARGETS)) if hasRuntime else []) + ((windows or list(pw.TARGETS)) if hasWindows else [])
        prepared += (darwin or list(pd.TARGETS)) if hasDarwin else []
        sharedTargets = [t for t in pr.SHARED_TARGETS if t in prepared]
        if sharedTargets:
            with tempfile.TemporaryDirectory(prefix="bundle-shared-") as scratch:
                overlay = os.path.join(scratch, "overlay")
                pr.prepareSharedRuntime(zig, engine, runtime, overlay, sharedTargets)
                pc.mergeOverlay(overlay, runtime)
        targetDirectories = addTargetRuntimeDirectories(clone, host, version, runtime) if hasRuntime else []
        cppTargets = [t for t in pc.TARGETS if t in prepared and t not in sourceTargets]
        if cppTargets:
            pc.addCppRuntime(zig, engine, runtime, cppTargets)
        if sourceTargets:
            addSourceWindowsRuntime(source, clone, files, digests, sourceTargets, version, major)
            if inputs() != before:
                raise pe.EngineError("the engine or the source Windows runtime changed while the bundle was assembled")
        cppTargets = cppTargets + sourceTargets
        writeBundleProvenance(clone, engineIdentity, host, version, hasRuntime, hasWindows, cppTargets,
                              [t for t in prepared if t not in cppTargets], targetDirectories, hasDarwin, sharedTargets,
                              {"targets": sourceTargets, "sha256": digests} if sourceTargets else None)
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
    parser.add_argument("--windows-runtime")
    args = parser.parse_args(argv)
    if args.bundle:
        if args.engine or args.zig or args.target or args.windows_runtime or not args.shared_runtime:
            parser.error("--bundle takes --shared-runtime and --output only")
    elif args.shared_runtime or not args.engine or not (
            args.zig or (args.windows_runtime and args.target and all(t in pw.TARGETS for t in args.target))):
        parser.error("--engine and --zig are required (--zig may be left out only for explicit Windows --target values "
                     "with --windows-runtime), and --shared-runtime needs --bundle")
    try:
        if args.bundle:
            output = augmentBundle(args.bundle, args.shared_runtime, args.output)
        else:
            output = prepareBundle(args.engine, args.zig, args.output, args.target, args.windows_runtime)
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
