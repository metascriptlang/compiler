#!/usr/bin/env python3
"""Assemble a full engine and runtime bundle from a prepared engine and a local Zig.

    prepareBundle.py --engine ENGINE_DIR --zig ZIG --output NEW_DIR [--target T ...]

The engine is the verified component from prepareEngine.py. The bundle keeps its contents at the
root (bin/, lib/, notices/) and adds `runtime/`, the payload prepareRuntime.py writes with the
engine reached by `..`. HOST, VERSION, FILES.sha256 and IDENTITY are rewritten over every file of
the bundle, and the source engine's identity is recorded in notices/bundle-provenance.json.

The bundle is a local proof, not an upstream-controlled build, and never certifies redistribution.
"""
import argparse
import json
import os
import shutil
import sys
import tempfile

import prepareEngine as pe
import prepareRuntime as pr

ENGINE_RELATIVE = ".."


def writeBundleProvenance(root, engineIdentity, host, version):
    receipt = {
        "kind": "local-bundle-assembly",
        "statement": "Engine copied unchanged, runtime prepared by prepareRuntime.py; the contract files "
                     "were rewritten over the whole bundle. Not an upstream-controlled build.",
        "redistributionCertified": False,
        "host": host, "engineVersion": version, "engineRelative": ENGINE_RELATIVE,
        "sourceEngineIdentity": engineIdentity,
        "engineProvenance": "notices/provenance.json",
        "engineProvenanceSha256": pe.sha256File(os.path.join(root, "notices", "provenance.json")),
        "runtimeProvenance": "runtime/notices/runtime-provenance.json",
    }
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
        pr.prepareRuntime(zig, engine, os.path.join(clone, "runtime"), targets, ENGINE_RELATIVE)
        writeBundleProvenance(clone, engineIdentity, host, version)
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
