#!/usr/bin/env python3
"""Prepare the C++ runtime of x86_64-linux-gnu.2.31 and x86_64-windows-gnu with a local Zig, then prove it with clang and lld alone.

    prepareCppRuntime.py --zig ZIG --engine ENGINE_DIR --runtime RUNTIME_DIR --output NEW_DIR [--target T ...] [--seed-cache DIR]
    prepareCppRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--zig ZIG] [--deny PATH ...]

RUNTIME_DIR is a bundle's `runtime/` whose C configs exist (prepareRuntime.py, prepareWindowsRuntime.py); it is
only read. NEW_DIR receives an overlay of new paths, each relative to RUNTIME_DIR, which prepareBundle.py merges:

    include/cxx/{libcxx,libcxxabi,libunwind}      the headers, shared by every target
    <target>.cxx/                                 the three archives and the aliases of their other spellings
    <target>.cxx.cfg  <target>.dll.cxx.cfg        one config per base config <name>.cfg (Windows has both)
    notices/cpp-provenance.json, notices/{libcxx,libcxxabi,libunwind}/LICENSE.TXT

Zig runs once per config on a C++ fixture with a private cache (`--seed-cache` copies the private cache of an
earlier run, which only skips building), and its compile and link lines give the defines, the include order and the
archives. A C++ compile or link names both configs, the C++ one first, and nothing else:

    clang++ --no-default-config --config=<name>.cxx.cfg --config=<name>.cfg x.cpp -o x

The C++ config puts libc++ and libc++abi before the C headers and libunwind after them (`-stdlib++-isystem`), carries
Zig's user-side defines (libc++ has no `__config_site`), searches its own `-L` directory and appends libc++abi,
libc++ and libunwind as link-only `$` inputs. Its archives live apart from the C runtime's, so a C link never
sees them and their `-L` shadows no C runtime file. Zig's link flag spellings `-lstdc++`, `-lsupc++`, `-lgcc_eh` and
`-lgcc_s` are files beside the archives. The base configs and the C runtime are not changed.

The payload is a local proof from an installed Zig, not an upstream-controlled build; its provenance receipt says so
and never certifies redistribution.
"""
import argparse
import hashlib
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
import prepareWindowsRuntime as pw

LINUX, WINDOWS = "x86_64-linux-gnu.2.31", pw.TARGET
PROVENANCE = "notices/cpp-provenance.json"
CXX_STANDARD = "-std=c++20"
CPP_DEFINES = ("-D_LIBCPP_", "-D_LIBCXXABI_")
HEADERS = {"libcxx": "libcxx/include", "libcxxabi": "libcxxabi/include", "libunwind": "libunwind/include"}
SPEC = {"notices": {name: [name + "/LICENSE.TXT"] for name in HEADERS}}
ARCHIVES = {LINUX: ["libc++abi.a", "libc++.a", "libunwind.a"], WINDOWS: ["c++abi.lib", "c++.lib", "unwind.lib"]}
LIBRARY_STEMS = ["c++abi", "c++", "unwind"]
OTHER_SPELLINGS = {"stdc++": "c++", "supc++": "c++abi", "gcc_eh": "unwind", "gcc_s": "unwind"}
DIRECTORIES = {LINUX: LINUX + ".cxx", WINDOWS: "windows/" + WINDOWS + ".cxx"}
VARIANTS = {
    (LINUX, "exe"): {"fixture": "runtimeCpp.cpp", "zigArgs": [], "zigLibraries": ["-lm", "-lpthread"],
                     "c": "runtimeLinux.c", "base": LINUX + ".cfg", "config": LINUX + ".cxx.cfg"},
    (WINDOWS, "exe"): {"fixture": "runtimeCpp.cpp", "zigArgs": [], "zigLibraries": pw.USER_LIBRARIES,
                       "c": "runtimeWindows.c", "base": "windows/%s.cfg" % WINDOWS,
                       "config": "windows/%s.cxx.cfg" % WINDOWS},
    (WINDOWS, "dll"): {"fixture": "runtimeCppDll.cpp", "zigArgs": ["-shared"], "zigLibraries": pw.USER_LIBRARIES,
                       "c": "runtimeWindowsDll.c", "base": "windows/%s.dll.cfg" % WINDOWS,
                       "config": "windows/%s.dll.cxx.cfg" % WINDOWS},
}
TARGETS = [LINUX, WINDOWS]
DRIVER_DEFAULT_CC1_FLAGS = ("-fcxx-exceptions", "-fexceptions", "-exception-model=seh", "-fno-sized-deallocation",
                            "-fno-use-init-array", "-fno-use-cxa-atexit")
ELF_NEEDED = {"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libutil.so.1",
              "libresolv.so.2", "ld-linux-x86-64.so.2"}
PE_IMPORTS = {"kernel32.dll", "ntdll.dll", "advapi32.dll", "shell32.dll", "user32.dll", "ws2_32.dll", "bcrypt.dll",
              "mswsock.dll"}
SEARCH_LIST = re.compile(r"#include <\.\.\.> search starts here:\n(.*?)End of search list\.", re.S)
LIMITS = ["no Linux or Windows execution was available: the executables and DLLs are linked and their ELF or PE "
          "headers, imports and exception tables inspected, never run",
          "x86_64-linux-gnu.2.31 and x86_64-windows-gnu only: the aarch64 and wasm32-wasi runtimes stay C only",
          "the Windows archives are copied as Zig produced them, so their member names hold the private cache paths of "
          "that run; the GNU archives are normalized like the C runtime's",
          "archive contents are not measured for bit-reproducibility across Zig caches",
          "the aliases are lower case; Zig ignores case in a Windows library name, the linker here does not",
          "the C++ config is a pair partner of the base config and is selected by the compiler, never found by the driver"]


def up(path):
    """The `../` steps from the directory of a runtime-relative path back to the runtime root."""
    return "../" * path.count("/")


def selectTargets(runtime, names):
    chosen = list(names) if names else [t for t in TARGETS if os.path.isfile(os.path.join(runtime, VARIANTS[(t, "exe")]["base"]))]
    for name in chosen:
        if name not in TARGETS:
            raise pe.EngineError("target %s has no C++ runtime; allowed: %s" % (name, ", ".join(TARGETS)))
    if not chosen or len(set(chosen)) != len(chosen):
        raise pe.EngineError("no C++ target, or a duplicate, in %s" % chosen)
    for key, spec in VARIANTS.items():
        if key[0] in chosen and not os.path.isfile(os.path.join(runtime, spec["base"])):
            raise pe.EngineError("%s has no base config %s to pair with" % (key[0], spec["base"]))
    return chosen


def splitIsystem(isystem):
    """(Zig lib directory, libc directory names) of the order libcxx, libcxxabi, builtin, libc..., libunwind."""
    zigLib = os.path.dirname(os.path.dirname(isystem[0]))
    expected = [os.path.join(zigLib, HEADERS["libcxx"]), os.path.join(zigLib, HEADERS["libcxxabi"]),
                os.path.join(zigLib, "include")]
    if isystem[:3] != expected or len(isystem) < 5 or isystem[-1] != os.path.join(zigLib, HEADERS["libunwind"]):
        raise pe.EngineError("C++ include order %s is not libcxx, libcxxabi, builtin, libc..., libunwind" % isystem)
    if re.search(r"\s", zigLib):
        raise pe.EngineError("Zig lib directory %s has whitespace" % zigLib)
    return zigLib, [os.path.basename(d) for d in isystem[3:-1]]


def cc1Flags(stderr, source):
    """Which of DRIVER_DEFAULT_CC1_FLAGS the cc1 line that compiled source carries."""
    for line in stderr.splitlines():
        tokens = line.split()
        if tokens[1:2] == ["-cc1"] and "-main-file-name" in tokens and tokens[tokens.index("-main-file-name") + 1] == source:
            return [flag for flag in DRIVER_DEFAULT_CC1_FLAGS if flag in tokens]
    raise pe.EngineError("Zig printed no cc1 line for %s" % source)


def splitArchives(inputs, names):
    """The paths of the archives in names, which must follow each other in that order among inputs."""
    found = [i for i, path in enumerate(inputs) if os.path.basename(path) in names]
    if [os.path.basename(inputs[i]) for i in found] != names or found != list(range(found[0], found[0] + len(names))):
        raise pe.EngineError("link inputs %s do not hold %s in a row" % ([os.path.basename(i) for i in inputs], names))
    return [inputs[i] for i in found]


def runZig(zig, target, variant, work, cache):
    """One Zig C++ compile and link of the variant's fixture in the shared private cache. Returns (stderr, output, directory)."""
    spec = VARIANTS[(target, variant)]
    private = os.path.join(work, target, variant)
    output = os.path.join(private, "fixture." + ("out" if target == LINUX else variant if variant == "dll" else "exe"))
    os.makedirs(os.path.join(private, "local"))
    environment = {"PATH": "/usr/bin:/bin", "HOME": private, "TMPDIR": private,
                   "ZIG_GLOBAL_CACHE_DIR": cache, "ZIG_LOCAL_CACHE_DIR": os.path.join(private, "local"),
                   "ZIG_VERBOSE_CC": "1", "ZIG_VERBOSE_LINK": "1"}
    command = [zig, "c++", "-target", target, "-O2", CXX_STANDARD, "-v"] + spec["zigArgs"] + [
        os.path.join(pr.FIXTURES, spec["fixture"])] + spec["zigLibraries"] + ["-o", output]
    try:
        done = subprocess.run(command, cwd=private, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=pr.ZIG_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise pe.EngineError("zig timed out after %d s for %s %s" % (pr.ZIG_TIMEOUT_SECONDS, target, variant))
    if done.returncode != 0:
        raise pe.EngineError("zig failed for %s %s (%d): %s" % (target, variant, done.returncode, done.stderr.strip()))
    return done.stderr, output, private


def produceVariant(zig, target, variant, work, cache):
    """Run Zig for one config. Returns the facts its lines give: defines, libc directories, link tokens, archive paths."""
    spec = VARIANTS[(target, variant)]
    stderr, output, private = runZig(zig, target, variant, work, cache)
    fixture = os.path.join(pr.FIXTURES, spec["fixture"])
    stem = os.path.splitext(spec["fixture"])[0]
    realCache = os.path.realpath(cache)
    if target == LINUX:
        compileLine, linkLine = pr.selectLines(stderr, fixture, output)
        linker, items = pr.parseLinkArgv(linkLine, output, stem + ".o", realCache)
        if linker != "ld.lld":
            raise pe.EngineError("%s linked with %s, expected ld.lld" % (target, linker))
        inputs = [value for kind, value in items if kind == "input"]
        tokens = [value if kind == "arg" else os.path.basename(value) for kind, value in items
                  if kind == "arg" or (kind == "input" and os.path.basename(value) not in ARCHIVES[target])]
    else:
        compileLine, linkLine = pw.selectWindowsLines(stderr, fixture, output)
        link = pw.parseCoffLinkArgv(linkLine, stem + ".obj", realCache, private)
        if link["dll"] != (variant == "dll"):
            raise pe.EngineError("%s %s link line has -DLL=%s" % (target, variant, link["dll"]))
        inputs = link["inputs"]
        tokens = [os.path.basename(p) for p in inputs if os.path.basename(p) not in ARCHIVES[target]]
    compile_ = pr.parseCompileArgv(compileLine)
    zigLib, libc = splitIsystem(compile_["isystem"])
    return {"zigLib": zigLib, "libc": libc, "tokens": tokens, "archives": splitArchives(inputs, ARCHIVES[target]),
            "defines": [d for d in compile_["defines"] if d.startswith(CPP_DEFINES)],
            "definesInBase": [d for d in compile_["defines"] if not d.startswith(CPP_DEFINES)],
            "cc1": cc1Flags(stderr, spec["fixture"])}


def subsequence(wanted, available):
    """The items of wanted, in order, among available."""
    remaining = iter(available)
    return all(item in remaining for item in wanted)


def baseTokens(text):
    """What a base config hands the linker, as tokens comparable with Zig's link line: option words, input file names."""
    tokens = []
    for line in text.splitlines():
        if line.startswith("-Xlinker "):
            value = line[len("-Xlinker "):]
            tokens.append(os.path.basename(value) if value.startswith("<CFGDIR>/") else value)
        elif line.startswith("$-l"):
            tokens.append(line[3:] + ".lib")
    return tokens


def crossCheck(variant, base):
    """The facts of Zig's C++ line agree with the C config the C++ config pairs with: nothing Zig passes is dropped."""
    lines = base.splitlines()
    libc = [l.split("/")[-1] for l in lines if l.startswith("-isystem <CFGDIR>/include/libc/")]
    if not subsequence(libc, variant["libcDirectories"]):
        raise pe.EngineError("%s %s: base libc directories %s are not in Zig's C++ order %s" % (
            variant["target"], variant["variant"], libc, variant["libcDirectories"]))
    missing = [d for d in variant["definesInBase"] if d not in lines]
    if missing:
        raise pe.EngineError("%s %s: Zig's C++ line defines %s, the base config does not" % (
            variant["target"], variant["variant"], missing))
    if not subsequence(variant["linkTokens"], baseTokens(base)):
        raise pe.EngineError("%s %s: Zig's C++ link tokens %s are not in the base config's order" % (
            variant["target"], variant["variant"], variant["linkTokens"]))


def renderConfig(target, variant, defines):
    """Text of RUNTIME/<config>: headers, defines, the late libunwind include, the archive directory and the link tail."""
    config = VARIANTS[(target, variant)]["config"]
    include = "<CFGDIR>/%sinclude/cxx/" % up(config)
    lines = [pr.configLine(["-isystem", include + "libcxx"]), pr.configLine(["-isystem", include + "libcxxabi"])]
    lines += [pr.configLine([d]) for d in defines]
    lines.append(pr.configLine(["-stdlib++-isystem", include + "libunwind"]))
    lines.append(pr.configLine(["-Xlinker", "-L", "-Xlinker", "<CFGDIR>/" + os.path.relpath(
        DIRECTORIES[target], os.path.dirname(config) or ".")]))
    lines += ["$" + pr.configLine(["-l" + stem]) for stem in LIBRARY_STEMS]
    return "\n".join(lines) + "\n"


def archiveSymbols(engine, path):
    """The defined external symbols of an archive as sorted (type, name), whatever its member names."""
    found = []
    for line in pe.run([os.path.join(engine, "bin", "llvm-nm"), "--defined-only", "--extern-only", path]).splitlines():
        words = line.split()
        if len(words) == 3:
            found.append((words[1], words[2]))
    return sorted(found)


def copyArchives(engine, target, paths, output):
    """Copy a target's archives in link order, the GNU ones normalized only while their symbols stay the same."""
    records = pr.copyInputs([("input", p) for p in paths], output, DIRECTORIES[target], engine)
    if target == LINUX:
        for path, record in zip(paths, records):
            if archiveSymbols(engine, path) != archiveSymbols(engine, os.path.join(output, DIRECTORIES[target], record["name"])):
                raise pe.EngineError("normalizing %s changed its symbols" % record["name"])
    return records


def linkAliases(directory, names):
    """Give each other spelling of a library a relative symlink to its file. Returns [{"alias", "target"}]."""
    files = {n[len("lib"):-len(".a")] if n.endswith(".a") else n[:-len(".lib")]: n for n in names}
    records = []
    for alias, stem in OTHER_SPELLINGS.items():
        target = files[stem]
        name = ("lib%s.a" if target.endswith(".a") else "%s.lib") % alias
        if os.path.lexists(os.path.join(directory, name)):
            raise pe.EngineError("%s: alias %s collides with an existing file" % (directory, name))
        os.symlink(target, os.path.join(directory, name))
        records.append({"alias": name, "target": target})
    pr.verifyLibraryAliases(directory, records)
    return records


def treeDigest(root):
    lines = ["%s  %s\n" % (pe.sha256File(os.path.join(d, n)), os.path.relpath(os.path.join(d, n), root))
             for d, _, names in os.walk(root) for n in names]
    return {"files": len(lines), "sha256": hashlib.sha256("".join(sorted(lines)).encode()).hexdigest()}


def overlayFiles(root):
    """Every file and symlink of root as a runtime-relative path, sorted."""
    return sorted(os.path.relpath(os.path.join(d, n), root) for d, _, names in os.walk(root) for n in names)


def seedCache(seed, cache):
    """A private copy of an earlier run's cache; the shared Zig cache is never one."""
    seed = os.path.realpath(seed)
    if not os.path.isdir(seed) or os.path.realpath(os.path.expanduser("~/.cache/zig")) in (seed, os.path.dirname(seed)):
        raise pe.EngineError("--seed-cache %s is not a private cache directory" % seed)
    shutil.copytree(seed, cache, symlinks=True)


def produce(zig, engine, targets, work, output, seed):
    """Run Zig for every config of targets and write the overlay into output. Returns (variant records, archive records, sources)."""
    cache = os.path.join(work, "global")
    if seed:
        seedCache(seed, cache)
    else:
        os.makedirs(cache)
    produced = {key: produceVariant(zig, key[0], key[1], work, cache) for key in VARIANTS if key[0] in targets}
    zigLibs = {p["zigLib"] for p in produced.values()}
    if len(zigLibs) != 1:
        raise pe.EngineError("the configs name different Zig lib directories %s" % sorted(zigLibs))
    zigLib = zigLibs.pop()
    for name, relative in HEADERS.items():
        pr.copyTree(os.path.join(zigLib, relative), os.path.join(output, "include", "cxx", name))
    archives, variants = {}, []
    for target in targets:
        first = produced[(target, "exe")]["archives"]
        for key, facts in produced.items():
            if key[0] == target and [pe.sha256File(p) for p in facts["archives"]] != [pe.sha256File(p) for p in first]:
                raise pe.EngineError("%s %s links other C++ archives than the executable" % key)
        records = copyArchives(engine, target, first, output)
        archives[target] = {"directory": DIRECTORIES[target], "inputs": records,
                            "aliases": linkAliases(os.path.join(output, DIRECTORIES[target]), [r["name"] for r in records])}
    for (target, variant), facts in produced.items():
        spec = VARIANTS[(target, variant)]
        pe.writeText(os.path.join(output, spec["config"]), renderConfig(target, variant, facts["defines"]))
        variants.append({"target": target, "variant": variant, "config": spec["config"], "base": spec["base"],
                         "directory": DIRECTORIES[target], "defines": facts["defines"],
                         "definesInBase": facts["definesInBase"], "libcDirectories": facts["libc"],
                         "linkTokens": facts["tokens"], "zigCc1Flags": facts["cc1"],
                         "libraries": [os.path.basename(p) for p in facts["archives"]]})
    return variants, archives, {"zigLib": zigLib, "notices": pr.copyNotices(output, zigLib, SPEC)}


def mergeOverlay(overlay, runtime):
    """Copy every file of overlay into runtime at its relative path; a path runtime already has is refused."""
    files = overlayFiles(overlay)
    taken = [f for f in files if os.path.lexists(os.path.join(runtime, f))]
    if taken:
        raise pe.EngineError("%s already has %s" % (runtime, taken))
    for relative in files:
        target = os.path.join(runtime, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(overlay, relative), target, follow_symlinks=False)


def readElf(path):
    """DT_NEEDED names and whether a PT_GNU_EH_FRAME header exists, from a little-endian ELF64 file."""
    with open(path, "rb") as f:
        data = f.read()
    number = lambda at, size: int.from_bytes(data[at:at + size], "little")
    loads, dynamic, ehFrame = [], None, False
    for i in range(number(56, 2)):
        header = number(32, 8) + i * number(54, 2)
        kind, offset, address, size = number(header, 4), number(header + 8, 8), number(header + 16, 8), number(header + 32, 8)
        if kind == 1:
            loads.append((address, offset, size))
        elif kind == 2:
            dynamic = (offset, size)
        elif kind == 0x6474e550:
            ehFrame = True
    needed, strings = [], None
    for at in range(dynamic[0], dynamic[0] + dynamic[1], 16) if dynamic else []:
        tag, value = number(at, 8), number(at + 8, 8)
        if tag == 5:
            strings = next(o + value - a for a, o, s in loads if a <= value < a + s)
        elif tag == 1:
            needed.append(value)
    return [data[strings + n:data.index(b"\0", strings + n)].decode("ascii") for n in needed], ehFrame


def elfCppProblem(path, nm):
    """Why a linked GNU executable is not a glibc C++ executable with unwind tables, or None."""
    problem = pr.elfProblem(path, LINUX) or pr.elfInterpreterProblem(path, LINUX) or pr.glibcSymbolProblem(nm, path)
    if problem:
        return problem
    needed, ehFrame = readElf(path)
    if "libc.so.6" not in needed or not set(needed) <= ELF_NEEDED:
        return "dynamic dependencies %s are not glibc's" % needed
    return None if ehFrame else "no PT_GNU_EH_FRAME header"


def peCppProblem(path, variant):
    """Why a linked file is not an x86_64 Windows executable or DLL on the C runtime with an exception table, or None."""
    info = pw.readPe(path)
    imports = {n.lower() for n in info["imports"]}
    if info["machine"] != pw.MACHINE_AMD64 or bool(info["characteristics"] & pw.DLL_CHARACTERISTIC) != (variant == "dll"):
        return "machine %#x characteristics %#x are not an x86_64 %s" % (info["machine"], info["characteristics"], variant)
    if variant == "exe" and info["subsystem"] != pw.SUBSYSTEM_CONSOLE:
        return "subsystem %d is not console" % info["subsystem"]
    if variant == "dll" and "cppSum" not in info["exports"]:
        return "exports %s lack cppSum" % info["exports"]
    other = sorted(i for i in imports if i not in PE_IMPORTS and not i.startswith("api-ms-win-crt-"))
    if other or "kernel32.dll" not in imports or not any(i.startswith("api-ms-win-crt-") for i in imports):
        return "imports %s are not the system and the universal C runtime (unexpected %s)" % (sorted(imports), other)
    with open(path, "rb") as f:
        data = f.read()
    exceptionTable = struct.unpack_from("<I", data, struct.unpack_from("<I", data, 0x3c)[0] + 24 + 136)[0]
    return None if exceptionTable else "no exception table"


def step(run, name, command, stderr=False):
    done = run(command)
    if done.returncode != 0 or (done.stderr.strip() and not stderr):
        raise pe.EngineError("%s failed (%d) or warned: %s" % (name, done.returncode, done.stderr.strip()))
    return done


def searchList(text, root):
    """The include search list of a `-E -v` run with the tree root replaced."""
    found = SEARCH_LIST.search(text)
    if not found:
        raise pe.EngineError("no include search list in %s" % text)
    return [os.path.normpath(line.strip().replace(root, "$ROOT")) for line in found.group(1).splitlines() if line.strip()]


def checkControl(run, merged, control, work, variant):
    """The C fixture through the base config alone: the include list, the object and the linked file are the same
    with the C++ overlay as without it."""
    spec = VARIANTS[(variant["target"], variant["variant"])]
    results = []
    for root in (merged, control):
        scratch = os.path.join(work, "control-%s-%s-%s" % (variant["target"], variant["variant"], os.path.basename(os.path.dirname(root))[:7]))
        os.makedirs(scratch)
        clang = os.path.join(os.path.dirname(root), "bin", "clang")
        config = ["--no-default-config", "--config=" + os.path.join(root, spec["base"])]
        obj, out = os.path.join(scratch, "c.o"), os.path.join(scratch, "c.out")
        fixture = os.path.join(pr.FIXTURES, spec["c"])
        listing = step(run, "C include list", [clang] + config + ["-E", "-v", "-x", "c", "/dev/null"], stderr=True).stderr
        step(run, "C compile", [clang] + config + ["-O2", "-c", fixture, "-o", obj])
        step(run, "C link", [clang] + config + (["-Wl,--no-insert-timestamp"] if variant["target"] == WINDOWS else [])
             + [obj, "-o", out])
        with open(obj, "rb") as f, open(out, "rb") as g:
            results.append((searchList(listing, os.path.dirname(root)), f.read(), g.read()))
    for name, withOverlay, without in zip(("include list", "object", "linked file"), results[0], results[1]):
        if withOverlay != without:
            raise pe.EngineError("%s %s: the C %s changes with the C++ overlay" % (variant["target"], variant["variant"], name))


def checkVariant(run, merged, work, variant, inspect):
    """Compile and link the C++ fixtures through the config pair; check the include order, the exception defaults and
    the outputs. Returns {name: path of each linked file}."""
    root = os.path.dirname(merged)
    spec = VARIANTS[(variant["target"], variant["variant"])]
    windows, dll = variant["target"] == WINDOWS, variant["variant"] == "dll"
    pair = ["--no-default-config", "--config=" + os.path.join(merged, spec["config"]),
            "--config=" + os.path.join(merged, spec["base"])]
    clangxx, clang = os.path.join(root, "bin", "clang++"), os.path.join(root, "bin", "clang")
    suffix = ".dll" if dll else ".exe" if windows else ".out"
    fixture = os.path.join(pr.FIXTURES, spec["fixture"])
    scratch = os.path.join(work, "cpp-%s-%s" % (variant["target"], variant["variant"]))
    os.makedirs(scratch)
    path = lambda name: os.path.join(scratch, name)
    caller = pw.USER_LIBRARIES if windows else ["-lm", "-lpthread"]
    step(run, "C++ compile", [clangxx] + pair + [CXX_STANDARD, "-O2", "-c", fixture, "-o", path("x.o")])
    step(run, "C++ link", [clangxx] + pair + [path("x.o"), "-o", path("plain" + suffix)])
    step(run, "C++ link with the caller's libraries and a written -lc++",
         [clangxx] + pair + [path("x.o")] + caller + ["-lc++", "-o", path("written" + suffix)])
    outputs = {"plain": path("plain" + suffix), "written": path("written" + suffix)}
    listing = step(run, "include order", [clangxx] + pair + ["-E", "-v", "-x", "c++", "/dev/null"], stderr=True).stderr
    entries = searchList(listing, root)
    cxx = ["$ROOT/runtime/include/cxx/" + n for n in ("libcxx", "libcxxabi")]
    libc = [e for e in entries if "/include/libc/" in e]
    order = [entries.index(e) for e in cxx + libc + ["$ROOT/runtime/include/cxx/libunwind"] if e in entries]
    if len(order) != 3 + len(libc) or order != sorted(order) or order[:2] != [0, 1] or any(
            not e.startswith("$ROOT/") for e in entries):
        raise pe.EngineError("%s %s include order %s is not libcxx, libcxxabi, libc..., libunwind" % (
            variant["target"], variant["variant"], entries))
    flags = step(run, "exception defaults", [clangxx] + pair + ["-###", "-c", fixture, "-o", path("flags.o")],
                 stderr=True).stderr
    cc1 = next((l.split() for l in flags.splitlines() if '"-cc1"' in l.split()), None)
    engineFlags = [f for f in DRIVER_DEFAULT_CC1_FLAGS if cc1 and '"%s"' % f in cc1]
    if engineFlags != variant["zigCc1Flags"]:
        raise pe.EngineError("%s %s: the engine's C++ defaults %s differ from Zig's %s" % (
            variant["target"], variant["variant"], engineFlags, variant["zigCc1Flags"]))
    if not dll:
        step(run, "archive C++ compile", [clangxx] + pair + [CXX_STANDARD, "-O2", "-c",
                                                             os.path.join(pr.FIXTURES, "cppArchive.cpp"), "-o", path("a.o")])
        step(run, "archive", [os.path.join(root, "bin", "llvm-ar"), "--format=gnu", "crs", path("libclient.a"), path("a.o")])
        step(run, "C client compile", [clang, "--no-default-config", "--config=" + os.path.join(merged, spec["base"]),
                                       "-O2", "-c", os.path.join(pr.FIXTURES, "cppArchiveClient.c"), "-o", path("client.o")])
        spellings = ["-l" + s for s in ("c++",) + tuple(OTHER_SPELLINGS) + ("c++abi", "unwind")]
        for name, libraries in (("client", ["-lc++"]), ("client with every spelling", spellings)):
            binary = path("client%d%s" % (len(libraries), suffix))
            step(run, "archive-only C " + name, [clang] + pair + [path("client.o"), path("libclient.a")] + libraries
                 + ["-o", binary])
            outputs[name] = binary
    for name, binary in outputs.items():
        problem = inspect(binary, variant)
        if problem:
            raise pe.EngineError("%s %s %s: %s" % (variant["target"], variant["variant"], name, problem))
    return outputs


def inspectBinary(nm):
    def inspect(binary, variant):
        return elfCppProblem(binary, nm) if variant["target"] == LINUX else peCppProblem(binary, variant["variant"])
    return inspect


def checkOverlay(run, merged, control, work, receipt):
    """Every variant of receipt: the structure against its base config, the C control, the C++ links. Returns the outputs."""
    outputs = {}
    inspect = inspectBinary(os.path.join(os.path.dirname(merged), "bin", "llvm-nm"))
    for variant in receipt["variants"]:
        with open(os.path.join(merged, variant["base"]), encoding="utf-8") as f:
            crossCheck(variant, f.read())
        checkControl(run, merged, control, work, variant)
        outputs[(variant["target"], variant["variant"])] = checkVariant(run, merged, work, variant, inspect)
    return outputs


def writeProvenance(overlay, zigId, host, engineVersion, targets, variants, archives, sources, seeded):
    receipt = {
        "kind": "local-zig-cpp-runtime-proof",
        "statement": "Produced by running a locally installed Zig once per C++ config on a fixture. "
                     "Not an upstream-controlled build and not bit-reproducible by this tool.",
        "redistributionCertified": False,
        "zig": zigId, "producerHost": host, "engineVersion": engineVersion, "targets": targets,
        "seededFromCache": seeded, "cxxStandard": CXX_STANDARD,
        "headers": {name: treeDigest(os.path.join(overlay, "include", "cxx", name)) for name in HEADERS},
        "notices": sources["notices"], "archives": archives, "variants": variants,
        "files": overlayFiles(overlay), "limits": LIMITS,
    }
    os.makedirs(os.path.join(overlay, os.path.dirname(PROVENANCE)), exist_ok=True)
    pe.writeText(os.path.join(overlay, PROVENANCE), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def verifyTrees(engine, runtime, overlay, work):
    """Two trees shaped like a bundle, the runtime with the overlay merged and as it is, each with the engine beside it.
    Returns (merged runtime, control runtime)."""
    trees = []
    for name in ("merged", "control"):
        root = os.path.join(work, name)
        copy = os.path.join(root, "runtime")
        os.makedirs(root)
        shutil.copytree(runtime, copy, symlinks=True)
        pr.linkEngineBeside(engine, root, copy)
        trees.append(copy)
    mergeOverlay(overlay, trees[0])
    return trees


def prepareCppRuntime(zig, engine, runtime, output, targets=None, seed=None):
    """Write the C++ overlay of `targets` (every target whose base config exists when none) to the new directory
    `output`, proven on copies of `runtime` with the engine beside it. Returns (output, receipt)."""
    zig, engine, runtime, output = (os.path.abspath(p) for p in (zig, engine, runtime, output))
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    if not os.access(zig, os.X_OK):
        raise pe.EngineError("--zig %s is not executable" % zig)
    host, version, _ = pr.engineMajor(engine)
    targets = selectTargets(runtime, targets)
    zigId = pr.zigIdentity(zig)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    work = os.path.realpath(tempfile.mkdtemp(prefix="prepareCppRuntime-"))
    try:
        variants, archives, sources = produce(zig, engine, targets, work, partial, seed)
        receipt = writeProvenance(partial, zigId, host, version, targets, variants, archives, sources, bool(seed))
        merged, control = verifyTrees(engine, runtime, partial, work)
        environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
        checkOverlay(lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                                                    stderr=subprocess.PIPE, universal_newlines=True),
                     merged, control, work, receipt)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return output, receipt


def addCppRuntime(zig, engine, runtime, targets=None, seed=None):
    """prepareCppRuntime for `runtime`, then merge its overlay into it. Returns the receipt."""
    scratch = tempfile.mkdtemp(prefix="cppOverlay-", dir=os.path.dirname(os.path.abspath(runtime)))
    try:
        overlay, receipt = prepareCppRuntime(zig, engine, runtime, os.path.join(scratch, "overlay"), targets, seed)
        mergeOverlay(overlay, runtime)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return receipt


def prove(engine, runtime, denied, zig=None):
    """Relocate the engine and its `runtime` child, which holds the overlay, to a path with a space and run checkOverlay
    under a sandbox that cannot read the originals, Zig or any --deny path. The control is the relocated runtime with
    the overlay's files removed."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    pe.verifyEngine(engine)
    if runtime != os.path.join(engine, "runtime"):
        raise pe.EngineError("runtime %s is not the `runtime` child of engine %s" % (runtime, engine))
    with open(os.path.join(runtime, PROVENANCE), encoding="utf-8") as f:
        receipt = json.load(f)
    work = os.path.realpath(tempfile.mkdtemp(prefix="cpp-runtime-proof-"))
    root = os.path.join(work, "relocated tree")
    shutil.copytree(engine, root, symlinks=True)
    secrets = [engine] + [os.path.realpath(p) for p in denied] + ([os.path.dirname(os.path.realpath(zig))] if zig else [])
    profile = os.path.join(work, "deny.sb")
    pe.writeText(profile, "(version 1)(allow default)" + "".join(
        '(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (p, p) for p in secrets) + "\n")
    if pr.sandboxed(profile, work, [os.path.join(engine, "bin", "clang"), "--version"]).returncode == 0:
        raise pe.EngineError("sandbox does not deny the original engine")
    if zig and pr.sandboxed(profile, work, [os.path.realpath(zig), "version"]).returncode == 0:
        raise pe.EngineError("sandbox does not deny Zig")
    controlRoot = os.path.join(work, "control tree")
    controlRuntime = os.path.join(controlRoot, "runtime")
    shutil.copytree(os.path.join(root, "runtime"), controlRuntime, symlinks=True)
    for relative in receipt["files"] + [PROVENANCE]:
        os.remove(os.path.join(controlRuntime, relative))
    engineView = os.path.join(work, "engine view")
    os.makedirs(engineView)
    for name in os.listdir(root):
        if name != "runtime":
            os.symlink(os.path.join(root, name), os.path.join(engineView, name))
    pr.linkEngineBeside(engineView, controlRoot, controlRuntime)
    outputs = checkOverlay(lambda command: pr.sandboxed(profile, work, command), os.path.join(root, "runtime"),
                           controlRuntime, work, receipt)
    for (target, variant), files in sorted(outputs.items()):
        for name, path in sorted(files.items()):
            with open(path, "rb") as f:
                data = f.read()
            leaked = [p for p in secrets if p.encode("utf-8") in data]
            if leaked:
                raise pe.EngineError("%s %s output %s holds source paths %s" % (target, variant, name, leaked))
            print("%s %s %s: linked and inspected; not run" % (target, variant, name))
    print("relocated=%s denied=%d zig=%s" % (root, len(secrets), "denied" if zig else "not given"))
    shutil.rmtree(work)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zig")
    parser.add_argument("--engine", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--output")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--seed-cache")
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--prove", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.prove:
            prove(args.engine, args.runtime, args.deny, args.zig)
        else:
            if not (args.zig and args.output):
                parser.error("--zig and --output are required")
            output, receipt = prepareCppRuntime(args.zig, args.engine, args.runtime, args.output, args.target,
                                                args.seed_cache)
            print("%d files, %d variants proven" % (len(receipt["files"]) + 1, len(receipt["variants"])))
            print("overlay written to %s" % output)
    except pe.EngineError as error:
        print("prepareCppRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
