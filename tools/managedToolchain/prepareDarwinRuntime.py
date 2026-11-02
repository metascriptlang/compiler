#!/usr/bin/env python3
"""Prepare the aarch64-macos and x86_64-macos runtimes from the macOS libc headers and libSystem stub a local Zig ships.

    prepareDarwinRuntime.py --zig ZIG --engine ENGINE_DIR --output NEW_RUNTIME_DIR [--target T ...]

NEW_RUNTIME_DIR receives `darwin/`; in a bundle the same directory is `runtime/darwin/`, and the
engine is `../..` from it. There is no Apple SDK: the sysroot is what Zig itself links macOS programs
against, copied opaquely:

    darwin/sysroot/usr/include/        Zig's include/any-darwin-any
    darwin/sysroot/usr/lib/libSystem.tbd   Zig's libc/darwin stub
    darwin/<target>.cfg                clang --config ... x.c -o x   (Mach-O, linked by the engine's ld64.lld)

A config names its target with the minimum macOS version, `-isysroot` on the sysroot (clang then finds
the headers and `-lSystem` there and passes the matching `-platform_version` and `-syslibroot` to the
linker) and the engine's `ld64.lld`. Zig's SDKSettings.json is left out: it holds only a display name and
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
LC_SEGMENT_64, LC_ID_DYLIB, LC_LOAD_DYLINKER = 0x19, 0xd, 0xe
DYLINKER = "/usr/lib/dyld"
PLATFORM_MACOS = 1
LIBSYSTEM = "/usr/lib/libSystem.B.dylib"

# What differs between the targets: the clang triple architecture and the Mach-O cpu type.
TARGETS = {
    TARGET: {"arch": "aarch64", "cpuType": 0x0100000c, "codeSignature": True},
    X64_TARGET: {"arch": "x86_64", "cpuType": 0x01000007, "codeSignature": False},
}
SPEC = {"notices": {"zig": ["../LICENSE"]}}
LIMITS = ["no macOS execution was available: the executables are linked and their Mach-O load commands read, never run",
          "no Apple SDK: only the headers and the libSystem stub Zig ships, so frameworks and the C++ library are not provided",
          "the headers carry Apple's own license text in each file; Zig ships no separate license file for them",
          "LTO is exercised by the proof for both targets; C++ is not"]
FIXTURE = """#include <stdio.h>
#include <pthread.h>
#include <math.h>
static void* f(void* a){ printf("%g\\n", pow(2.0, 10)); return 0; }
int main(void){ pthread_t t; pthread_create(&t,0,f,0); pthread_join(t,0); puts("hello darwin"); return 0; }
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


def readMachO(path):
    """Bounded load commands, sections, library names and platform facts of a 64-bit little-endian Mach-O file."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        raise pe.EngineError("%s is not a 64-bit Mach-O file" % path)
    cpuType, _, fileType, count, commandBytes = struct.unpack_from("<iiIII", data, 4)
    commands, dylibs, sections, build, installName, dylinker, cursor = [], [], [], None, None, None, 32
    end = cursor + commandBytes
    def malformed(reason):
        raise pe.EngineError("%s: malformed Mach-O: %s" % (path, reason))
    if end > len(data) or count * 8 > commandBytes:
        malformed("load command table extends past its bounds")
    for _ in range(count):
        if cursor + 8 > end:
            malformed("truncated load command")
        kind, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or size % 8 or cursor + size > end:
            malformed("invalid load command size %d" % size)
        command = data[cursor:cursor + size]
        commands.append(kind)
        if kind in (LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_DYLINKER, 0x20, 0x80000018, 0x8000001f, 0x80000023):
            minimum = 12 if kind == LC_LOAD_DYLINKER else 24
            if size < minimum:
                malformed("short library name command")
            offset = struct.unpack_from("<I", command, 8)[0]
            stop = command.find(b"\0", offset)
            if offset < minimum or offset >= size or stop < 0:
                malformed("library name extends outside its command")
            try:
                name = command[offset:stop].decode("utf-8")
            except UnicodeDecodeError:
                malformed("library name is not UTF-8")
            if kind == LC_ID_DYLIB:
                if installName is not None:
                    malformed("duplicate LC_ID_DYLIB")
                installName = name
            elif kind == LC_LOAD_DYLINKER:
                if dylinker is not None:
                    malformed("duplicate LC_LOAD_DYLINKER")
                dylinker = name
            else:
                dylibs.append(name)
        elif kind == LC_BUILD_VERSION:
            if size < 24 or build is not None:
                malformed("short or duplicate LC_BUILD_VERSION")
            if 24 + 8 * struct.unpack_from("<I", command, 20)[0] > size:
                malformed("build tools extend outside their command")
            build = struct.unpack_from("<II", command, 8)
        elif kind == LC_SEGMENT_64:
            if size < 72:
                malformed("short LC_SEGMENT_64")
            countSections = struct.unpack_from("<I", command, 64)[0]
            if 72 + 80 * countSections > size:
                malformed("section table extends outside its segment command")
            for at in range(72, 72 + 80 * countSections, 80):
                try:
                    sections.append(tuple(command[at + offset:at + offset + 16].split(b"\0")[0].decode("ascii")
                                          for offset in (16, 0)))
                except UnicodeDecodeError:
                    malformed("section name is not ASCII")
        cursor += size
    if cursor != end:
        malformed("load commands do not cover sizeofcmds")
    return {"cpuType": cpuType & 0xffffffff, "fileType": fileType, "commands": commands, "dylibs": dylibs, "build": build,
            "sections": sections, "installName": installName, "dylinker": dylinker}


def machOProblem(info, target):
    """Why a linked file is not a console executable of target for macOS MINIMUM_VERSION, or None."""
    expected = TARGETS[target]
    if info["cpuType"] != expected["cpuType"]:
        return "cpu type %#x is not %s" % (info["cpuType"], expected["arch"])
    if info["fileType"] != MH_EXECUTE or LC_MAIN not in info["commands"]:
        return "file type %d with commands %s is not an executable with LC_MAIN" % (info["fileType"], info["commands"])
    if info["dylinker"] != DYLINKER:
        return "dynamic linker %s is not %s" % (info["dylinker"], DYLINKER)
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


def writeProvenance(darwin, zigId, host, engineVersion, targets, sysroot, notices):
    receipt = {
        "kind": "local-zig-darwin-runtime-proof",
        "statement": "Produced by copying the macOS libc headers and the libSystem stub of a locally installed Zig, "
                     "with one clang config per target. Not an upstream-controlled build and not an Apple SDK.",
        "redistributionCertified": False,
        "zig": zigId, "producerHost": host, "engineVersion": engineVersion,
        "targets": targets, "engineRelative": ENGINE_RELATIVE, "minimumMacosVersion": MINIMUM_VERSION,
        "configs": {t: configName(t) for t in targets}, "sysroot": SYSROOT, "sysrootContents": sysroot,
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
        for target in targets:
            pe.writeText(os.path.join(partial, configName(target)), renderDarwinConfig(target))
        notices = pr.copyNotices(partial, zigLib, SPEC)
        verifyConfigs(engine, partial, targets, work)
        writeProvenance(partial, zigId, host, version, targets, sysroot, notices)
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
