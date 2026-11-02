#!/usr/bin/env python3
"""Compile, link and inspect programs with bare -fsanitize flags against the standard Windows sanitizer assets. COMPILE/LINK
INSPECTION ONLY: no program is run, so no runtime diagnostic, exit code or DLL load is proven.

    proveWindowsSanitizerRuntime.py --engine ENGINE_DIR --runtime RUNTIME_DIR [--target T ...] [--deny PATH ...]

RUNTIME_DIR holds `windows/` of the source C runtime with the source C++ overlay and the sanitizer overlay of
prepareWindowsSanitizerRuntime.py merged in. The three receipts, their cohort (one llvm-project commit, version and major,
the engine's) and the files they list are checked first. The engine and the runtime are then relocated to a path with a
space, the root notices and resource files of the sanitizer receipt are copied beside them and
prepareWindowsSanitizerRuntime.installResource installs the archives into the staged engine's own lib/clang/<major>; the
originals are read and never written. No compiler config, PATH or bundle layout is changed and the ASan DLL stays where
the overlay put it, under windows/<target>/bin, for a later harness to copy beside a program.

Every proof is compiled and linked with the target's own config (C with the base config, C++ with the C++ config first
and the base config last, the pair the C++ cohort is proven with) and then `-g -O2`, plain, thin and full LTO, and the
sanitizer flag after the configs and nothing else: x86_64 with address, undefined and address,undefined, aarch64 with
undefined (Windows ASan is x86_64 only). The C++ vptr proofs explicitly add vptr, which the undefined group does not
include, and include it in their non-recovering flags. The program that must fail under UBSan adds -fno-sanitize-recover=undefined to
its compile and its link, because the recovering default exits 0 after the diagnostic. No sanitizer archive, `-l`, whole
archive or forced symbol is named by the proof: the driver and the object's default-library directive choose them, and the
plan (`-###`) of each plain link shows the choice. A C control through the base config alone is compiled and linked before
and after the installation and must not change.

Each compile and link must exit 0 with no output, each object must reference the runtime entry points its sanitizers
need (plain) or hold bitcode (LTO), and each linked file must be the console executable or DLL of the target's machine
whose imports are system DLLs, api sets and the UCRT, plus the ASan DLL exactly when address is on, and which exports
what its fixture exports.

--execute is not implemented: running the programs, reading the diagnostics and loading a DLL in a host is a later step.
--deny is enforced by the macOS sandbox only; elsewhere it is refused and the relocation, with a scan of the linked files
for the original paths, is all that is proven.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSanitizerRuntime as san
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws

LIMIT = "compile/link inspection only; no execution/runtime diagnostic proven"
FATAL = "-fno-sanitize-recover=undefined"
ASAN_ENTRY = "__asan_"
UBSAN_ENTRY = "__ubsan_handle_"
VPTR_ENTRY = "__ubsan_handle_dynamic_type_cache_miss"
ENTRIES = {"address": ASAN_ENTRY, "undefined": UBSAN_ENTRY}
INTERCEPTOR = "__asan_seh_interceptor"
PROOFS = {
    "clean": {"language": "c", "variant": "exe", "fixture": "windowsSanitizerClean.c", "needs": None, "fatal": False,
              "checks": ("address", "undefined")},
    "signed": {"language": "c", "variant": "exe", "fixture": "windowsSanitizerSigned.c", "needs": "undefined",
               "fatal": True, "checks": ("undefined",)},
    "heap": {"language": "c", "variant": "exe", "fixture": "windowsSanitizerHeap.c", "needs": "address", "fatal": False,
             "checks": ("address",)},
    "vptr": {"language": "c++", "variant": "exe", "fixture": "windowsSanitizerVptr.cpp", "needs": "undefined",
             "fatal": True, "checks": ("undefined",), "vptr": True},
    "dll": {"language": "c", "variant": "dll", "fixture": "windowsSanitizerDll.c", "needs": None, "fatal": True,
            "checks": ("address", "undefined"), "export": "sanitizerCProbe"},
    "cppdll": {"language": "c++", "variant": "dll", "fixture": "windowsSanitizerDll.cpp", "needs": None, "fatal": True,
               "checks": ("address", "undefined"), "export": "sanitizerCppProbe", "vptr": True},
}


def sanitizers(mask):
    return mask.split(",")


def masks(target):
    """The -fsanitize values of target: undefined always, and address alone and with it where the target carries an ASan
    runtime."""
    if any(spec["role"] == "asan-import" for spec in san.assetSpecs(target)):
        return ["address", "undefined", "address,undefined"]
    return ["undefined"]


def applies(proof, mask):
    return proof["needs"] is None or proof["needs"] in sanitizers(mask)


def sanitizerFlags(proof, mask):
    """The flags that follow the configs: the sanitizer, and the explicit fatal switch where the proof must fail and
    UBSan is on."""
    vptr = proof.get("vptr", False) and "undefined" in sanitizers(mask)
    selected = mask + (",vptr" if vptr else "")
    fatal = FATAL + (",vptr" if vptr else "")
    return ["-fsanitize=" + selected] + ([fatal] if proof["fatal"] and "undefined" in sanitizers(mask) else [])


def proofSteps(stage, work, target):
    """([(name, command)], {(proof, mask, mode): (object, linked file)}, [(name, `-###` link command, key)]): every proof
    that applies to each mask, plain and with thin and full LTO. The config flags come first and the sanitizer flags
    after them; nothing else names a sanitizer file."""
    runtime = os.path.join(stage, "runtime")
    steps, outputs, plans = [], {}, []
    for mask in masks(target):
        for name, proof in PROOFS.items():
            if not applies(proof, mask):
                continue
            cxx = proof["language"] == "c++"
            compiler = pws.engineTool(stage, "clang++" if cxx else "clang")
            config = (pwc.pairFlags if cxx else pwc.baseFlags)(runtime, target, proof["variant"])
            shared = ["-shared"] if proof["variant"] == "dll" else []
            flags = sanitizerFlags(proof, mask)
            fixture = os.path.join(pr.FIXTURES, proof["fixture"])
            suffix = ".dll" if proof["variant"] == "dll" else ".exe"
            for mode, lto in pws.LTO_MODES:
                tag = "%s-%s-%s" % (name, mask.replace(",", "+"), mode)
                obj, output = os.path.join(work, tag + ".o"), os.path.join(work, tag + suffix)
                steps.append(("%s %s %s compile" % (name, mask, mode), [compiler] + config + (
                    [pwc.CXX_STANDARD] if cxx else []) + ["-g", "-O2"] + lto + flags + ["-c", fixture, "-o", obj]))
                steps.append(("%s %s %s link" % (name, mask, mode), [compiler] + config + lto + shared + flags + [
                    obj, "-o", output]))
                outputs[(name, mask, mode)] = (obj, output)
            plain = outputs[(name, mask, "plain")]
            plans.append(("%s %s plan" % (name, mask), [compiler] + config + shared + flags + [
                "-###", plain[0], "-o", os.path.join(work, "%s-%s-plan%s" % (name, mask.replace(",", "+"), suffix))],
                (name, mask)))
    return steps, outputs, plans


def referencesProblem(listing, proof, mask):
    """Why the `llvm-nm --undefined-only` listing of a plain object does not reference the runtime entry point of each
    sanitizer of mask the proof's fixture exercises, or None."""
    undefined = [words[1] for words in (line.split() for line in listing.splitlines()) if len(words) == 2 and words[0] == "U"]
    for sanitizer in proof["checks"]:
        if sanitizer in sanitizers(mask) and not any(name.startswith(ENTRIES[sanitizer]) for name in undefined):
            return "the object references no %s* symbol for %s: %s" % (ENTRIES[sanitizer], sanitizer, undefined)
    if proof.get("vptr", False) and "undefined" in sanitizers(mask) and not any(
            name.startswith(VPTR_ENTRY) for name in undefined):
        return "the vptr object references no %s* symbol: %s" % (VPTR_ENTRY, undefined)
    return None


def planProblem(plan, stage, target, mask):
    """Why the one ld.lld line of a `-###` plan does not show the driver's own sanitizer choice, or None. With address:
    the import library of the resource directory before the startup object and again in the tail, then its thunk, the
    required interceptor and the thunk once more inside --whole-archive. Without it no ASan file, and for any mask no
    UBSan archive, which only an object's default-library directive may bring."""
    lines = [re.findall(r'"([^"]*)"', line) for line in plan.splitlines()]
    links = [words for words in lines if words and os.path.basename(words[0]).startswith("ld.lld")]
    if len(links) != 1:
        return "the plan has %d ld.lld lines, not one" % len(links)
    words = links[0]
    version = re.search(r"clang version (\d+)", plan)
    if version is None:
        return "the plan names no compiler version"
    library = os.path.normpath(os.path.join(stage, "lib", "clang", version.group(1), "lib", "windows"))
    searched = [os.path.normpath(words[i + 1]) for i, w in enumerate(words[:-1]) if w == "-L"] + [
        os.path.normpath(w[2:]) for w in words if w.startswith("-L") and len(w) > 2]
    if library not in searched:
        return "the plan does not search the resource directory %s: %s" % (library, searched)
    archives = [w for w in words if os.path.basename(w).endswith(".a")]
    ubsan = [w for w in archives if "ubsan" in os.path.basename(w)]
    if ubsan:
        return "the plan links %s: the UBSan runtime comes from the object, never from a driver tail" % ubsan
    asan = [w for w in archives if "asan" in os.path.basename(w)]
    if "address" not in sanitizers(mask):
        return "the plan links %s without address" % asan if asan else None
    names = {spec["role"]: spec["name"] for spec in san.assetSpecs(target)}
    where = lambda role: [i for i, w in enumerate(words) if os.path.normpath(w) == os.path.join(library, names[role])]
    imports, thunks = where("asan-import"), where("asan-thunk")
    if len(imports) != 2 or len(thunks) != 2:
        return "the plan names the ASan import library %d times and its thunk %d times, not twice each" % (
            len(imports), len(thunks))
    startups = [i for i, w in enumerate(words) if os.path.basename(w) in pws.STARTUP_OBJECTS]
    if not startups or imports[0] > startups[0]:
        return "the ASan import library does not come before the startup object"
    if "--require-defined" not in words or words[words.index("--require-defined") + 1] != INTERCEPTOR:
        return "the plan does not require %s" % INTERCEPTOR
    required = words.index("--require-defined")
    whole = words.index("--whole-archive") if "--whole-archive" in words else -1
    if not (imports[1] < thunks[0] < required < whole and thunks[1] == whole + 1
            and words[whole + 2:whole + 3] == ["--no-whole-archive"]):
        return "the ASan tail is not import, thunk, --require-defined, then the thunk inside --whole-archive"
    return None


def selectionProblem(plan, stage, target, proof):
    """pws.selectionProblem for a C link (startup objects, tail, builtins) and pwc.selectionProblem for a C++ one."""
    if proof["language"] == "c":
        return pws.selectionProblem(plan, os.path.join(stage, "runtime", "windows"), target, proof["variant"])
    return pwc.selectionProblem(plan, os.path.join(stage, "runtime"), target, proof["variant"], "cxx")


def peProblem(proof, mask, info, target):
    """Why a linked file is not the console executable or DLL of the proof for target under mask, or None. The ASan DLL
    is imported exactly when address is on, and the rest of the imports are system DLLs, api sets and the UCRT."""
    expected = pw.TARGETS[target]
    imports = {name.lower() for name in info["imports"]}
    dll = (san.ASAN_DLL_NAME % san.architecture(target)).lower()
    if info["machine"] != expected["machine"]:
        return "machine %#x is not %s" % (info["machine"], expected["machineName"])
    if bool(info["characteristics"] & pw.DLL_CHARACTERISTIC) != (proof["variant"] == "dll"):
        return "characteristics %#x do not match a %s" % (info["characteristics"], proof["variant"])
    if proof["variant"] == "exe" and info["subsystem"] != pw.SUBSYSTEM_CONSOLE:
        return "subsystem %d is not console" % info["subsystem"]
    if proof["variant"] == "dll" and proof["export"] not in info["exports"]:
        return "exports %s lack %s" % (info["exports"], proof["export"])
    if ("address" in sanitizers(mask)) != (dll in imports):
        return "imports %s %s %s, which address %s" % (sorted(imports), "lack" if dll not in imports else "hold", dll,
                                                       "needs" if "address" in sanitizers(mask) else "does not use")
    other = sorted(i for i in imports if i != dll and i not in pwc.SYSTEM_IMPORTS and not i.startswith("api-ms-win-"))
    if other or "kernel32.dll" not in imports or not any(i.startswith("api-ms-win-crt-") for i in imports):
        return "imports %s are not system DLLs and the UCRT (unexpected %s)" % (sorted(imports), other)
    return None


def checkTarget(run, stage, work, target):
    """Compile and link every proof of target, then check the references of the plain objects, the plans of the plain
    links, the bitcode of the LTO objects and the linked files. Any nonzero exit or stderr is an error. Returns
    {(proof, mask, mode): linked file}."""
    steps, outputs, plans = proofSteps(stage, work, target)
    for name, command in steps:
        pc.step(run, "%s %s" % (target, name), command)
    nm = pws.engineTool(stage, "llvm-nm")
    for (name, mask, mode), (obj, _) in sorted(outputs.items()):
        label = "%s %s %s %s" % (target, name, mask, mode)
        if mode == "plain":
            listing = pc.step(run, label + " symbols", [nm, "--undefined-only", obj]).stdout
            problem = referencesProblem(listing, PROOFS[name], mask)
            if problem:
                raise pe.EngineError("%s: %s" % (label, problem))
        else:
            with open(obj, "rb") as f:
                if f.read(4) not in pws.BITCODE_MAGICS:
                    raise pe.EngineError("%s: %s is not LTO bitcode" % (label, os.path.basename(obj)))
    for name, command, (proof, mask) in plans:
        plan = pc.step(run, "%s %s" % (target, name), command, stderr=True).stderr
        problem = selectionProblem(plan, stage, target, PROOFS[proof]) or planProblem(plan, stage, target, mask)
        if problem:
            raise pe.EngineError("%s %s: %s" % (target, name, problem))
    for (name, mask, mode), (_, path) in sorted(outputs.items()):
        problem = peProblem(PROOFS[name], mask, pw.readPe(path), target)
        if problem:
            raise pe.EngineError("%s %s %s %s: %s" % (target, name, mask, mode, problem))
    return {key: path for key, (_, path) in outputs.items()}


def checkControls(run, stage, work, targets, label):
    """{(target, variant): (include search list, object, linked file)} of the C control through the base config alone."""
    scratch = os.path.join(work, label)
    os.makedirs(scratch)
    return {(target, variant): pwc.controlResults(run, stage, scratch, target, variant)
            for target in targets for variant in pws.SOURCE_VARIANTS}


def controlProblem(before, after):
    """Why the C control changed when the sanitizer assets were installed, or None."""
    for key in sorted(before):
        for what, one, other in zip(("include list", "object", "linked file"), before[key], after[key]):
            if one != other:
                return "%s %s: the C control's %s changes with the sanitizer assets installed" % (key[0], key[1], what)
    return None


def checkInputs(engine, runtime):
    """(receipt, major) once the engine verifies and the sanitizer, C++ and C receipts describe the files of
    runtime and one cohort of the engine's version, with a synchronization archive in every variant; anything else is
    an error."""
    host, version, major = pr.engineMajor(engine)
    receipt, _ = pwc.readJson(runtime, san.PROVENANCE)
    problem = san.receiptProblem(receipt, runtime, runtime)
    if problem:
        raise pe.EngineError(problem)
    source = receipt["sources"]["llvm-project"]
    if (receipt.get("engineVersion"), receipt.get("cohort"), source.get("version"), source.get("major")) != (
            version, "llvm-%s-source" % version, version, major):
        raise pe.EngineError("the sanitizer receipt is for LLVM %s (cohort %s, engine %s), not the engine's LLVM %s" % (
            source.get("version"), receipt.get("cohort"), receipt.get("engineVersion"), version))
    san.inputReceipts(runtime, receipt["targets"], version, major, source["rev"])
    problem = san.synchronizationProblem(runtime, receipt["targets"])
    if problem:
        raise pe.EngineError(problem)
    return receipt, major


def stageRoot(engine, runtime, root, major):
    """The relocated tree at root: pws.stageTree's copy of the engine and runtime/windows, and beside them the files
    san.installResource reads from a runtime directory: the sanitizer and C++ receipts, the notices and the resource
    archives. Nothing is installed yet."""
    pws.stageTree(engine, os.path.join(runtime, "windows"), root, major)
    copy = os.path.join(root, "runtime")
    for relative in (san.PROVENANCE, pwc.PROVENANCE):
        linked = pws.linkedComponent(runtime, relative)
        if linked:
            raise pe.EngineError("%s is a link" % linked)
        os.makedirs(os.path.dirname(os.path.join(copy, *relative.split("/"))), exist_ok=True)
        shutil.copy2(os.path.join(runtime, *relative.split("/")), os.path.join(copy, *relative.split("/")))
    for relative in (san.NOTICE_ROOT, san.RESOURCE_ROOT):
        shutil.copytree(os.path.join(runtime, *relative.split("/")), os.path.join(copy, *relative.split("/")),
                        symlinks=True)


def hostRun(work):
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    return lambda command: subprocess.run(command, env=environment, cwd=work, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, universal_newlines=True)


def sandboxRun(engine, work, secrets):
    """(run, sandbox label): on macOS a sandbox that cannot read or execute the originals or any --deny path, elsewhere
    the host's own run with the sandbox labelled absent."""
    if sys.platform != "darwin":
        return hostRun(work), "none"
    profile = os.path.join(work, "deny.sb")
    pe.writeText(profile, "(version 1)(allow default)" + "".join(
        '(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (p, p) for p in secrets) + "\n")
    if pr.sandboxed(profile, work, [os.path.join(engine, "bin", "clang"), "--version"]).returncode == 0:
        raise pe.EngineError("sandbox does not deny the original engine")
    return (lambda command: pr.sandboxed(profile, work, command)), "macos"


def checkStage(run, root, work, targets, major):
    """The C control before and after san.installResource, the installed archives, and checkTarget for every target.
    Returns {(target, proof, mask, mode): linked file}."""
    before = checkControls(run, root, work, targets, "control-before")
    installed = san.installResource(os.path.join(root, "runtime"), os.path.join(root, "lib", "clang", major))
    expected = sorted(san.resourcePath(spec["name"]) for target in targets for spec in san.assetSpecs(target)
                      if spec["role"] != "asan-dll")
    if not set(expected) <= set(installed):
        raise pe.EngineError("installResource installed %s, not %s" % (sorted(installed), expected))
    problem = controlProblem(before, checkControls(run, root, work, targets, "control-after"))
    if problem:
        raise pe.EngineError(problem)
    found = {}
    for target in targets:
        scratch = os.path.join(work, "san-" + target)
        os.makedirs(scratch)
        found.update({(target,) + key: path for key, path in checkTarget(run, root, scratch, target).items()})
    return found


def prove(engine, runtime, denied, targets=None):
    """Relocate the engine and runtime, install the sanitizer resource archives into the copy and run checkStage for
    `targets` (every target of the sanitizer receipt when none). Prints what was inspected and what was not proven."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    if denied and sys.platform != "darwin":
        raise pe.EngineError("--deny is enforced by the macOS sandbox only and this host has none")
    receipt, major = checkInputs(engine, runtime)
    chosen = pw.selectWindowsTargets(targets) if targets else list(receipt["targets"])
    absent = [t for t in chosen if t not in receipt["targets"]]
    if absent:
        raise pe.EngineError("the sanitizer runtime has no %s" % ", ".join(absent))
    work = os.path.realpath(tempfile.mkdtemp(prefix="windows-sanitizer-proof-"))
    root = os.path.join(work, "relocated tree")
    try:
        stageRoot(engine, runtime, root, major)
        secrets = [engine, runtime] + [os.path.realpath(p) for p in denied]
        run, sandbox = sandboxRun(engine, work, secrets)
        outputs = checkStage(run, root, work, chosen, major)
        for (target, name, mask, mode), path in sorted(outputs.items()):
            with open(path, "rb") as f:
                data = f.read()
            leaked = [p for p in secrets if p.encode("utf-8") in data]
            if leaked:
                raise pe.EngineError("%s output %s %s %s holds source paths %s" % (target, name, mask, mode, leaked))
        for target in chosen:
            print("%s: %d linked files inspected (masks %s; plain, thin and full LTO)" % (
                target, sum(1 for k in outputs if k[0] == target), " | ".join(masks(target))))
        print("relocated=%s sandbox=%s" % (root, sandbox))
        print(LIMIT)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--target", action="append", default=[], help="a Windows target; every target when none")
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--execute", action="store_true", help="not implemented: this step links and inspects only")
    args = parser.parse_args(argv)
    if args.execute:
        parser.error("--execute is not implemented: this step compiles, links and inspects, and runs nothing")
    try:
        prove(args.engine, args.runtime, args.deny, args.target)
    except pe.EngineError as error:
        print("proveWindowsSanitizerRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
