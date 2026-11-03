#!/usr/bin/env python3
"""Prepare the aarch64-macos and x86_64-macos runtimes from the macOS libc headers and libSystem stub a local Zig ships.

    prepareDarwinRuntime.py --zig ZIG --engine ENGINE_DIR --output NEW_RUNTIME_DIR [--target T ...]

NEW_RUNTIME_DIR receives `darwin/`; in a bundle the same directory is `runtime/darwin/`, and the
engine is `../..` from it. There is no Apple SDK: the sysroot is what Zig itself links macOS programs
against, copied opaquely:

    darwin/sysroot/usr/include/        Zig's include/any-darwin-any
    darwin/sysroot/usr/lib/libSystem.tbd   Zig's libc/darwin stub
    darwin/<target>.cfg                clang --config ... x.c -o x   (Mach-O, linked by the engine's ld64.lld)
    darwin/<target>/libcompiler_rt.a   the builtins Zig links for that target

A config names its target with the minimum macOS version, `-isysroot` on the sysroot (clang then finds
the headers and `-lSystem` there and passes the matching `-platform_version` and `-syslibroot` to the
linker) and the engine's `ld64.lld`. It also sets `-nostdlib`, then names `-lSystem` and the target's own
`libcompiler_rt.a` itself, as Zig's link does: the clang driver would otherwise look for `libclang_rt.osx.a` in
the engine's resource directory, which only a macOS engine has and which is a fat file of its own choosing.
No Apple SDK, Xcode or `xcrun` is read at any point. Zig's SDKSettings.json is left out: it holds only a display name and
clang warns that it cannot parse it. Nothing is executed on the producer host: a Mach-O file is linked
and its load commands read, never run.

The payload is a local proof from an installed Zig, not an upstream-controlled build; its
provenance receipt says so and never certifies redistribution.
"""
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

import prepareEngine as pe
import prepareRuntime as pr

TARGET = "aarch64-macos"
X64_TARGET = "x86_64-macos"
ENGINE_RELATIVE = "../.."
PROVENANCE = "darwin-provenance.json"
MINIMUM_VERSION = "11.0"
MINOS = 0x000b0000
SYSROOT = "sysroot"
HEADERS = "include/any-darwin-any"
STUB = "darwin/libSystem.tbd"
MH_MAGIC_64 = 0xfeedfacf
MH_EXECUTE = 2
LC_LOAD_DYLIB = 0xc
LC_CODE_SIGNATURE = 0x1d
LC_BUILD_VERSION = 0x32
LC_MAIN = 0x80000028
PLATFORM_MACOS = 1
LIBSYSTEM = "/usr/lib/libSystem.B.dylib"
BUILTINS = "libcompiler_rt.a"
ZIG_TARGET_VERSION = "." + MINIMUM_VERSION

# What differs between the targets: the clang triple architecture and the Mach-O cpu type.
TARGETS = {
    TARGET: {"arch": "aarch64", "cpuType": 0x0100000c, "codeSignature": True},
    X64_TARGET: {"arch": "x86_64", "cpuType": 0x01000007, "codeSignature": False},
}
SPEC = {"notices": {"zig": ["../LICENSE"]}}
LIMITS = ["no macOS execution was available: the executables are linked and their Mach-O load commands read, never run",
          "no Apple SDK: only the headers and the libSystem stub Zig ships, so frameworks are not provided and the C++ "
          "library comes from prepareCppRuntime.py",
          "the builtins are Zig's libcompiler_rt.a for each target, not LLVM's libclang_rt.osx.a, which compiler-rt "
          "builds on Darwin only with xcrun and lipo",
          "the headers carry Apple's own license text in each file; Zig ships no separate license file for them",
          "LTO is exercised by the proof for both targets; C++ is not"]
FIXTURE = """#include <stdio.h>
#include <pthread.h>
#include <math.h>
static void* f(void* a){ printf("%g\\n", pow(2.0, 10)); return 0; }
static unsigned __int128 divide(unsigned __int128 a, unsigned __int128 b){ return a / b; }
int main(void){ volatile unsigned long x = 7; pthread_t t; pthread_create(&t,0,f,0); pthread_join(t,0);
  printf("%lu\\n", (unsigned long)divide((unsigned __int128)x << 70, 3 << 3)); puts("hello darwin"); return 0; }
"""
PROOF_FLAGS = (("-O0",), ("-O2", "-flto=thin"))


def configName(target):
    return target + ".cfg"


def renderDarwinConfig(target):
    """Text of RUNTIME/<target>.cfg."""
    arch = TARGETS[target]["arch"]
    return "\n".join([
        pr.configLine(["--target=%s-apple-macos%s" % (arch, MINIMUM_VERSION)]),
        pr.configLine(["-isysroot", "<CFGDIR>/" + SYSROOT]),
        pr.configLine(["--ld-path=<CFGDIR>/%s/bin/ld64.lld" % ENGINE_RELATIVE]),
        "-nostdlib",
        pr.configLine(["-Xlinker", "<CFGDIR>/%s/%s" % (target, BUILTINS)]),
        "$-lSystem",
    ]) + "\n"


def selectDarwinTargets(names):
    chosen = [t for t in TARGETS if t in names] if names else list(TARGETS)
    unknown = [n for n in names or [] if n not in TARGETS]
    if unknown or len(set(names or [])) != len(names or []):
        raise pe.EngineError("Darwin targets %s are unknown or duplicated; allowed: %s" % (names, ", ".join(TARGETS)))
    return chosen


def zigLibrary(zig):
    lib = os.path.join(os.path.dirname(os.path.realpath(zig)), "lib")
    if not os.path.isdir(os.path.join(lib, "libc", HEADERS)) or not os.path.isfile(os.path.join(lib, "libc", STUB)):
        raise pe.EngineError("Zig lib %s has no libc/%s or libc/%s" % (lib, HEADERS, STUB))
    return lib


def treeDigest(hashes):
    digest = hashlib.sha256()
    for name in sorted(hashes):
        digest.update(("%s %s\n" % (name.replace(os.sep, "/"), hashes[name])).encode("utf-8"))
    return digest.hexdigest()


def copySysroot(zigLib, darwin):
    """Copy the headers and the stub into darwin/sysroot. Returns their record for the receipt."""
    libc = os.path.join(zigLib, "libc")
    root = os.path.join(darwin, SYSROOT)
    pr.copyTree(os.path.join(libc, HEADERS), os.path.join(root, "usr", "include"))
    stub = os.path.join(root, "usr", "lib", "libSystem.tbd")
    os.makedirs(os.path.dirname(stub))
    shutil.copyfile(os.path.join(libc, STUB), stub)
    os.chmod(stub, 0o644)
    hashes = pr.treeHashes(os.path.join(root, "usr", "include"))
    return {"headers": {"source": "lib/libc/" + HEADERS, "directory": SYSROOT + "/usr/include",
                        "files": len(hashes), "treeSha256": treeDigest(hashes)},
            "stub": {"source": "lib/libc/" + STUB, "path": SYSROOT + "/usr/lib/libSystem.tbd",
                     "sha256": pe.sha256File(stub), "bytes": os.path.getsize(stub)}}


def zigBuiltins(zig, target, work):
    """The libcompiler_rt.a Zig links into a C program of target, found on the `zig ld` line of a run in a private
    cache."""
    private = os.path.join(work, "zig-" + target)
    os.makedirs(os.path.join(private, "local"))
    source = os.path.join(private, "runtimeDarwin.c")
    pe.writeText(source, FIXTURE)
    output = os.path.join(private, "fixture")
    environment = {"PATH": "/usr/bin:/bin", "HOME": private, "TMPDIR": private,
                   "ZIG_GLOBAL_CACHE_DIR": os.path.join(private, "global"),
                   "ZIG_LOCAL_CACHE_DIR": os.path.join(private, "local"), "ZIG_VERBOSE_LINK": "1"}
    command = [zig, "cc", "-target", TARGETS[target]["arch"] + "-macos" + ZIG_TARGET_VERSION, "-O2", source, "-o", output]
    try:
        done = subprocess.run(command, cwd=private, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=pr.ZIG_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise pe.EngineError("zig timed out after %d s for %s" % (pr.ZIG_TIMEOUT_SECONDS, target))
    if done.returncode != 0:
        raise pe.EngineError("zig failed for %s (%d): %s" % (target, done.returncode, done.stderr.strip()))
    found = [t for line in done.stderr.splitlines() if line.startswith("zig ld ") for t in line.split()
             if os.path.basename(t) == BUILTINS]
    if len(found) != 1 or not os.path.isfile(found[0]):
        raise pe.EngineError("Zig's link of %s names %d %s: %s" % (target, len(found), BUILTINS, found))
    return found[0]


def copyBuiltins(zig, engine, darwin, targets, work):
    """Copy each target's builtins to darwin/<target>/ with the debug info and member paths of Zig's cache dropped.
    Returns their records for the receipt."""
    records = {}
    for target in targets:
        destination = os.path.join(darwin, target, BUILTINS)
        os.makedirs(os.path.dirname(destination))
        produced = zigBuiltins(zig, target, work)
        shutil.copyfile(produced, destination)
        os.chmod(destination, 0o644)
        pr.normalizeInput(engine, destination)
        records[target] = {"path": "%s/%s" % (target, BUILTINS), "producedSha256": pe.sha256File(produced),
                           "sha256": pe.sha256File(destination),
                           "bytes": os.path.getsize(destination)}
    return records


def readMachO(path):
    """Cpu type, file type, load command kinds, dylibs and the macOS minos of a 64-bit little-endian Mach-O file."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        raise pe.EngineError("%s is not a 64-bit Mach-O file" % path)
    cpuType, _, fileType, count = struct.unpack_from("<iiII", data, 4)
    commands, dylibs, build, cursor = [], [], None, 32
    for _ in range(count):
        kind, size = struct.unpack_from("<II", data, cursor)
        commands.append(kind)
        if kind == LC_LOAD_DYLIB:
            offset = struct.unpack_from("<I", data, cursor + 8)[0]
            end = data.index(b"\0", cursor + offset)
            dylibs.append(data[cursor + offset:end].decode("ascii"))
        elif kind == LC_BUILD_VERSION:
            build = struct.unpack_from("<II", data, cursor + 8)
        cursor += size
    return {"cpuType": cpuType & 0xffffffff, "fileType": fileType, "commands": commands, "dylibs": dylibs, "build": build}


def machOProblem(info, target):
    """Why a linked file is not a console executable of target for macOS MINIMUM_VERSION, or None."""
    expected = TARGETS[target]
    if info["cpuType"] != expected["cpuType"]:
        return "cpu type %#x is not %s" % (info["cpuType"], expected["arch"])
    if info["fileType"] != MH_EXECUTE or LC_MAIN not in info["commands"]:
        return "file type %d with commands %s is not an executable with LC_MAIN" % (info["fileType"], info["commands"])
    if info["dylibs"] != [LIBSYSTEM]:
        return "dylibs %s are not exactly %s" % (info["dylibs"], LIBSYSTEM)
    if not info["build"] or info["build"][0] != PLATFORM_MACOS or info["build"][1] != MINOS:
        return "build version %s is not macOS %s" % (info["build"], MINIMUM_VERSION)
    if (LC_CODE_SIGNATURE in info["commands"]) != expected["codeSignature"]:
        return "LC_CODE_SIGNATURE is %s" % ("absent" if expected["codeSignature"] else "present")
    return None


def checkDarwinConfig(run, clang, runtime, work, target):
    """Compile and link the fixture through the config of target at each of PROOF_FLAGS: any nonzero exit or any
    stderr is an error, and the linked file is read as a Mach-O. Returns {flags: path of the linked file}."""
    source = os.path.join(work, "runtimeDarwin.c")
    pe.writeText(source, FIXTURE)
    outputs = {}
    for flags in PROOF_FLAGS:
        name = "".join(c for c in " ".join(flags) if c.isalnum())
        output = os.path.join(work, "fixture" + name)
        done = run([clang, "--no-default-config", "--config", os.path.join(runtime, configName(target))]
                   + list(flags) + [source, "-o", output])
        if done.returncode != 0 or done.stderr.strip():
            raise pe.EngineError("%s %s failed or warned (%d): %s" % (target, " ".join(flags), done.returncode,
                                                                      done.stderr.strip()))
        problem = machOProblem(readMachO(output), target)
        if problem:
            raise pe.EngineError("%s %s: %s" % (target, " ".join(flags), problem))
        outputs[" ".join(flags)] = output
    return outputs


def verifyConfigs(engine, darwin, targets, work):
    """checkDarwinConfig of every target on a copy of the runtime two levels below an engine tree, the layout of a bundle."""
    root = os.path.join(work, "verify")
    runtime = os.path.join(root, "runtime")
    os.makedirs(runtime)
    shutil.copytree(darwin, os.path.join(runtime, "darwin"), symlinks=True)
    pr.linkEngineBeside(engine, root, runtime)
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    run = lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, universal_newlines=True)
    for target in targets:
        scratch = os.path.join(work, "verify-" + target)
        os.makedirs(scratch)
        checkDarwinConfig(run, os.path.join(root, "bin", "clang"), os.path.join(runtime, "darwin"), scratch, target)


def writeProvenance(darwin, zigId, host, engineVersion, targets, sysroot, builtins, notices):
    receipt = {
        "kind": "local-zig-darwin-runtime-proof",
        "statement": "Produced by copying the macOS libc headers and the libSystem stub of a locally installed Zig, "
                     "with one clang config per target. Not an upstream-controlled build and not an Apple SDK.",
        "redistributionCertified": False,
        "zig": zigId, "producerHost": host, "engineVersion": engineVersion,
        "targets": targets, "engineRelative": ENGINE_RELATIVE, "minimumMacosVersion": MINIMUM_VERSION,
        "configs": {t: configName(t) for t in targets}, "sysroot": SYSROOT, "sysrootContents": sysroot,
        "builtins": builtins,
        "zigFilesNotCarried": ["lib/libc/darwin/SDKSettings.json"],
        "notices": notices, "limits": LIMITS,
        "linkerFlavor": "the engine's ld64.lld, named by --ld-path in each config",
    }
    os.makedirs(os.path.join(darwin, "notices"), exist_ok=True)
    pe.writeText(os.path.join(darwin, "notices", PROVENANCE), json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def prepareDarwinRuntime(zig, engine, darwin, targets=None):
    """Write the Darwin runtime of `targets` (every target of TARGETS when none) to the new directory
    `darwin`, whose engine is two levels up in a bundle. Returns (darwin, targets)."""
    zig, engine, darwin = (os.path.abspath(p) for p in (zig, engine, darwin))
    targets = selectDarwinTargets(targets)
    if os.path.lexists(darwin):
        raise pe.EngineError("output %s exists; it is never replaced" % darwin)
    if not os.access(zig, os.X_OK):
        raise pe.EngineError("--zig %s is not executable" % zig)
    host, version, _ = pr.engineMajor(engine)
    zigId = pr.zigIdentity(zig)
    zigLib = zigLibrary(zig)
    os.makedirs(os.path.dirname(darwin), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(darwin) + ".partial-", dir=os.path.dirname(darwin))
    work = tempfile.mkdtemp(prefix="prepareDarwinRuntime-")
    try:
        sysroot = copySysroot(zigLib, partial)
        builtins = copyBuiltins(zig, engine, partial, targets, work)
        for target in targets:
            pe.writeText(os.path.join(partial, configName(target)), renderDarwinConfig(target))
        notices = pr.copyNotices(partial, zigLib, SPEC)
        verifyConfigs(engine, partial, targets, work)
        writeProvenance(partial, zigId, host, version, targets, sysroot, builtins, notices)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, darwin)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return darwin, targets


def prepareRuntimeDirectory(zig, engine, output, targets=None):
    """The standalone form: a new RUNTIME directory holding only `darwin/`."""
    output = os.path.abspath(output)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        prepared = prepareDarwinRuntime(zig, engine, os.path.join(partial, "darwin"), targets)[1]
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return output, prepared


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zig", required=True)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--target", action="append", default=[], help="a macOS target; every target when none")
    args = parser.parse_args(argv)
    try:
        output, targets = prepareRuntimeDirectory(args.zig, args.engine, args.output, args.target)
    except pe.EngineError as error:
        print("prepareDarwinRuntime: error: %s" % error, file=sys.stderr)
        return 1
    print("targets: %s" % ", ".join(targets))
    print("runtime written to %s" % output)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
