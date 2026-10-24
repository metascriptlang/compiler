#!/usr/bin/env python3
"""Assemble a full engine and runtime bundle from a prepared engine and a local Zig.

    prepareBundle.py --engine ENGINE_DIR --zig ZIG --output NEW_DIR [--target T ...]

The engine is the verified component from prepareEngine.py. The bundle keeps its contents at the
root (bin/, lib/, notices/) and adds `runtime/`, the payload prepareRuntime.py writes with the
engine reached by `..`; the x86_64-windows-gnu and aarch64-windows-gnu runtimes are `runtime/windows/`, from
prepareWindowsRuntime.py, with the engine reached by `../..`. HOST, VERSION, FILES.sha256 and IDENTITY are rewritten over every file of
the bundle, and the source engine's identity is recorded in notices/bundle-provenance.json.

The x86_64-linux-gnu.2.31 and x86_64-windows-gnu runtimes also get the C++ overlay of prepareCppRuntime.py merged
into `runtime/`; the aarch64 and wasm32-wasi runtimes stay C only, and the receipt names them under `cOnlyTargets`.

The bundle is a local proof, not an upstream-controlled build, and never certifies redistribution.
"""
import argparse
import json
import os
import shutil
import sys
import tempfile

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw

ENGINE_RELATIVE = ".."


def splitTargets(targets):
    """(targets prepareRuntime.py makes, Windows targets prepareWindowsRuntime.py makes; none when no Windows
    target is named and others are). No target selects every target."""
    windows = [t for t in targets if t in pw.TARGETS]
    return [t for t in targets if t not in pw.TARGETS], windows if windows or not targets else []


def writeBundleProvenance(root, engineIdentity, host, version, hasRuntime, hasWindows, cppTargets=(), cOnlyTargets=()):
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
    pe.writeText(os.path.join(root, "notices", "bundle-provenance.json"),
                 json.dumps(receipt, indent=2, sort_keys=True) + "\n")


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
        prepared = ((others or list(pr.TARGETS)) if hasRuntime else []) + ((windows or list(pw.TARGETS)) if hasWindows else [])
        cppTargets = [t for t in pc.TARGETS if t in prepared]
        if cppTargets:
            pc.addCppRuntime(zig, engine, runtime, cppTargets)
        writeBundleProvenance(clone, engineIdentity, host, version, hasRuntime, hasWindows, cppTargets,
                              [t for t in prepared if t not in cppTargets])
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
    parser.add_argument("--engine", required=True)
    parser.add_argument("--zig", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--target", action="append", default=[])
    args = parser.parse_args(argv)
    try:
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
