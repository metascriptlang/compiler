#!/usr/bin/env python3
"""Compile, link and inspect programs with bare -fsanitize flags against the standard Windows sanitizer assets. By default
COMPILE/LINK INSPECTION ONLY: no program is run, so no runtime diagnostic, exit code or DLL load is proven; --execute runs
them natively.

    proveWindowsSanitizerRuntime.py --engine ENGINE_DIR --runtime RUNTIME_DIR [--target T ...] [--deny PATH ...] [--execute]

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

--execute runs, after all of that, only the target whose machine is the OS's native one (IsWow64Process2, never
platform.machine, which an emulated Python misreports) and only on Windows; with no such target among the chosen ones it
refuses before staging, and every other target stays compile/link only. The standalone ASan DLL is copied byte-identical
from the staged runtime/windows/<target>/bin beside the programs (a harness copy: no compiler directory, deployment or
PATH is touched), and the child inherits the parent's environment with PATH unchanged plus ASAN_SYMBOLIZER_PATH and
UBSAN_SYMBOLIZER_PATH naming the staged llvm-symbolizer.exe (MinGW -g is DWARF, which that tool reads and dbghelp does
not). Each executable runs plain, thin and full: the clean one must print its marker, exit 0 and report nothing; the
signed, vptr and heap ones must exit nonzero, name the right report at the fixture's basename and line and not reach
their marker, the heap ones with ASAN_OPTIONS=verbosity=2 and the symbolizer backend named on stderr. Each DLL is loaded
by a Unicode host (windowsSanitizerHost.c, built with the same mask through the C base config) that calls its export for
step 0 (clean), 1 (UBSan) and 2 (ASan, C only); a run takes 45 seconds at most.
--deny is enforced by the macOS sandbox only; elsewhere it is refused and the relocation, with a scan of the linked files
for the original paths, is all that is proven.
"""
import argparse
import ctypes
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
LIMIT_EXECUTED = ("executed natively for the targets marked as run only: their diagnostics, exit codes and DLL loads are "
                  "proven there; every other target is compile/link only, not run; no emulated run is claimed; the ASan DLL "
                  "was copied beside the programs by this harness, which does not prove a real application finds it")
FATAL = "-fno-sanitize-recover=undefined"
ASAN_ENTRY = "__asan_"
UBSAN_ENTRY = "__ubsan_handle_"
VPTR_ENTRY = "__ubsan_handle_dynamic_type_cache_miss"
ENTRIES = {"address": ASAN_ENTRY, "undefined": UBSAN_ENTRY}
INTERCEPTOR = "__asan_seh_interceptor"
RUN_TIMEOUT_SECONDS = 45
HOST = {"fixture": "windowsSanitizerHost.c", "variant": "exe"}
HOST_MARKER = "sanitizer host ok\n"
HOST_PREFIX = "windowsSanitizerHost:"
SYMBOLIZER = "llvm-symbolizer.exe"
SYMBOLIZER_EVIDENCE = re.compile(r"Using llvm-symbolizer at user-specified path: .*llvm-symbolizer(\.exe)?", re.I)
SANITIZER_VARIABLES = ("ASAN_OPTIONS", "UBSAN_OPTIONS", "LSAN_OPTIONS", "ASAN_SYMBOLIZER_PATH", "UBSAN_SYMBOLIZER_PATH")
REPORTS = {
    "signed": r"runtime error: signed integer overflow: 2147483647 \+ 1 cannot be represented in type 'int'",
    "vptr": r"runtime error: (?:member call on|downcast of) address 0x[0-9a-fA-F]+ which does not point to an object "
            r"of type 'Derived'",
}
SIGNED_STEP = {"sanitizer": "undefined", "report": "signed"}
VPTR_STEP = {"sanitizer": "undefined", "report": "vptr", "site": "static_cast<Derived *>(object)->value();"}
HEAP_STEP = {"sanitizer": "address", "report": "heap"}
PROOFS = {
    "clean": {"language": "c", "variant": "exe", "fixture": "windowsSanitizerClean.c", "needs": None, "fatal": False,
              "checks": ("address", "undefined"),
              "runs": [{"step": None, "sanitizer": None, "marker": "sanitizer clean ok\n"}]},
    "signed": {"language": "c", "variant": "exe", "fixture": "windowsSanitizerSigned.c", "needs": "undefined",
               "fatal": True, "checks": ("undefined",),
               "runs": [dict(SIGNED_STEP, step=None, site="int sum = big + argc;")]},
    "heap": {"language": "c", "variant": "exe", "fixture": "windowsSanitizerHeap.c", "needs": "address", "fatal": False,
             "checks": ("address",), "runs": [dict(HEAP_STEP, step=None, site="block[argc + 3] = 1;")]},
    "vptr": {"language": "c++", "variant": "exe", "fixture": "windowsSanitizerVptr.cpp", "needs": "undefined",
             "fatal": True, "checks": ("undefined",), "vptr": True, "runs": [dict(VPTR_STEP, step=None)]},
    "dll": {"language": "c", "variant": "dll", "fixture": "windowsSanitizerDll.c", "needs": None, "fatal": True,
            "checks": ("address", "undefined"), "export": "sanitizerCProbe",
            "runs": [{"step": 0, "sanitizer": None, "marker": HOST_MARKER, "expected": 0},
                     dict(SIGNED_STEP, step=1, site="int result = step == 1 ? big + step : 0;"),
                     dict(HEAP_STEP, step=2, site="block[step == 2 ? 4 : 3] = 1;")]},
    "cppdll": {"language": "c++", "variant": "dll", "fixture": "windowsSanitizerDll.cpp", "needs": None, "fatal": True,
               "checks": ("address", "undefined"), "export": "sanitizerCppProbe", "vptr": True,
               "runs": [{"step": 0, "sanitizer": None, "marker": HOST_MARKER, "expected": 2}, dict(VPTR_STEP, step=1)]},
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


MACHINE_TARGETS = {spec["machine"]: target for target, spec in pw.TARGETS.items()}


def hostMachines(kernel32=None):
    """(process machine, native machine) from IsWow64Process2: the process value is 0 unless this process is emulated, the
    native value is the machine of the OS. GetNativeSystemInfo and platform.machine are not used, because an emulated
    process is told the emulated machine. A kernel32 without the function (before Windows 10 version 1709) or a call
    that fails is an error: there is no fallback."""
    kernel32 = kernel32 or ctypes.WinDLL("kernel32", use_last_error=True)
    try:
        query, current = kernel32.IsWow64Process2, kernel32.GetCurrentProcess
    except AttributeError:
        raise pe.EngineError("kernel32 has no IsWow64Process2 (Windows 10 version 1709 or later): the native machine "
                             "cannot be told")
    current.restype, current.argtypes = ctypes.c_void_p, []
    query.restype = ctypes.c_int
    query.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)]
    process, native = ctypes.c_ushort(), ctypes.c_ushort()
    if not query(current(), ctypes.pointer(process), ctypes.pointer(native)):
        raise pe.EngineError("IsWow64Process2 failed with error %d" % ctypes.get_last_error())
    return process.value, native.value


def nativeTarget(chosen, kernel32=None):
    """(the one target of chosen whose machine is the OS's native one, whether this process is emulated); any other host
    or native machine is an error that names it."""
    if sys.platform != "win32":
        raise pe.EngineError("--execute needs a Windows host: this one is %s" % sys.platform)
    process, native = hostMachines(kernel32)
    target = MACHINE_TARGETS.get(native)
    if target is None:
        raise pe.EngineError("--execute: the native machine %#x is neither AMD64 nor ARM64" % native)
    if target not in chosen:
        raise pe.EngineError("--execute: the native machine is %s and %s is not among the chosen targets %s" % (
            pw.TARGETS[target]["machineName"], target, ", ".join(chosen)))
    return target, process != 0


def symbolizerPath(root):
    """The absolute path of root's llvm-symbolizer.exe in the form the runtime accepts: no `%`, no quote."""
    path = os.path.join(root, "bin", SYMBOLIZER)
    if not os.path.isfile(path):
        raise pe.EngineError("%s has no bin/%s" % (root, SYMBOLIZER))
    if not os.path.isabs(path) or "%" in path or '"' in path or path.endswith("\\"):
        raise pe.EngineError("the symbolizer path %s is not one the runtime accepts (absolute, no %% and no quote)" % path)
    return path


def proofEnvironment(environ, symbolizer, run):
    """The parent's environment, PATH and all, without any sanitizer variable of its own, plus the symbolizer paths and
    for a heap run verbosity 2, which prints the symbolizer backend."""
    environment = {key: value for key, value in environ.items() if key.upper() not in SANITIZER_VARIABLES}
    environment.update(ASAN_SYMBOLIZER_PATH=symbolizer, UBSAN_SYMBOLIZER_PATH=symbolizer)
    if run.get("report") == "heap":
        environment["ASAN_OPTIONS"] = "verbosity=2"
    return environment


def siteLine(proof, run):
    """The 1-based line of the proof's fixture that holds the site text of run, which must be on exactly one line."""
    with open(os.path.join(pr.FIXTURES, proof["fixture"]), encoding="utf-8") as f:
        lines = [number for number, line in enumerate(f.read().splitlines(), 1) if run["site"] in line]
    if len(lines) != 1:
        raise pe.EngineError("%s holds %r on %d lines, not one" % (proof["fixture"], run["site"], len(lines)))
    return lines[0]


def clip(text, size=600):
    return text if len(text) <= size else text[:size] + "..."


def runProblem(proof, run, result):
    """Why the outcome of one execution is not what run requires, or None. A clean run exits 0 with exactly its marker and
    no report. A failing one exits nonzero, never reaches a marker, shows its own sanitizer's report and not the other's
    at the fixture's basename and line (a frame without a source location does not count), and a heap one also names the
    llvm-symbolizer backend. The loader host's own failures are never a sanitizer's."""
    out, err = result.stdout, result.stderr
    if HOST_PREFIX in err:
        return "the loader host failed: %s" % clip(err.strip())
    reported = {"address": "ERROR: AddressSanitizer" in err, "undefined": "runtime error:" in err}
    sanitizer = run["sanitizer"]
    if sanitizer is None:
        if result.returncode != 0 or out != run["marker"] or any(reported.values()):
            return "a clean run exited %d with stdout %r and stderr %r, not 0 with %r and no report" % (
                result.returncode, clip(out), clip(err), run["marker"])
        return None
    if result.returncode == 0:
        return "exited 0 where it must fail (stdout %r, stderr %r)" % (clip(out), clip(err))
    if "unreachable" in out or HOST_MARKER in out:
        return "reached its marker: stdout %r" % clip(out)
    if not reported[sanitizer] or any(seen for other, seen in reported.items() if other != sanitizer):
        return "stderr does not hold the %s report alone: %s" % (sanitizer, clip(err))
    line = siteLine(proof, run)
    where = r"(?<![\w.-])%s:%d(?::\d+)?" % (re.escape(proof["fixture"]), line)
    if run["report"] == "heap":
        found = re.search(r"ERROR: AddressSanitizer: heap-buffer-overflow on address 0x[0-9a-fA-F]+", err) and re.search(
            r"(?m)^\s*#0 0x[0-9a-fA-F]+ in .*" + where + r"\s*$", err)
    else:
        found = re.search(r"(?m)^.*" + where + ": " + REPORTS[run["report"]], err)
    if not found:
        return "stderr has no %s report at %s:%d: %s" % (run["report"], proof["fixture"], line, clip(err))
    if run["report"] == "heap" and not SYMBOLIZER_EVIDENCE.search(err):
        return "stderr does not say llvm-symbolizer was used at the given path: %s" % clip(err)
    return None


def runProgram(command, environment, directory):
    try:
        return subprocess.run(command, env=environment, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              encoding="utf-8", errors="replace", timeout=RUN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise pe.EngineError("%s did not finish in %d seconds" % (os.path.basename(command[0]), RUN_TIMEOUT_SECONDS))


def copyAsanDll(root, target, directory):
    """(source, copy, sha256): the standalone ASan DLL of the staged runtime copied byte-identical into directory, beside
    the programs. A link on the way to the source, a missing source, an existing copy or a copy that differs is an error."""
    name = san.ASAN_DLL_NAME % san.architecture(target)
    relative = "windows/%s/bin/%s" % (target, name)
    runtime = os.path.join(root, "runtime")
    source, copy = os.path.join(runtime, *relative.split("/")), os.path.join(directory, name)
    linked = pws.linkedComponent(runtime, relative)
    if linked:
        raise pe.EngineError("%s is a link" % linked)
    if not os.path.isfile(source):
        raise pe.EngineError("the staged runtime has no %s" % relative)
    if os.path.lexists(copy):
        raise pe.EngineError("%s exists already beside the programs" % copy)
    digest = pe.sha256File(source)
    shutil.copyfile(source, copy)
    if pe.sha256File(copy) != digest:
        raise pe.EngineError("the copy %s differs from %s" % (copy, source))
    return source, copy, digest


def checkHost(run, stage, work, target, mask):
    """Compile and link the loader host with mask through the base config alone, check the driver's plan of that link (the
    wide startup object, and with address the import library before it) and the file's PE, and return the executable."""
    compiler = pws.engineTool(stage, "clang")
    config = pwc.baseFlags(os.path.join(stage, "runtime"), target, "exe")
    flags = ["-municode", "-fsanitize=" + mask]
    tag = os.path.join(work, "host-%s-plain" % mask.replace(",", "+"))
    label = "%s host %s" % (target, mask)
    pc.step(run, label + " compile", [compiler] + config + ["-g", "-O2", "-fsanitize=" + mask, "-c", os.path.join(
        pr.FIXTURES, HOST["fixture"]), "-o", tag + ".o"])
    pc.step(run, label + " link", [compiler] + config + flags + [tag + ".o", "-o", tag + ".exe"])
    plan = pc.step(run, label + " plan", [compiler] + config + flags + ["-###", tag + ".o", "-o", tag + "-plan.exe"],
                   stderr=True).stderr
    problem = (pws.selectionProblem(plan, os.path.join(stage, "runtime", "windows"), target, "wide")
               or planProblem(plan, stage, target, mask) or peProblem(HOST, mask, pw.readPe(tag + ".exe"), target))
    if problem:
        raise pe.EngineError("%s: %s" % (label, problem))
    return tag + ".exe"


def runCases(target, outputs, hosts):
    """[(label, command, proof, run)] for every execution of the linked files {(proof, mask, mode): path} of target that
    its mask can exercise: an executable with no argument, a DLL as the argument of the host built for its mask."""
    cases = []
    for (name, mask, mode), path in sorted(outputs.items()):
        proof = PROOFS[name]
        for run in proof["runs"]:
            if run["sanitizer"] is not None and run["sanitizer"] not in sanitizers(mask):
                continue
            command = [path] if proof["variant"] == "exe" else [hosts[mask], path, proof["export"], str(run["step"]),
                                                                 str(run.get("expected", 0))]
            step = "" if run["step"] is None else " step %d" % run["step"]
            cases.append(("%s %s %s %s%s" % (target, name, mask, mode, step), command, proof, run))
    return cases


def executeTarget(run, root, target, outputs, environ):
    """Run every case of target's linked files {(proof, mask, mode): path} natively: the ASan DLL copied beside them when
    a mask has address, one host per mask, the symbolizer of the staged engine in the environment. The copy and its source
    must hold the same hash after the runs as before. Returns the number of executions."""
    directories = {os.path.dirname(path) for path in outputs.values()}
    if len(directories) != 1:
        raise pe.EngineError("%s outputs are in %d directories, not one" % (target, len(directories)))
    directory = directories.pop()
    symbolizer = symbolizerPath(root)
    dll = copyAsanDll(root, target, directory) if any("address" in sanitizers(m) for m in masks(target)) else None
    hosts = {mask: checkHost(run, root, directory, target, mask) for mask in masks(target)}
    cases = runCases(target, outputs, hosts)
    for label, command, proof, spec in cases:
        problem = runProblem(proof, spec, runProgram(command, proofEnvironment(environ, symbolizer, spec), directory))
        if problem:
            raise pe.EngineError("%s: %s" % (label, problem))
    for path in dll[:2] if dll else []:
        if not os.path.isfile(path) or pe.isLinkLike(path) or pe.sha256File(path) != dll[2]:
            raise pe.EngineError("%s changed while the programs ran" % path)
    return len(cases)


def prove(engine, runtime, denied, targets=None, execute=False):
    """Relocate the engine and runtime, install the sanitizer resource archives into the copy and run checkStage for
    `targets` (every target of the sanitizer receipt when none). With execute the programs of the one chosen target whose
    machine is the OS's native one then run, and a host with none is refused before anything is staged. Prints what was
    inspected, what ran and what was not proven."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    if denied and sys.platform != "darwin":
        raise pe.EngineError("--deny is enforced by the macOS sandbox only and this host has none")
    receipt, major = checkInputs(engine, runtime)
    chosen = pw.selectWindowsTargets(targets) if targets else list(receipt["targets"])
    absent = [t for t in chosen if t not in receipt["targets"]]
    if absent:
        raise pe.EngineError("the sanitizer runtime has no %s" % ", ".join(absent))
    native = nativeTarget(chosen) if execute else None
    if execute:
        symbolizerPath(engine)
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
        ran = {}
        if execute:
            ran[native[0]] = executeTarget(run, root, native[0], {k[1:]: p for k, p in outputs.items() if k[0] == native[0]},
                                           os.environ)
        for target in chosen:
            print("%s: %d linked files inspected (masks %s; plain, thin and full LTO)%s" % (
                target, sum(1 for k in outputs if k[0] == target), " | ".join(masks(target)),
                "" if not execute else "; %d runs natively" % ran[target] if target in ran else "; not run"))
        print("relocated=%s sandbox=%s" % (root, sandbox))
        if execute:
            print("native machine %s; this process is %s" % (pw.TARGETS[native[0]]["machineName"],
                                                              "emulated" if native[1] else "not emulated"))
        print(LIMIT_EXECUTED if execute else LIMIT)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--target", action="append", default=[], help="a Windows target; every target when none")
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--execute", action="store_true",
                        help="also run the programs of the target the OS runs natively; Windows only")
    args = parser.parse_args(argv)
    try:
        prove(args.engine, args.runtime, args.deny, args.target, args.execute)
    except pe.EngineError as error:
        print("proveWindowsSanitizerRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
