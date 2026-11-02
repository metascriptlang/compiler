#!/usr/bin/env python3
"""Prepare the C++ runtime of x86_64-linux-gnu.2.31, aarch64-linux-gnu.2.31, x86_64-windows-gnu, aarch64-macos and x86_64-macos with a local Zig, then prove it with clang and lld alone.

    prepareCppRuntime.py --zig ZIG --engine ENGINE_DIR --runtime RUNTIME_DIR --output NEW_DIR [--target T ...] [--seed-cache DIR]
    prepareCppRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--zig ZIG] [--deny PATH ...]
    prepareCppRuntime.py --execute --engine ENGINE_DIR --runtime RUNTIME_DIR

RUNTIME_DIR is a bundle's `runtime/` whose C configs exist (prepareRuntime.py, prepareWindowsRuntime.py); it is
only read. NEW_DIR receives an overlay of new paths, each relative to RUNTIME_DIR, which prepareBundle.py merges:

    include/cxx/{libcxx,libcxxabi,libunwind}      the headers, shared by every target
    <target>.cxx/                                 the three archives and the aliases of their other spellings
    <target>.cxx.cfg  <target>.dll.cxx.cfg        one config per base config <name>.cfg (Windows has both)
    <target>.so.cxx.cfg                           each GNU Linux target, when the runtime already holds the shared-object base <target>.so.cfg
    darwin/<target>.cxx.cfg  darwin/<target>.cxx/ each macOS target: one config for its executable and its dylib, over darwin/<target>.cfg
    notices/cpp-provenance.json, notices/{libcxx,libcxxabi,libunwind}/LICENSE.TXT

Zig runs once per config on a C++ fixture with a private cache (`--seed-cache` copies the private cache of an
earlier run, which only skips building), and its compile and link lines give the defines, the include order and the
archives. A C++ compile or link names both configs, the C++ one first, and nothing else:

    clang++ --no-default-config --config=<name>.cxx.cfg --config=<name>.cfg x.cpp -o x

The C++ config puts libc++ and libc++abi before the C headers and libunwind after them (`-stdlib++-isystem`), carries
Zig's user-side defines (libc++ has no `__config_site`), searches its own `-L` directory and appends libc++abi,
libc++ and libunwind as link-only `$` inputs. Its archives live apart from the C runtime's, so a C link never
sees them and their `-L` shadows no C runtime file. A macOS target has only libc++abi.a and libc++.a, no
`-stdlib++-isystem` and no alias, because libSystem re-exports the unwinder; Zig is asked for `<arch>-macos.11.0`,
the floor of the C base config, and its `zig ld` line is read as a Mach-O plan, not as an ld.lld command. Zig's link flag spellings `-lstdc++`, `-lsupc++`, `-lgcc_eh` and
`-lgcc_s` are files beside the archives. A Linux shared-object config reads the executable's archives of its own CPU, and the overlay
is refused unless Zig's `-shared` link names byte-identical ones (Zig builds every non-Windows libc++, libc++abi and
libunwind archive position independent, so one set could serve both). The base configs and the C runtime are not changed.

`--prove` links and inspects every file and runs none, under a sandbox that denies the originals. `--execute` is a
separate mode that takes neither --prove, --zig nor --deny: on a matching x86_64 or ARM64 glibc Linux host it relocates the tree,
links that CPU's Linux shared object and its C control, loads it with `dlopen` from a C host linked through the executable's C
base config and `-ldl` alone, and checks cppSum, a caught throw and the destructor count. On a native Mac (arm64 for
aarch64-macos, Intel for x86_64-macos; an x86_64 process Rosetta translates is refused) it does the same for the dylib, with
a C host that links the Darwin C base config alone, and also runs the C++ executables and the archive-only C clients, which
must print exactly what their fixtures print. A host or receipt without the exact variants it runs fails before any compile.
It is an extra check, never a substitute for --prove, and says that the hermetic proof was not run.

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
import platform
import subprocess
import sys
import tempfile

import prepareDarwinRuntime as pd
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw

LINUX, LINUX_ARM, WINDOWS = "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31", pw.TARGET
LINUX_TARGETS = (LINUX, LINUX_ARM)
MACOS_ARM, MACOS = pd.TARGET, pd.X64_TARGET
DARWIN_TARGETS = (MACOS_ARM, MACOS)
PROVENANCE = "notices/cpp-provenance.json"
CXX_STANDARD = "-std=c++20"
CPP_DEFINES = ("-D_LIBCPP_", "-D_LIBCXXABI_")
HEADERS = {"libcxx": "libcxx/include", "libcxxabi": "libcxxabi/include", "libunwind": "libunwind/include"}
SPEC = {"notices": {name: [name + "/LICENSE.TXT"] for name in HEADERS}}
ARCHIVES = {LINUX: ["libc++abi.a", "libc++.a", "libunwind.a"], LINUX_ARM: ["libc++abi.a", "libc++.a", "libunwind.a"],
            WINDOWS: ["c++abi.lib", "c++.lib", "unwind.lib"], **{t: ["libc++abi.a", "libc++.a"] for t in DARWIN_TARGETS}}
LIBRARY_STEMS = ["c++abi", "c++", "unwind"]
OTHER_SPELLINGS = {"stdc++": "c++", "supc++": "c++abi", "gcc_eh": "unwind", "gcc_s": "unwind"}
STEMS = {**{t: LIBRARY_STEMS for t in (LINUX, LINUX_ARM, WINDOWS)}, **{t: LIBRARY_STEMS[:2] for t in DARWIN_TARGETS}}
SPELLINGS = {**{t: OTHER_SPELLINGS for t in (LINUX, LINUX_ARM, WINDOWS)}, **{t: {} for t in DARWIN_TARGETS}}
DIRECTORIES = {LINUX: LINUX + ".cxx", LINUX_ARM: LINUX_ARM + ".cxx", WINDOWS: "windows/" + WINDOWS + ".cxx",
               **{t: "darwin/" + t + ".cxx" for t in DARWIN_TARGETS}}
DYLIB_INSTALL_NAME = "@rpath/libcppRuntimeFixture.dylib"


def linuxVariants(target):
    """The executable and the optional shared-object variant of a GNU Linux target, each over that target's C base config."""
    return {
        (target, "exe"): {"fixture": "runtimeCpp.cpp", "zigArgs": [], "zigLibraries": ["-lm", "-lpthread"],
                          "c": "runtimeLinux.c", "base": target + ".cfg", "config": target + ".cxx.cfg"},
        (target, "so"): {"fixture": "runtimeCppShared.cpp", "zigArgs": ["-shared"], "zigLibraries": ["-lm", "-lpthread"],
                         "c": "runtimeLinuxShared.c", "base": target + ".so.cfg", "config": target + ".so.cxx.cfg",
                         "optional": True},
    }


def darwinVariants(target):
    """The executable and the dylib of a macOS target: one config pairs over the one C base config, so the dylib is told
    its own driver flags and a fixed install name, which the C base config cannot carry for both."""
    pair = {"zigLibraries": [], "base": "darwin/%s.cfg" % target, "config": "darwin/%s.cxx.cfg" % target}
    return {
        (target, "exe"): dict(pair, fixture="runtimeCppDarwin.cpp", zigArgs=[], c="runtimeDarwin.c", linkFlags=[]),
        (target, "dylib"): dict(pair, fixture="runtimeCppShared.cpp", zigArgs=["-shared"], c="runtimeDarwinDylib.c",
                                linkFlags=["-dynamiclib", "-install_name", DYLIB_INSTALL_NAME]),
    }


VARIANTS = {
    **linuxVariants(LINUX),
    **linuxVariants(LINUX_ARM),
    **darwinVariants(MACOS_ARM),
    **darwinVariants(MACOS),
    (WINDOWS, "exe"): {"fixture": "runtimeCpp.cpp", "zigArgs": [], "zigLibraries": pw.USER_LIBRARIES,
                       "c": "runtimeWindows.c", "base": "windows/%s.cfg" % WINDOWS,
                       "config": "windows/%s.cxx.cfg" % WINDOWS},
    (WINDOWS, "dll"): {"fixture": "runtimeCppDll.cpp", "zigArgs": ["-shared"], "zigLibraries": pw.USER_LIBRARIES,
                       "c": "runtimeWindowsDll.c", "base": "windows/%s.dll.cfg" % WINDOWS,
                       "config": "windows/%s.dll.cxx.cfg" % WINDOWS},
}
TARGETS = [LINUX, LINUX_ARM, WINDOWS, MACOS_ARM, MACOS]
MACHO_UNWIND_SECTIONS = ("__unwind_info", "__gcc_except_tab")
MACHO_DYLIB_IMPORTS = {0x20, 0x80000018, 0x8000001f, 0x80000023}
LC_SEGMENT_64, LC_ID_DYLIB, LC_LOAD_DYLINKER, MH_DYLIB = pd.LC_SEGMENT_64, pd.LC_ID_DYLIB, pd.LC_LOAD_DYLINKER, 6
DARWIN_LIBC = os.path.basename(pd.HEADERS)
DARWIN_INCLUDES = ["$ROOT/runtime/include/cxx/libcxx", "$ROOT/runtime/include/cxx/libcxxabi"]
DRIVER_DEFAULT_CC1_FLAGS = ("-fcxx-exceptions", "-fexceptions", "-exception-model=seh", "-fno-sized-deallocation",
                            "-fno-use-init-array", "-fno-use-cxa-atexit")
GLIBC_NEEDED = {"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libutil.so.1", "libresolv.so.2"}
ELF_NEEDED_BY_TARGET = {t: GLIBC_NEEDED | {os.path.basename(pr.ELF_TARGETS[t]["interpreter"])} for t in LINUX_TARGETS}
ELF_NEEDED = ELF_NEEDED_BY_TARGET[LINUX]
PE_IMPORTS = {"kernel32.dll", "ntdll.dll", "advapi32.dll", "shell32.dll", "user32.dll", "ws2_32.dll", "bcrypt.dll",
              "mswsock.dll"}
RUN_TIMEOUT_SECONDS = 45
HOST_FIXTURE = "runtimeCppHost.c"
HOST_OUTPUT = "cpp caught=count destroyed=2\nhost ok\n"
EXECUTABLE_OUTPUT = "cpp sum=42 what=boom\n"
CLIENT_OUTPUT = "archive sum=12\n"
RUN_OUTPUTS = {"plain": EXECUTABLE_OUTPUT, "written": EXECUTABLE_OUTPUT, "client": CLIENT_OUTPUT,
               "client with every spelling": CLIENT_OUTPUT}
HOST_TARGETS = {("Linux", "x86_64"): LINUX, ("Linux", "aarch64"): LINUX_ARM, ("Linux", "arm64"): LINUX_ARM,
                ("Darwin", "arm64"): pd.TARGET, ("Darwin", "aarch64"): pd.TARGET,
                ("Darwin", "x86_64"): pd.X64_TARGET}
VARIANT_NAMES = {"exe": "executable", "so": "shared-object", "dylib": "dylib"}
NM_ROW = re.compile(r"^[0-9a-fA-F]{8,16} ([A-Za-z]) (\S.*)$")
SEARCH_LIST = re.compile(r"#include <\.\.\.> search starts here:\n(.*?)End of search list\.", re.S)
LIMITS = ["no Linux or Windows execution was available: the executables, shared objects and DLLs are linked and their ELF or PE "
          "headers, imports and exception tables inspected, never run by --prove; `--execute` runs only the Linux shared object "
          "on a glibc Linux host of the same CPU, or the executables and the dylib of a macOS target on a native Mac of that CPU, "
          "without the sandbox of --prove",
          "x86_64-linux-gnu.2.31, aarch64-linux-gnu.2.31, x86_64-windows-gnu, aarch64-macos and x86_64-macos only: the aarch64 "
          "Windows and wasm32-wasi runtimes stay C only; a Linux shared object runs only on a matching glibc host; "
          "a macOS file is run only on a native Mac of its CPU, never "
          "under Rosetta",
          "the macOS archives are Zig-built at macOS 11.0 and carry no libunwind: libSystem re-exports the unwinder; Zig's own "
          "compiler_rt, which its link line ends with, is not carried, so a builtin only that library defines fails the link here",
          "the Windows archives are copied as Zig produced them, so their member names hold the private cache paths of "
          "that run; the GNU archives are normalized like the C runtime's",
          "archive contents are not measured for bit-reproducibility across Zig caches",
          "the aliases are lower case; Zig ignores case in a Windows library name, the linker here does not",
          "the C++ config is a pair partner of the base config and is selected by the compiler, never found by the driver",
          "a Linux shared-object config exists only when the runtime held that target's .so.cfg base when the overlay was made"]


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
    selectVariants(runtime, chosen)
    return chosen


def selectVariants(runtime, targets):
    """The (target, variant) keys of targets to produce: each variant whose base config the runtime holds. The Linux
    shared-object variant is optional, because a bundle adds its base apart from the executable's."""
    keys = []
    for key, spec in VARIANTS.items():
        if key[0] not in targets:
            continue
        if os.path.isfile(os.path.join(runtime, spec["base"])):
            keys.append(key)
        elif not spec.get("optional"):
            raise pe.EngineError("%s has no base config %s to pair with" % (key[0], spec["base"]))
    return keys


def splitIsystem(isystem, unwinder=True):
    """(Zig lib directory, libc directory names) of the order libcxx, libcxxabi, builtin, libc... and, for a target with an
    unwinder of its own to build, libunwind last."""
    zigLib = os.path.dirname(os.path.dirname(isystem[0]))
    expected = [os.path.join(zigLib, HEADERS["libcxx"]), os.path.join(zigLib, HEADERS["libcxxabi"]),
                os.path.join(zigLib, "include")]
    tail = [os.path.join(zigLib, HEADERS["libunwind"])] if unwinder else []
    count = len(isystem) - len(tail)
    if isystem[:3] != expected or count < 4 or isystem[count:] != tail or (
            not unwinder and os.path.join(zigLib, HEADERS["libunwind"]) in isystem):
        raise pe.EngineError("C++ include order %s is not libcxx, libcxxabi, builtin, libc...%s" % (
            isystem, ", libunwind" if unwinder else ""))
    if re.search(r"\s", zigLib):
        raise pe.EngineError("Zig lib directory %s has whitespace" % zigLib)
    return zigLib, [os.path.basename(d) for d in isystem[3:count]]


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


def zigTarget(target):
    """Zig's spelling of target: a macOS target names the minimum version of the C base config, because Zig builds libc++ and
    libc++abi for its own default, which is newer."""
    return "%s.%s" % (target, pd.MINIMUM_VERSION) if target in DARWIN_TARGETS else target


def versionOf(text):
    """The (major, minor, patch) of a dotted version, so that 11.0 and 11.0.0 compare equal."""
    parts = text.split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        raise pe.EngineError("version %r is not dotted numbers" % text)
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


def cacheInput(token, cacheRoot, directory):
    """The real path of a link input a Zig line names relative to directory, which must be a regular file of the private cache."""
    path = os.path.join(directory, token)
    real = os.path.realpath(path)
    if not os.path.isfile(real) or os.path.islink(path):
        raise pe.EngineError("link input %s is not a regular file" % token)
    if os.path.commonpath([cacheRoot, real]) != cacheRoot:
        raise pe.EngineError("link input %s is not from this run's private cache" % token)
    return real


def parseMachOLinkArgv(line, output, objectName, cacheRoot, directory, dylib):
    """Read the pseudo-line of Zig's own Mach-O linker, `zig ld -dynamic [-dylib] -platform_version OS VERSION SDK [-dead_strip]
    -o OUTPUT OBJECT ARCHIVE... -lSystem INPUT...`, which is no ld.lld command. Anything else Zig could print there is refused.
    Returns {"version", "sdk", "inputs", "tokens", "zigOnly"}: inputs are the real paths of the archives and Zig's own runtime in
    order, zigOnly the file names after -lSystem."""
    tokens = line.split()
    if tokens[:2] != ["zig", "ld"]:
        raise pe.EngineError("Mach-O link line starts with %s, expected zig ld" % tokens[:2])
    counts, platform, written, items, i = {"-dynamic": 0, "-dylib": 0, "-dead_strip": 0}, None, False, [], 2
    while i < len(tokens):
        token = tokens[i]
        if token == "-platform_version" and not platform and i + 3 < len(tokens):
            platform = tokens[i + 1:i + 4]
            i += 4
        elif token == "-o" and not written:
            if tokens[i + 1:i + 2] != [output]:
                raise pe.EngineError("link line writes %s, not %s" % (tokens[i + 1:i + 2], output))
            written = True
            i += 2
        elif token in counts:
            counts[token] += 1
            i += 1
        elif token == "-lSystem":
            items.append(("arg", token))
            i += 1
        elif token.startswith("-"):
            raise pe.EngineError("Mach-O link option %s is not one Zig prints for a plain C++ %s" % (
                token, "dylib" if dylib else "executable"))
        elif os.path.basename(token) == objectName:
            items.append(("user", None))
            i += 1
        else:
            items.append(("input", cacheInput(token, cacheRoot, directory)))
            i += 1
    if counts["-dynamic"] != 1 or counts["-dylib"] != int(dylib) or counts["-dead_strip"] > 1:
        raise pe.EngineError("Mach-O link line options %s are not a dynamic %s" % (counts, "dylib" if dylib else "executable"))
    if not platform or platform[0] != "macos" or not written:
        raise pe.EngineError("Mach-O link line has no macos -platform_version or no -o: %s" % line)
    kinds = [kind for kind, _ in items]
    if kinds[:4] != ["user", "input", "input", "arg"] or any(kind != "input" for kind in kinds[4:]):
        raise pe.EngineError("link inputs %s are not the fixture object, libc++abi, libc++, -lSystem, then Zig's own runtime" % [
            value if kind == "arg" else kind if kind == "user" else os.path.basename(value) for kind, value in items])
    inputs = [value for kind, value in items if kind == "input"]
    versionOf(platform[2])
    return {"version": platform[1], "sdk": platform[2], "inputs": inputs,
            "tokens": [t for t in tokens[2:] if t in counts or t == "-lSystem"],
            "zigOnly": [os.path.basename(p) for p in inputs[2:]]}


def macosFloor(compileLine, link):
    """The macOS minimum Zig compiled and linked for, as {"platformVersion", "sdkVersion", "compileMinimum", "zigOnlyInputs"}; it must
    be pd.MINIMUM_VERSION on both lines."""
    found = [t[len("-mmacos-version-min="):] for t in compileLine.split() if t.startswith("-mmacos-version-min=")]
    if len(found) != 1:
        raise pe.EngineError("Zig's compile line names -mmacos-version-min %d times: %s" % (len(found), found))
    if not versionOf(found[0]) == versionOf(link["version"]) == versionOf(pd.MINIMUM_VERSION):
        raise pe.EngineError("Zig compiled for macOS %s and linked for %s, not the base config's %s" % (
            found[0], link["version"], pd.MINIMUM_VERSION))
    return {"platformVersion": link["version"], "sdkVersion": link["sdk"], "compileMinimum": found[0],
            "zigOnlyInputs": link["zigOnly"]}


def runZig(zig, target, variant, work, cache):
    """One Zig C++ compile and link of the variant's fixture in the shared private cache. Returns (stderr, output, directory)."""
    spec = VARIANTS[(target, variant)]
    private = os.path.join(work, target, variant)
    extension = "dylib" if variant == "dylib" else "dll" if variant == "dll" else "out" if target != WINDOWS else "exe"
    output = os.path.join(private, "fixture." + extension)
    os.makedirs(os.path.join(private, "local"))
    environment = {"PATH": "/usr/bin:/bin", "HOME": private, "TMPDIR": private,
                   "ZIG_GLOBAL_CACHE_DIR": cache, "ZIG_LOCAL_CACHE_DIR": os.path.join(private, "local"),
                   "ZIG_VERBOSE_CC": "1", "ZIG_VERBOSE_LINK": "1"}
    command = [zig, "c++", "-target", zigTarget(target), "-O2", CXX_STANDARD, "-v"] + spec["zigArgs"] + [
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
    if target in LINUX_TARGETS:
        compileLine, linkLine = pr.selectLines(stderr, fixture, output)
        linker, items = pr.parseLinkArgv(linkLine, output, stem + ".o", realCache, private)
        if linker != "ld.lld":
            raise pe.EngineError("%s linked with %s, expected ld.lld" % (target, linker))
        if variant == "so":
            pr.checkSharedLink(linkLine)
        inputs = [value for kind, value in items if kind == "input"]
        tokens = [value if kind == "arg" else os.path.basename(value) for kind, value in items
                  if kind == "arg" or (kind == "input" and os.path.basename(value) not in ARCHIVES[target])]
    elif target in DARWIN_TARGETS:
        compileLine, linkLine = pr.selectLines(stderr, fixture, output)
        link = parseMachOLinkArgv(linkLine, output, stem + ".o", realCache, private, variant == "dylib")
        inputs, tokens, macos = link["inputs"], link["tokens"], macosFloor(compileLine, link)
    else:
        compileLine, linkLine = pw.selectWindowsLines(stderr, fixture, output)
        link = pw.parseCoffLinkArgv(linkLine, stem + ".obj", realCache, private)
        if link["dll"] != (variant == "dll"):
            raise pe.EngineError("%s %s link line has -DLL=%s" % (target, variant, link["dll"]))
        inputs = link["inputs"]
        tokens = [os.path.basename(p) for p in inputs if os.path.basename(p) not in ARCHIVES[target]]
    compile_ = pr.parseCompileArgv(compileLine)
    zigLib, libc = splitIsystem(compile_["isystem"], target not in DARWIN_TARGETS)
    facts = {"zigLib": zigLib, "libc": libc, "tokens": tokens, "archives": splitArchives(inputs, ARCHIVES[target]),
             "defines": [d for d in compile_["defines"] if d.startswith(CPP_DEFINES)],
             "definesInBase": [d for d in compile_["defines"] if not d.startswith(CPP_DEFINES)],
             "cc1": cc1Flags(stderr, spec["fixture"])}
    if target in DARWIN_TARGETS:
        facts["macos"] = macos
    return facts


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


def darwinCrossCheck(variant, lines):
    """A macOS base config agrees with Zig's lines on what it can say: the macOS minimum of the target triple, the sysroot that
    holds the libc headers Zig used, the linker. Zig's own linker takes no ld64.lld token, so there are no link tokens to compare."""
    label = "%s %s" % (variant["target"], variant["variant"])
    triple = "--target=%s-apple-macos%s" % (pd.TARGETS[variant["target"]]["arch"], pd.MINIMUM_VERSION)
    macos = variant["macos"]
    if triple not in lines or not versionOf(macos["platformVersion"]) == versionOf(macos["compileMinimum"]) == versionOf(
            pd.MINIMUM_VERSION):
        raise pe.EngineError("%s: the base config has no %s, or Zig's macOS %s/%s is not %s" % (
            label, triple, macos["platformVersion"], macos["compileMinimum"], pd.MINIMUM_VERSION))
    if "-isysroot <CFGDIR>/%s" % pd.SYSROOT not in lines or variant["libcDirectories"] != [DARWIN_LIBC]:
        raise pe.EngineError("%s: Zig's libc directories %s are not %s, the headers of the base config's sysroot" % (
            label, variant["libcDirectories"], [DARWIN_LIBC]))
    if not any(l.startswith("--ld-path=") and l.endswith("/bin/ld64.lld") for l in lines):
        raise pe.EngineError("%s: the base config names no ld64.lld" % label)


def crossCheck(variant, base):
    """The facts of Zig's C++ line agree with the C config the C++ config pairs with: nothing Zig passes is dropped."""
    lines = base.splitlines()
    darwin = variant["target"] in DARWIN_TARGETS
    libc = [l.split("/")[-1] for l in lines if l.startswith("-isystem <CFGDIR>/include/libc/")]
    if darwin:
        darwinCrossCheck(variant, lines)
    elif not subsequence(libc, variant["libcDirectories"]):
        raise pe.EngineError("%s %s: base libc directories %s are not in Zig's C++ order %s" % (
            variant["target"], variant["variant"], libc, variant["libcDirectories"]))
    missing = [d for d in variant["definesInBase"] if d not in lines]
    if missing:
        raise pe.EngineError("%s %s: Zig's C++ line defines %s, the base config does not" % (
            variant["target"], variant["variant"], missing))
    if not darwin and not subsequence(variant["linkTokens"], baseTokens(base)):
        raise pe.EngineError("%s %s: Zig's C++ link tokens %s are not in the base config's order" % (
            variant["target"], variant["variant"], variant["linkTokens"]))


def renderConfig(target, variant, defines):
    """Text of RUNTIME/<config>: headers, defines, the late libunwind include, the archive directory and the link tail."""
    config = VARIANTS[(target, variant)]["config"]
    include = "<CFGDIR>/%sinclude/cxx/" % up(config)
    lines = [pr.configLine(["-isystem", include + "libcxx"]), pr.configLine(["-isystem", include + "libcxxabi"])]
    lines += [pr.configLine([d]) for d in defines]
    if "unwind" in STEMS[target]:
        lines.append(pr.configLine(["-stdlib++-isystem", include + "libunwind"]))
    lines.append(pr.configLine(["-Xlinker", "-L", "-Xlinker", "<CFGDIR>/" + os.path.relpath(
        DIRECTORIES[target], os.path.dirname(config) or ".")]))
    lines += ["$" + pr.configLine(["-l" + stem]) for stem in STEMS[target]]
    return "\n".join(lines) + "\n"


def archiveSymbols(engine, path):
    """The defined external symbols of an archive as sorted (type, name), whatever its member names: only rows of an address, a
    type letter and a name count, never the member headings llvm-nm prints between them."""
    found = []
    for line in pe.run([os.path.join(engine, "bin", "llvm-nm"), "--defined-only", "--extern-only", path]).splitlines():
        row = NM_ROW.match(line)
        if row:
            found.append((row.group(1), row.group(2)))
    return sorted(found)


def copyArchives(engine, target, paths, output):
    """Copy a target's archives in link order, the GNU and Mach-O ones normalized only while their symbols stay the same."""
    records = pr.copyInputs([("input", p) for p in paths], output, DIRECTORIES[target], engine)
    if target in LINUX_TARGETS + DARWIN_TARGETS:
        for path, record in zip(paths, records):
            if archiveSymbols(engine, path) != archiveSymbols(engine, os.path.join(output, DIRECTORIES[target], record["name"])):
                raise pe.EngineError("normalizing %s changed its symbols" % record["name"])
    return records


def linkAliases(directory, names, spellings=OTHER_SPELLINGS):
    """Give each other spelling of a library a relative symlink to its file. Returns [{"alias", "target"}]."""
    files = {n[len("lib"):-len(".a")] if n.endswith(".a") else n[:-len(".lib")]: n for n in names}
    records = []
    for alias, stem in spellings.items():
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


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def seedCache(seed, cache):
    """A private copy of an earlier run's cache; the shared Zig cache is never one."""
    seed = os.path.realpath(seed)
    if not os.path.isdir(seed) or os.path.realpath(os.path.expanduser("~/.cache/zig")) in (seed, os.path.dirname(seed)):
        raise pe.EngineError("--seed-cache %s is not a private cache directory" % seed)
    shutil.copytree(seed, cache, symlinks=True)


def produce(zig, engine, targets, work, output, seed, variants):
    """Run Zig for every config of variants (the keys selectVariants gives) and write the overlay into output.
    Returns (variant records, archive records, sources)."""
    cache = os.path.join(work, "global")
    if seed:
        seedCache(seed, cache)
    else:
        os.makedirs(cache)
    produced = {key: produceVariant(zig, key[0], key[1], work, cache) for key in variants}
    zigLibs = {p["zigLib"] for p in produced.values()}
    if len(zigLibs) != 1:
        raise pe.EngineError("the configs name different Zig lib directories %s" % sorted(zigLibs))
    zigLib = zigLibs.pop()
    for name, relative in HEADERS.items():
        pr.copyTree(os.path.join(zigLib, relative), os.path.join(output, "include", "cxx", name))
    archives, records = {}, []
    for target in targets:
        first = produced[(target, "exe")]["archives"]
        for key, facts in produced.items():
            if key[0] == target and [pe.sha256File(p) for p in facts["archives"]] != [pe.sha256File(p) for p in first]:
                raise pe.EngineError("%s %s links other C++ archives than the executable" % key)
        copies = copyArchives(engine, target, first, output)
        archives[target] = {"directory": DIRECTORIES[target], "inputs": copies,
                            "aliases": linkAliases(os.path.join(output, DIRECTORIES[target]), [r["name"] for r in copies],
                                                   SPELLINGS[target])}
    for (target, variant), facts in produced.items():
        spec = VARIANTS[(target, variant)]
        text, config = renderConfig(target, variant, facts["defines"]), os.path.join(output, spec["config"])
        if os.path.lexists(config):
            if read(config) != text:
                raise pe.EngineError("%s %s: its config text differs from the other variant's at %s" % (
                    target, variant, spec["config"]))
        else:
            os.makedirs(os.path.dirname(config), exist_ok=True)
            pe.writeText(config, text)
        records.append({"target": target, "variant": variant, "config": spec["config"], "base": spec["base"],
                        "directory": DIRECTORIES[target], "defines": facts["defines"],
                        "definesInBase": facts["definesInBase"], "libcDirectories": facts["libc"],
                        "linkTokens": facts["tokens"], "zigCc1Flags": facts["cc1"],
                        "libraries": [os.path.basename(p) for p in facts["archives"]],
                        **({"macos": facts["macos"]} if "macos" in facts else {})})
    return records, archives, {"zigLib": zigLib, "notices": pr.copyNotices(output, zigLib, SPEC)}


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


def elfCppProblem(path, nm, variant="exe", target=LINUX):
    """Why a linked GNU executable, or the shared object ("so") that exports cppSum, is not a glibc C++ file of target
    (its machine, loader and dependencies) with unwind tables, or None."""
    if variant == "so":
        problem = (pr.elfSharedProblem(path, target) or pr.exportedSymbolProblem(nm, path, "cppSum")
                   or pr.glibcSymbolProblem(nm, path))
    else:
        problem = pr.elfProblem(path, target) or pr.elfInterpreterProblem(path, target) or pr.glibcSymbolProblem(nm, path)
    if problem:
        return problem
    needed, ehFrame = readElf(path)
    if "libc.so.6" not in needed or not set(needed) <= ELF_NEEDED_BY_TARGET[target]:
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


def machOCppProblem(path, variant, target, nm):
    """Why a linked file is not a C++ executable, or the dylib that exports _cppSum, of target for macOS pd.MINIMUM_VERSION with
    libSystem as its only dependency, the target's code signature, compact unwind info and an exception table, or None."""
    expected, dylib = pd.TARGETS[target], variant == "dylib"
    try:
        info = pd.readMachO(path)
    except pe.EngineError as error:
        return str(error)
    commands, sections, installName = info["commands"], info["sections"], info["installName"]
    if info["cpuType"] != expected["cpuType"]:
        return "cpu type %#x is not %s" % (info["cpuType"], expected["arch"])
    if dylib and (info["fileType"] != MH_DYLIB or LC_ID_DYLIB not in commands or pd.LC_MAIN in commands
                  or LC_LOAD_DYLINKER in commands or installName != DYLIB_INSTALL_NAME):
        return "file type %d with commands %s and install name %s is not a dylib named %s without LC_MAIN" % (
            info["fileType"], commands, installName, DYLIB_INSTALL_NAME)
    if not dylib and (info["fileType"] != pd.MH_EXECUTE or pd.LC_MAIN not in commands or LC_LOAD_DYLINKER not in commands
                      or LC_ID_DYLIB in commands or info["dylinker"] != pd.DYLINKER):
        return "file type %d with commands %s is not an executable with LC_MAIN and a dynamic linker" % (
            info["fileType"], commands)
    if info["dylibs"] != [pd.LIBSYSTEM] or MACHO_DYLIB_IMPORTS.intersection(commands):
        return "dylibs %s with commands %s are not exactly %s" % (info["dylibs"], commands, pd.LIBSYSTEM)
    if not info["build"] or info["build"][0] != pd.PLATFORM_MACOS or info["build"][1] != pd.MINOS:
        return "build version %s is not macOS %s" % (info["build"], pd.MINIMUM_VERSION)
    if (pd.LC_CODE_SIGNATURE in commands) != expected["codeSignature"]:
        return "LC_CODE_SIGNATURE is %s" % ("absent" if expected["codeSignature"] else "present")
    missing = [name for name in MACHO_UNWIND_SECTIONS if ("__TEXT", name) not in sections]
    if missing:
        return "no __TEXT section %s among %s" % (missing, sections)
    if dylib:
        defined = [l.split()[-1] for l in pe.run([nm, "-g", "--defined-only", path]).splitlines() if l.strip()]
        if "_cppSum" not in defined:
            return "does not export _cppSum: %s" % defined
    return None


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
             + spec.get("linkFlags", []) + [obj, "-o", out])
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
    windows, darwin = variant["target"] == WINDOWS, variant["target"] in DARWIN_TARGETS
    shared = variant["variant"] in ("dll", "so", "dylib")
    pair = ["--no-default-config", "--config=" + os.path.join(merged, spec["config"]),
            "--config=" + os.path.join(merged, spec["base"])]
    clangxx, clang = os.path.join(root, "bin", "clang++"), os.path.join(root, "bin", "clang")
    suffix = {"dll": ".dll", "so": ".so", "dylib": ".dylib"}.get(variant["variant"], ".exe" if windows else ".out")
    linkFlags = spec.get("linkFlags", [])
    fixture = os.path.join(pr.FIXTURES, spec["fixture"])
    scratch = os.path.join(work, "cpp-%s-%s" % (variant["target"], variant["variant"]))
    os.makedirs(scratch)
    path = lambda name: os.path.join(scratch, name)
    step(run, "C++ compile", [clangxx] + pair + [CXX_STANDARD, "-O2", "-c", fixture, "-o", path("x.o")])
    step(run, "C++ link", [clangxx] + pair + linkFlags + [path("x.o"), "-o", path("plain" + suffix)])
    step(run, "C++ link with the caller's libraries and a written -lc++",
         [clangxx] + pair + linkFlags + [path("x.o")] + spec["zigLibraries"] + ["-lc++", "-o", path("written" + suffix)])
    outputs = {"plain": path("plain" + suffix), "written": path("written" + suffix)}
    listing = step(run, "include order", [clangxx] + pair + ["-E", "-v", "-x", "c++", "/dev/null"], stderr=True).stderr
    entries = searchList(listing, root)
    if darwin:
        builtin = r"\$ROOT/lib/clang/[^/]+/include"
        if len(entries) != 4 or entries[:2] != DARWIN_INCLUDES or not re.fullmatch(builtin, entries[2]) or entries[3] != (
                "$ROOT/runtime/darwin/%s/usr/include" % pd.SYSROOT):
            raise pe.EngineError("%s %s include order %s is not libcxx, libcxxabi, builtin, sysroot (and no libunwind)" % (
                variant["target"], variant["variant"], entries))
    else:
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
    if not shared:
        step(run, "archive C++ compile", [clangxx] + pair + [CXX_STANDARD, "-O2", "-c",
                                                             os.path.join(pr.FIXTURES, "cppArchive.cpp"), "-o", path("a.o")])
        step(run, "archive", [os.path.join(root, "bin", "llvm-ar"), "--format=" + ("darwin" if darwin else "gnu"), "crs",
                              path("libclient.a"), path("a.o")])
        step(run, "C client compile", [clang, "--no-default-config", "--config=" + os.path.join(merged, spec["base"]),
                                       "-O2", "-c", os.path.join(pr.FIXTURES, "cppArchiveClient.c"), "-o", path("client.o")])
        stems = [s for s in STEMS[variant["target"]] if s != "c++"]
        spellings = ["-l" + s for s in ("c++",) + tuple(SPELLINGS[variant["target"]]) + tuple(stems)]
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
        if variant["target"] in LINUX_TARGETS:
            return elfCppProblem(binary, nm, variant["variant"], variant["target"])
        if variant["target"] in DARWIN_TARGETS:
            return machOCppProblem(binary, variant["variant"], variant["target"], nm)
        return peCppProblem(binary, variant["variant"])
    return inspect


def translatedByRosetta():
    """Whether this process is an x86_64 one that Rosetta translates (`sysctl.proc_translated` is 1)."""
    import ctypes
    import errno
    query = ctypes.CDLL(None, use_errno=True).sysctlbyname
    query.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    query.restype = ctypes.c_int
    translated = ctypes.c_int(0)
    size = ctypes.c_size_t(ctypes.sizeof(translated))
    if query(b"sysctl.proc_translated", ctypes.byref(translated), ctypes.byref(size), None, 0) != 0:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return False
        raise pe.EngineError("sysctl.proc_translated failed: %s" % os.strerror(error))
    if size.value != ctypes.sizeof(translated) or translated.value not in (0, 1):
        raise pe.EngineError("sysctl.proc_translated returned invalid value %d of size %d" % (translated.value, size.value))
    return translated.value == 1


def executionTarget(system=None, machine=None, loader=None, translated=None):
    """(target, None) of the native host: x86_64/ARM64 glibc Linux, arm64 macOS or an Intel Mac that runs x86_64 itself; else
    (None, why this host runs no target of the overlay). Rosetta never makes a host an x86_64 Mac."""
    system, machine = system or platform.system(), machine or platform.machine()
    target = HOST_TARGETS.get((system, machine))
    if target is None:
        return None, "host is %s %s, not x86_64/ARM64 Linux or macOS on arm64 or x86_64" % (system, machine)
    if system == "Linux":
        if loader is None:
            loader = os.path.exists(pr.ELF_TARGETS[target]["interpreter"])
        if not loader:
            return None, "host has no %s loader" % pr.ELF_TARGETS[target]["interpreter"]
    elif target == pd.X64_TARGET:
        if translated is None:
            translated = translatedByRosetta()
        if translated:
            return None, "host is an x86_64 process translated by Rosetta, not an Intel Mac running %s itself" % target
    return target, None


def executedVariants(receipt, target):
    """The receipt's variants this host runs, exactly one of each: the Linux shared object, or a Mac's executable and dylib."""
    found = []
    for kind in ["so"] if target in LINUX_TARGETS else ["exe", "dylib"]:
        name = "%s %s" % ("Linux" if target in LINUX_TARGETS else target, VARIANT_NAMES[kind])
        matching = [v for v in receipt["variants"] if (v["target"], v["variant"]) == (target, kind)]
        if not matching:
            raise pe.EngineError("--execute: the overlay has no %s variant to run" % name)
        if len(matching) > 1:
            raise pe.EngineError("--execute: the overlay has %d %s variants, not one" % (len(matching), name))
        found.append(matching[0])
    return found


def checkHost(run, merged, work, shared, target=LINUX):
    """Link the C host through the executable's C base config alone, no C++ config or library (Linux adds -ldl; libSystem
    has dlopen), then run it on each shared object: it must load it, call cppSum and cppDestroyed and print HOST_OUTPUT."""
    clang = os.path.join(os.path.dirname(merged), "bin", "clang")
    config = ["--no-default-config", "--config=" + os.path.join(merged, VARIANTS[(target, "exe")]["base"])]
    scratch = os.path.join(work, "host-" + target)
    os.makedirs(scratch)
    obj, host = os.path.join(scratch, "host.o"), os.path.join(scratch, "host.out")
    step(run, "C host compile", [clang] + config + ["-O2", "-c", os.path.join(pr.FIXTURES, HOST_FIXTURE), "-o", obj])
    step(run, "C host link", [clang] + config + [obj] + (["-ldl"] if target in LINUX_TARGETS else []) + ["-o", host])
    for path in shared:
        printed = step(run, "C host run", [host, path]).stdout
        if printed != HOST_OUTPUT:
            raise pe.EngineError("C host printed %r for %s, expected %r" % (printed, os.path.basename(path), HOST_OUTPUT))


def checkRuns(run, files):
    """Run each linked executable of a variant by its absolute path: it must exit 0 with clean stderr and print what its
    fixture source prints."""
    if set(files) != set(RUN_OUTPUTS):
        raise pe.EngineError("the linked files %s are not the %s to run" % (sorted(files), sorted(RUN_OUTPUTS)))
    for name in sorted(files):
        printed = step(run, name + " run", [files[name]]).stdout
        if printed != RUN_OUTPUTS[name]:
            raise pe.EngineError("%s printed %r, expected %r" % (name, printed, RUN_OUTPUTS[name]))


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
        variants, archives, sources = produce(zig, engine, targets, work, partial, seed, selectVariants(runtime, targets))
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


def openProof(engine, runtime):
    """The real paths of an engine and its `runtime` child, and the overlay's receipt."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    pe.verifyEngine(engine)
    if runtime != os.path.join(engine, "runtime"):
        raise pe.EngineError("runtime %s is not the `runtime` child of engine %s" % (runtime, engine))
    with open(os.path.join(runtime, PROVENANCE), encoding="utf-8") as f:
        return engine, runtime, json.load(f)


def controlTree(root, work, receipt):
    """The relocated runtime of root with the overlay's files removed, beside the engine. Returns its runtime path."""
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
    return controlRuntime


def prove(engine, runtime, denied, zig=None):
    """Relocate the engine and its `runtime` child, which holds the overlay, to a path with a space and run checkOverlay
    under a sandbox that cannot read the originals, Zig or any --deny path. The control is the relocated runtime with
    the overlay's files removed."""
    engine, runtime, receipt = openProof(engine, runtime)
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
    controlRuntime = controlTree(root, work, receipt)
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


def boundedRun(label):
    """A runner of commands in a clean environment that gives up on one after RUN_TIMEOUT_SECONDS, naming label."""
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"}

    def run(command):
        try:
            return subprocess.run(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  universal_newlines=True, timeout=RUN_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            raise pe.EngineError("%s: %s timed out after %d s" % (label, " ".join(command[:2]), RUN_TIMEOUT_SECONDS))
    return run


def execute(engine, runtime):
    """On a native host, relocate the engine and runtime and check only what that host runs: the same-CPU shared object on
    glibc Linux, the executable and the dylib on an arm64 or Intel Mac. Each variant goes C control, link and inspection,
    then its run: an executable directly, a shared object by the C host. No sandbox, so not the proof of prove."""
    target, problem = executionTarget()
    if problem:
        raise pe.EngineError("--execute: %s" % problem)
    engine, runtime, receipt = openProof(engine, runtime)
    variants = executedVariants(receipt, target)
    work = os.path.realpath(tempfile.mkdtemp(prefix="cpp-runtime-execute-"))
    try:
        root = os.path.join(work, "relocated tree")
        shutil.copytree(engine, root, symlinks=True)
        merged = os.path.join(root, "runtime")
        control = controlTree(root, work, receipt)
        inspect = inspectBinary(os.path.join(root, "bin", "llvm-nm"))
        for variant in variants:
            run = boundedRun("%s %s" % (target, variant["variant"]))
            checkControl(run, merged, control, work, variant)
            files = checkVariant(run, merged, work, variant, inspect)
            if variant["variant"] == "exe":
                checkRuns(run, files)
                how = "run natively"
            else:
                checkHost(run, merged, work, [files["plain"], files["written"]], target=target)
                how = "run by the C host"
            for name in sorted(files):
                print("%s %s %s: %s; execution only; hermetic proof not run" % (target, variant["variant"], name, how))
    finally:
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
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    if args.execute:
        refused = [n for n, v in (("--prove", args.prove), ("--zig", args.zig), ("--deny", args.deny),
                                  ("--output", args.output), ("--target", args.target),
                                  ("--seed-cache", args.seed_cache)) if v]
        if refused:
            parser.error("--execute takes only --engine and --runtime, not %s" % ", ".join(refused))
    try:
        if args.execute:
            execute(args.engine, args.runtime)
        elif args.prove:
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
