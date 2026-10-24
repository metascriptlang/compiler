#!/usr/bin/env python3
"""Prepare the x86_64-windows-gnu runtime with a local Zig, then prove it with clang and lld alone.

    prepareWindowsRuntime.py --zig ZIG --engine ENGINE_DIR --output NEW_RUNTIME_DIR
    prepareWindowsRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--zig ZIG] [--deny PATH ...]

NEW_RUNTIME_DIR receives `windows/`; in a bundle the same directory is `runtime/windows/`, and the
engine is `../..` from it. Zig runs once for an executable and once for a DLL on fixtures, both in
one private cache, and the ordered inputs of each lld-link line it printed are copied opaquely
(`crt2.obj` or `dllcrt2.obj`, `libmingw32.lib` which differs between the two, the Zig and compiler
runtime archives, the import libraries). Two native clang configs result:

    windows/x86_64-windows-gnu.cfg       clang --config ... x.c / x.o -o x.exe
    windows/x86_64-windows-gnu.dll.cfg   clang --config ... x.c / x.o -o x.dll   (the config carries -shared)

Each config names its startup object as a linker input, which lld loads before the caller's object,
and its archives as `$-l` lines: clang appends those after every command-line input on a link and
leaves them out of a compile, so the archives follow the caller's objects and libraries in Zig's
order with no wrapper or change to the caller's command line. The caller's own `-lws2_32 -lmswsock
-lbcrypt` stay meaningful (a duplicate import library is harmless). `--sysroot` names the target
directory so the driver searches no host MinGW directory. The clang GNU driver picks `ld.lld`'s
MinGW mode itself.

Only the removed disabled CPU feature of prepareRuntime.REMOVED_DISABLED_FEATURES is left out of
the config; any other unknown feature stays and the proof fails on the engine's warning.

The payload is a local proof from an installed Zig, not an upstream-controlled build; its
provenance receipt says so and never certifies redistribution.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

import prepareEngine as pe
import prepareRuntime as pr

TARGET = "x86_64-windows-gnu"
ENGINE_RELATIVE = "../.."
PROVENANCE = "windows-provenance.json"
MACHINE_AMD64 = 0x8664
SUBSYSTEM_CONSOLE = 3
DLL_CHARACTERISTIC = 0x2000
LINK_IGNORED = ("-lldmingw", "-ERRORLIMIT:0", "-NOLOGO", "-DEBUG", "-BUILD-ID:NO", "-BREPRO", "-MACHINE:X64",
                "-MLLVM:-float-abi=hard")
LINK_PREFIXES = ("-PDB:", "-PDBALTPATH:", "-OUT:", "-IMPLIB:")
USER_LIBRARIES = ["-lws2_32", "-lbcrypt", "-lmswsock"]
LIBRARY_STEM = re.compile(r"^[A-Za-z0-9_.+-]+$")

VARIANTS = {
    "exe": {"fixture": "runtimeWindows.c", "zigArgs": [], "startup": "crt2.obj", "driverFlags": [],
            "directory": TARGET, "config": TARGET + ".cfg"},
    "dll": {"fixture": "runtimeWindowsDll.c", "zigArgs": ["-shared"], "startup": "dllcrt2.obj",
            "driverFlags": ["-shared"], "directory": TARGET + ".dll", "config": TARGET + ".dll.cfg"},
}
SPEC = {"clangTarget": None, "linker": "ld.lld",
        "notices": {"zig": ["../LICENSE"], "mingw-w64": ["libc/mingw/COPYING"]}}
LIMITS = ["no Windows execution was available: the executable and the DLL are linked and their PE headers, "
          "imports and exports inspected, never run",
          "x86_64 only; aarch64-windows-gnu is not prepared",
          "C++ (libc++) and LTO are not exercised for this target",
          "no archive is normalized: the C runtime inputs are copied as Zig produced them, so zigc.lib is "
          "not byte-reproducible across Zig caches"]


def selectWindowsLines(stderr, fixture, output):
    """The one compile line of the fixture and the one lld-link line that writes output."""
    compile_, link = [], []
    for line in stderr.splitlines():
        tokens = line.split()
        if tokens[1:3] == ["clang", fixture]:
            compile_.append(line)
        elif tokens[:1] and os.path.basename(tokens[0]) == "lld-link" and "-OUT:" + output in tokens:
            link.append(line)
    if len(compile_) != 1 or len(link) != 1:
        raise pe.EngineError("expected one compile and one link line, found %d and %d" % (
            len(compile_), len(link)))
    return compile_[0], link[0]


def parseCoffLinkArgv(line, objectName, cacheRoot, cwd):
    """Read a Zig lld-link line into {"dll", "stack", "base", "inputs", "notCarried"}. `inputs` are
    the real files after the fixture object, in order, each under cacheRoot. Every option is either
    carried, named as not carried, or an error."""
    found = {"dll": False, "stack": None, "base": None, "inputs": [], "notCarried": [], "user": 0}
    for token in line.split()[1:]:
        if token == "-DLL":
            found["dll"] = True
        elif token.startswith("-STACK:") and token[7:].isdigit():
            found["stack"] = int(token[7:])
        elif token.startswith("-BASE:") and token[6:].isdigit():
            found["base"] = int(token[6:])
        elif token.startswith("-ALTERNATENAME:"):
            found["notCarried"].append(token)
        elif token in LINK_IGNORED or token.startswith(LINK_PREFIXES):
            continue
        elif token.startswith("-"):
            raise pe.EngineError("lld-link option %s is not understood" % token)
        elif os.path.basename(token) == objectName:
            found["user"] += 1
        elif found["user"] != 1:
            raise pe.EngineError("link input %s comes before the fixture object" % token)
        else:
            real = os.path.realpath(os.path.join(cwd, token))
            if not os.path.isfile(real) or os.path.islink(os.path.join(cwd, token)):
                raise pe.EngineError("link input %s is not a regular file" % token)
            if os.path.commonpath([cacheRoot, real]) != cacheRoot:
                raise pe.EngineError("link input %s is not from this run's private cache" % token)
            found["inputs"].append(real)
    if found["user"] != 1:
        raise pe.EngineError("link line names the fixture object %s %d times" % (objectName, found["user"]))
    if found["base"] is None:
        raise pe.EngineError("link line has no -BASE")
    return found


def runZig(zig, variant, work, cache):
    """One Zig compile and link of the variant's fixture in the shared private cache. Returns
    (stderr, output, working directory)."""
    spec = VARIANTS[variant]
    private = os.path.join(work, variant)
    output = os.path.join(private, "fixture." + variant)
    os.makedirs(os.path.join(private, "local"))
    environment = {"PATH": "/usr/bin:/bin", "HOME": private, "TMPDIR": private,
                   "ZIG_GLOBAL_CACHE_DIR": cache, "ZIG_LOCAL_CACHE_DIR": os.path.join(private, "local"),
                   "ZIG_VERBOSE_CC": "1", "ZIG_VERBOSE_LINK": "1"}
    command = [zig, "cc", "-target", TARGET, "-O2"] + spec["zigArgs"] + [
        os.path.join(pr.FIXTURES, spec["fixture"])] + USER_LIBRARIES + ["-o", output]
    try:
        done = subprocess.run(command, cwd=private, env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True, timeout=pr.ZIG_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise pe.EngineError("zig timed out after %d s for %s %s" % (pr.ZIG_TIMEOUT_SECONDS, TARGET, variant))
    if done.returncode != 0:
        raise pe.EngineError("zig failed for %s %s (%d): %s" % (TARGET, variant, done.returncode, done.stderr.strip()))
    return done.stderr, output, private


def libraryTail(inputs, startup):
    """The `-l` stems of the archives after the startup object, in link order."""
    if os.path.basename(inputs[0]) != startup:
        raise pe.EngineError("first link input is %s, not %s" % (os.path.basename(inputs[0]), startup))
    stems = []
    for path in inputs[1:]:
        name = os.path.basename(path)
        if not name.endswith(".lib") or not LIBRARY_STEM.match(name[:-4]):
            raise pe.EngineError("link input %s is not a .lib with a plain name" % name)
        stems.append(name[:-4])
    for expected in ("libmingw32", "zigc", "compiler_rt"):
        if expected not in stems:
            raise pe.EngineError("link line has no %s.lib" % expected)
    return stems


def renderWindowsConfig(variant, compile_, link, directories, stems, major):
    """Text of RUNTIME/<config>. The common head is prepareRuntime.renderConfig's; the startup
    object is a linker input, the archives are `$-l` lines after every command-line input."""
    spec = dict(SPEC, driverFlags=VARIANTS[variant]["driverFlags"])
    directory = VARIANTS[variant]["directory"]
    text = pr.renderConfig(directory, spec, compile_, [], directories, ENGINE_RELATIVE, major)
    lines = [pr.configLine(["--sysroot=<CFGDIR>/" + directory]), pr.configLine(["-Xlinker", "--error-limit=0"])]
    if link["stack"] is not None:
        lines.append(pr.configLine(["-Xlinker", "--stack=%d" % link["stack"]]))
    lines.append(pr.configLine(["-Xlinker", "--image-base=0x%x" % link["base"]]))
    lines.append(pr.configLine(["-Xlinker", "--build-id=none"]))
    lines.append(pr.configLine(["-Xlinker", "<CFGDIR>/%s/%s" % (directory, pr.checkName(VARIANTS[variant]["startup"]))]))
    lines += ["$" + pr.configLine(["-l" + stem]) for stem in stems]
    return text + "\n".join(lines) + "\n"


def produceVariant(zig, variant, work, cache):
    spec = VARIANTS[variant]
    stderr, out, private = runZig(zig, variant, work, cache)
    compileLine, linkLine = selectWindowsLines(stderr, os.path.join(pr.FIXTURES, spec["fixture"]), out)
    link = parseCoffLinkArgv(linkLine, os.path.splitext(spec["fixture"])[0] + ".obj", os.path.realpath(cache), private)
    if link["dll"] != (variant == "dll"):
        raise pe.EngineError("%s link line has -DLL=%s" % (variant, link["dll"]))
    return pr.parseCompileArgv(compileLine), link, libraryTail(link["inputs"], spec["startup"])


def produceTarget(zig, zigVersion, engine, work, output, major):
    cache = os.path.join(work, "global")
    os.makedirs(cache)
    produced = {variant: produceVariant(zig, variant, work, cache) for variant in VARIANTS}
    first = produced["exe"][0]
    if produced["dll"][0]["isystem"] != first["isystem"]:
        raise pe.EngineError("the executable and the DLL compile lines name different include directories")
    zigLib = os.path.dirname(first["isystem"][0])
    if re.search(r"\s", zigLib):
        raise pe.EngineError("Zig lib directory %s has whitespace" % zigLib)
    directories, absent = pr.copyHeaders(first["isystem"], output, zigLib)
    records = []
    for variant, (compile_, link, stems) in produced.items():
        directory = VARIANTS[variant]["directory"]
        inputs = pr.copyInputs([("input", p) for p in link["inputs"]], output, directory, engine)
        carried, notCarried = pr.translateFeatures(compile_["features"], TARGET, compile_["cpu"], zigVersion, major)
        pe.writeText(os.path.join(output, VARIANTS[variant]["config"]),
                     renderWindowsConfig(variant, dict(compile_, features=carried), link, directories, stems, major))
        records.append({
            "variant": variant, "directory": directory, "config": VARIANTS[variant]["config"],
            "zigTarget": compile_["target"], "cpu": compile_["cpu"], "defines": compile_["defines"],
            "cpuFeatures": compile_["features"], "cpuFeaturesNotCarried": notCarried,
            "startupObject": VARIANTS[variant]["startup"], "libraryTail": stems,
            "stack": link["stack"], "imageBase": "0x%x" % link["base"],
            "zigLinkOptionsNotCarried": link["notCarried"], "inputs": inputs,
            "zigFlagsNotCarried": "debug info, -O level, -DNDEBUG, frame pointer and unwind flags, "
                                  "-DEBUG/-PDB/-BREPRO/-IMPLIB outputs (the caller asks for them)",
        })
    return directories, absent, records, pr.copyNotices(output, zigLib, SPEC)


def prepareWindowsRuntime(zig, engine, windows):
    """Write the Windows runtime to the new directory `windows`, whose engine is two levels up
    in a bundle. Returns (windows, records)."""
    zig, engine, windows = (os.path.abspath(p) for p in (zig, engine, windows))
    if os.path.lexists(windows):
        raise pe.EngineError("output %s exists; it is never replaced" % windows)
    if not os.access(zig, os.X_OK):
        raise pe.EngineError("--zig %s is not executable" % zig)
    host, version, major = pr.engineMajor(engine)
    zigId = pr.zigIdentity(zig)
    os.makedirs(os.path.dirname(windows), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(windows) + ".partial-", dir=os.path.dirname(windows))
    work = tempfile.mkdtemp(prefix="prepareWindowsRuntime-")
    try:
        directories, absent, records, notices = produceTarget(zig, zigId["version"], engine, work, partial, major)
        verifyConfigs(engine, partial, records, work)
        writeProvenance(partial, zigId, host, version, directories, absent, records, notices)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, windows)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return windows, records


def prepareRuntimeDirectory(zig, engine, output):
    """The standalone form: a new RUNTIME directory holding only `windows/`."""
    output = os.path.abspath(output)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        records = prepareWindowsRuntime(zig, engine, os.path.join(partial, "windows"))[1]
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return output, records


def writeProvenance(windows, zigId, host, engineVersion, directories, absent, records, notices):
    receipt = {
        "kind": "local-zig-windows-runtime-proof",
        "statement": "Produced by running a locally installed Zig once for an executable and once for a DLL on "
                     "fixtures. Not an upstream-controlled build and not bit-reproducible by this tool.",
        "redistributionCertified": False,
        "zig": zigId, "producerHost": host, "engineVersion": engineVersion,
        "target": TARGET, "engineRelative": ENGINE_RELATIVE,
        "includeDirectories": directories, "includeDirectoriesAbsentInZig": absent,
        "variants": records, "notices": notices, "limits": LIMITS,
        "linkerFlavor": "clang GNU driver, ld.lld in MinGW mode; no lld-link and no wrapper",
    }
    os.makedirs(os.path.join(windows, "notices"), exist_ok=True)
    pe.writeText(os.path.join(windows, "notices", PROVENANCE), json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def readPe(path):
    """Machine, subsystem, characteristics, imports {dll: [names]} and export names of a PE32+ file."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        raise pe.EngineError("%s is not a PE file" % path)
    base = struct.unpack_from("<I", data, 0x3c)[0]
    if data[base:base + 4] != b"PE\0\0":
        raise pe.EngineError("%s has no PE signature" % path)
    machine, count, _, _, _, optionalSize, characteristics = struct.unpack_from("<HHIIIHH", data, base + 4)
    optional = base + 24
    if struct.unpack_from("<H", data, optional)[0] != 0x20b:
        raise pe.EngineError("%s is not PE32+" % path)
    subsystem = struct.unpack_from("<H", data, optional + 68)[0]
    sections = [struct.unpack_from("<IIII", data, optional + optionalSize + 40 * i + 8) for i in range(count)]

    def offset(rva):
        for size, address, rawSize, raw in sections:
            if address <= rva < address + max(size, rawSize):
                return raw + rva - address
        raise pe.EngineError("%s: RVA %#x is in no section" % (path, rva))

    def text(rva):
        start = offset(rva)
        return data[start:data.index(b"\0", start)].decode("ascii")

    exportRva = struct.unpack_from("<I", data, optional + 112)[0]
    importRva = struct.unpack_from("<I", data, optional + 120)[0]
    exports, imports = [], {}
    if exportRva:
        table = offset(exportRva)
        nameCount, namesRva = struct.unpack_from("<I", data, table + 24)[0], struct.unpack_from("<I", data, table + 32)[0]
        exports = [text(struct.unpack_from("<I", data, offset(namesRva) + 4 * i)[0]) for i in range(nameCount)]
    cursor = offset(importRva) if importRva else None
    while cursor is not None:
        lookup, _, _, nameRva, thunks = struct.unpack_from("<IIIII", data, cursor)
        if not nameRva:
            break
        names, thunk = [], offset(lookup or thunks)
        while True:
            entry = struct.unpack_from("<Q", data, thunk)[0]
            if not entry:
                break
            names.append("#%d" % (entry & 0xffff) if entry >> 63 else text((entry & 0x7fffffff) + 2))
            thunk += 8
        imports[text(nameRva)] = names
        cursor += 20
    return {"machine": machine, "subsystem": subsystem, "characteristics": characteristics,
            "imports": imports, "exports": exports}


def peProblem(variant, info):
    """Why a linked file is not the x86_64 executable or DLL the variant promises, or None."""
    imports = {name.lower() for name in info["imports"]}
    if info["machine"] != MACHINE_AMD64:
        return "machine %#x is not AMD64" % info["machine"]
    isDll = bool(info["characteristics"] & DLL_CHARACTERISTIC)
    if isDll != (variant == "dll"):
        return "characteristics %#x do not match a %s" % (info["characteristics"], variant)
    if variant == "exe" and info["subsystem"] != SUBSYSTEM_CONSOLE:
        return "subsystem %d is not console" % info["subsystem"]
    if variant == "dll" and "addNumbers" not in info["exports"]:
        return "exports %s lack addNumbers" % info["exports"]
    missing = [d for d in ("ws2_32.dll", "bcrypt.dll", "kernel32.dll") if d not in imports]
    if missing or not any(d.startswith("api-ms-win-crt-") for d in imports):
        return "imports %s lack %s or the C runtime" % (sorted(imports), missing)
    return None


def checkWindowsConfig(run, clang, runtime, work, absentMacroPrefixes):
    """Compile and link both fixtures through their configs: the plain link, the link with the caller's
    own `-lws2_32 -lmswsock -lbcrypt` and `-shared` again, a DLL with an import library, and an executable
    with a PDB. Any nonzero exit or any stderr is an error. Returns {name: path of the linked file}."""
    outputs = {}
    for variant, spec in VARIANTS.items():
        config = ["--config", os.path.join(runtime, spec["config"])]
        fixture = os.path.join(pr.FIXTURES, spec["fixture"])
        obj = os.path.join(work, variant + ".o")
        suffix = ".dll" if variant == "dll" else ".exe"
        shared = ["-shared"] if variant == "dll" else []
        steps = [("compile", [clang] + config + ["-O2", "-c", fixture, "-o", obj]),
                 ("link", [clang] + config + [obj, "-o", os.path.join(work, variant + suffix)]),
                 ("link with the caller's libraries", [clang] + config + shared + [obj] + USER_LIBRARIES
                  + ["-o", os.path.join(work, variant + "Libs" + suffix)])]
        if variant == "dll":
            steps.append(("import library", [clang] + config + shared + [
                obj, "-Wl,--out-implib," + os.path.join(work, "dll.lib"), "-o", os.path.join(work, "dllImplib.dll")]))
        else:
            steps.append(("compile with debug info", [clang] + config + ["-O2", "-g", "-gcodeview", "-c", fixture,
                                                                         "-o", os.path.join(work, "exeDebug.o")]))
            steps.append(("pdb", [clang] + config + [os.path.join(work, "exeDebug.o"),
                                                     "-Wl,--pdb=" + os.path.join(work, "exe.pdb"),
                                                     "-o", os.path.join(work, "exePdb.exe")]))
        steps.append(("macros", [clang] + config + ["-dM", "-E", "-x", "c", "/dev/null"]))
        for name, command in steps:
            done = run(command)
            if done.returncode != 0:
                raise pe.EngineError("%s %s %s failed: %s" % (TARGET, variant, name, done.stderr.strip()))
            if done.stderr.strip():
                raise pe.EngineError("%s %s %s warned: %s" % (TARGET, variant, name, done.stderr.strip()))
        present = [p for p in absentMacroPrefixes if "#define " + p in done.stdout]
        if present:
            raise pe.EngineError("%s %s config defines %s macros" % (TARGET, variant, present))
        outputs[variant] = os.path.join(work, variant + suffix)
        outputs[variant + "Libs"] = os.path.join(work, variant + "Libs" + suffix)
    for name in ("dll.lib", "dllImplib.dll", "exe.pdb", "exePdb.exe"):
        if not os.path.isfile(os.path.join(work, name)):
            raise pe.EngineError("%s: %s was not written" % (TARGET, name))
    with open(os.path.join(work, "exe.pdb"), "rb") as f:
        if not f.read(32).startswith(b"Microsoft C/C++ MSF 7.00"):
            raise pe.EngineError("%s: exe.pdb is not a PDB" % TARGET)
    with open(os.path.join(work, "dll.lib"), "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise pe.EngineError("%s: dll.lib is not an import archive" % TARGET)
    for name in ("exe", "exeLibs", "dll", "dllLibs"):
        problem = peProblem(name[:3], readPe(outputs[name]))
        if problem:
            raise pe.EngineError("%s %s: %s" % (TARGET, name, problem))
    return outputs


def verifyConfigs(engine, windows, records, work):
    """checkWindowsConfig on a copy of the runtime two levels below an engine tree, the layout of a bundle."""
    root = os.path.join(work, "verify")
    runtime = os.path.join(root, "runtime")
    os.makedirs(runtime)
    shutil.copytree(windows, os.path.join(runtime, "windows"), symlinks=True)
    pr.linkEngineBeside(engine, root, runtime)
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    run = lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, universal_newlines=True)
    prefixes = sorted({e["absentMacroPrefix"] for r in records for e in r["cpuFeaturesNotCarried"]})
    checkWindowsConfig(run, os.path.join(root, "bin", "clang"), os.path.join(runtime, "windows"), work, prefixes)


def prove(engine, runtime, denied, zig=None):
    """Relocate the engine and RUNTIME (which holds `windows/`) to a path with a space, where the
    receipt's engineRelative puts them, and run checkWindowsConfig under a sandbox that cannot read the
    originals, Zig or any --deny path."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    pe.verifyEngine(engine)
    with open(os.path.join(runtime, "windows", "notices", PROVENANCE)) as f:
        receipt = json.load(f)
    if receipt["engineRelative"] != ENGINE_RELATIVE:
        raise pe.EngineError("receipt engineRelative %r is not %r" % (receipt["engineRelative"], ENGINE_RELATIVE))
    work = os.path.realpath(tempfile.mkdtemp(prefix="windows-proof-"))
    root = os.path.join(work, "relocated tree")
    shutil.copytree(engine, root, symlinks=True)
    if os.path.lexists(os.path.join(root, "runtime")):
        raise pe.EngineError("engine entry collides with the runtime")
    shutil.copytree(runtime, os.path.join(root, "runtime"), symlinks=True)
    secrets = [engine, runtime] + [os.path.realpath(p) for p in denied]
    if zig:
        secrets.append(os.path.dirname(os.path.realpath(zig)))
    profile = os.path.join(work, "deny.sb")
    pe.writeText(profile, "(version 1)(allow default)" + "".join(
        '(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (p, p) for p in secrets) + "\n")
    if pr.sandboxed(profile, work, [os.path.join(engine, "bin", "clang"), "--version"]).returncode == 0:
        raise pe.EngineError("sandbox does not deny the original engine")
    if zig and pr.sandboxed(profile, work, [os.path.realpath(zig), "version"]).returncode == 0:
        raise pe.EngineError("sandbox does not deny Zig")
    prefixes = sorted({e["absentMacroPrefix"] for r in receipt["variants"] for e in r["cpuFeaturesNotCarried"]})
    scratch = os.path.join(work, "out")
    os.makedirs(scratch)
    outputs = checkWindowsConfig(lambda command: pr.sandboxed(profile, work, command),
                                 os.path.join(root, "bin", "clang"), os.path.join(root, "runtime", "windows"),
                                 scratch, prefixes)
    for name, path in sorted(outputs.items()):
        with open(path, "rb") as f:
            data = f.read()
        leaked = [p for p in secrets if p.encode("utf-8") in data]
        if leaked:
            raise pe.EngineError("%s output %s holds source paths %s" % (TARGET, name, leaked))
        info = readPe(path)
        print("%s %s: AMD64 %s, imports %s%s; linked, not run" % (
            TARGET, name, "DLL" if info["characteristics"] & DLL_CHARACTERISTIC else "console exe",
            ",".join(sorted(info["imports"])), "; exports " + ",".join(info["exports"]) if info["exports"] else ""))
    print("%s: import library and PDB written; the caller's own -lws2_32 -lmswsock -lbcrypt link; Windows execution not proven" % TARGET)
    print("relocated=%s denied=%d zig=%s" % (root, len(secrets), "denied" if zig else "not given"))
    shutil.rmtree(work)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zig")
    parser.add_argument("--engine", required=True)
    parser.add_argument("--output")
    parser.add_argument("--runtime")
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--prove", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.prove:
            if not args.runtime:
                parser.error("--prove needs --runtime")
            prove(args.engine, args.runtime, args.deny, args.zig)
        else:
            if not (args.zig and args.output):
                parser.error("--zig and --output are required")
            output, records = prepareRuntimeDirectory(args.zig, args.engine, args.output)
            for record in records:
                print("%s: %d inputs, %d archives in the tail" % (
                    record["variant"], len(record["inputs"]), len(record["libraryTail"])))
            print("runtime written to %s" % output)
    except pe.EngineError as error:
        print("prepareWindowsRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
