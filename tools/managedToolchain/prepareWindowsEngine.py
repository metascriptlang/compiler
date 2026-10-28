#!/usr/bin/env python3
"""Prepare a relocatable native clang/lld engine bundle for Windows x86_64 from an installed LLVM.

    prepareWindowsEngine.py --llvm-root DIR --license FILE --output NEW_DIR
    prepareWindowsEngine.py --verify BUNDLE_DIR [--inspector LLVM_READOBJ]

Runs on native Windows x86_64 only. The bundle has the layout and contract files of prepareEngine.py (HOST
x86_64-windows): the twelve .exe tools of the LLVM root's bin/ (the eleven compiler and linker tools and llvm-readobj)
and the resource directory lib/clang/MAJOR. The upstream payload ships no license, so --license names the exact-release
license file, copied to notices/LICENSE.TXT with its hash recorded; it is never fetched.

Every PE file of bin/ is read, never run, with the bundle's own llvm-readobj: the machine must be AMD64, the image PE32+
and an executable image, an .exe must not be a DLL and a .dll must be one. Each DLL it imports, normal or delayed, must be
an operating system library of SYSTEM_DLLS or a file of the source bin/, which is copied under its own exact name with its
own imports followed in turn. Names are matched with their case folded, so two source files that fold to one name, or a
source DLL that would shadow a system library, are refused. The names of SYSTEM_DLLS are the ones the upstream tools were
observed to import; any other name is a missing file, never an accepted system library.

The bundle is a local proof built from an installed LLVM and an operator-supplied license, not an upstream-controlled
build; its provenance receipt names the source file and hash of every copied file and never certifies redistribution.
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

import prepareEngine as pe
import prepareRuntime as pr

MACHINE_AMD64 = 0x8664
MAGIC_PE32_PLUS = 0x20B
IMAGE_EXECUTABLE = 0x2
IMAGE_DLL = 0x2000
INSPECTOR = "llvm-readobj.exe"
TOOLS = ("clang.exe", "clang++.exe", "lld.exe", "ld.lld.exe", "lld-link.exe", "wasm-ld.exe", "llvm-ar.exe",
         "llvm-ranlib.exe", "llvm-strip.exe", "llvm-objcopy.exe", "llvm-nm.exe", INSPECTOR)
SYSTEM_DLLS = frozenset(("advapi32.dll", "kernel32.dll", "ntdll.dll", "ole32.dll", "oleaut32.dll", "shell32.dll",
                         "user32.dll", "version.dll"))
RESOURCE_PREFIX = "lib/clang/"
INCLUDE = "lib/clang/%s/include/stddef.h"
BUILTINS = "lib/clang/%s/lib/windows/clang_rt.builtins-x86_64.lib"
LICENSE = "notices/LICENSE.TXT"
INSPECT_FLAGS = ("--file-headers", "--coff-imports")
BLOCK_START = re.compile(r"^([A-Za-z]+) \{$")
MACHINE_LINE = re.compile(r"^  Machine: .*\(0x([0-9a-fA-F]+)\)$")
CHARACTERISTICS_LINE = re.compile(r"^  Characteristics \[ \(0x([0-9a-fA-F]+)\)$")
MAGIC_LINE = re.compile(r"^  Magic: 0x([0-9a-fA-F]+)$")
NAME_LINE = re.compile(r"^  Name: (\S.*\S|\S)$")


def detectHost():
    if sys.platform != "win32":
        raise pe.EngineError("unsupported host %s: only native Windows x86_64 is implemented" % sys.platform)
    if platform.machine().upper() not in ("AMD64", "X86_64"):
        raise pe.EngineError("unsupported host windows %s: only x86_64 is implemented" % platform.machine())
    return pe.WINDOWS_X64


def isPe(path):
    with open(path, "rb") as f:
        return f.read(2) == b"MZ"


def inspect(inspector, flags, path):
    done = subprocess.run([inspector, *flags, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    if done.returncode != 0:
        raise pe.EngineError("%s: %s failed (%d): %s" % (path, os.path.basename(inspector), done.returncode, done.stderr.strip()))
    if done.stderr.strip():
        raise pe.EngineError("%s: %s warned: %s" % (path, os.path.basename(inspector), done.stderr.strip()))
    return done.stdout


def readBlocks(path, text):
    blocks, current = [], None
    for line in text.splitlines():
        start = BLOCK_START.match(line)
        if current is None:
            if start:
                current = (start.group(1), [])
        elif line == "}":
            blocks.append(current)
            current = None
        elif start:
            raise pe.EngineError("%s: inspector block %s starts inside block %s" % (path, start.group(1), current[0]))
        else:
            current[1].append(line)
    if current is not None:
        raise pe.EngineError("%s: inspector output ends inside block %s" % (path, current[0]))
    return blocks


def hexField(path, block, pattern, what):
    found = [m.group(1) for m in (pattern.match(line) for line in block) if m]
    if len(found) != 1:
        raise pe.EngineError("%s: inspector output has %d %s lines, not one" % (path, len(found), what))
    return int(found[0], 16)


def readImports(path, blocks):
    imports = {"Import": [], "DelayImport": []}
    for name, lines in blocks:
        if name in imports:
            match = NAME_LINE.match(lines[0]) if lines else None
            if not match:
                raise pe.EngineError("%s: %s block has no Name line first" % (path, name))
            imports[name].append(match.group(1))
    return imports


def readPe(path, inspector):
    """The facts of a PE file as a dict, or None when path is not one. An inspector output that lacks a header,
    names an import without its Name line, or warns, is an error."""
    if not isPe(path):
        return None
    blocks = readBlocks(path, inspect(inspector, INSPECT_FLAGS, path))
    named = {name: [lines for n, lines in blocks if n == name] for name in ("ImageFileHeader", "ImageOptionalHeader")}
    for name, found in named.items():
        if len(found) != 1:
            raise pe.EngineError("%s: inspector output has %d %s blocks, not one" % (path, len(found), name))
    imports = readImports(path, blocks)
    header, optional = named["ImageFileHeader"][0], named["ImageOptionalHeader"][0]
    return {"machine": hexField(path, header, MACHINE_LINE, "ImageFileHeader Machine"),
            "characteristics": hexField(path, header, CHARACTERISTICS_LINE, "ImageFileHeader Characteristics"),
            "magic": hexField(path, optional, MAGIC_LINE, "ImageOptionalHeader Magic"),
            "imports": imports["Import"], "delayImports": imports["DelayImport"]}


def roleProblem(rel, info):
    if info["machine"] != MACHINE_AMD64:
        return "machine 0x%x, not AMD64 (0x%x)" % (info["machine"], MACHINE_AMD64)
    if info["magic"] != MAGIC_PE32_PLUS:
        return "optional header magic 0x%x, not PE32+ (0x%x)" % (info["magic"], MAGIC_PE32_PLUS)
    if not info["characteristics"] & IMAGE_EXECUTABLE:
        return "is not an executable image (characteristics 0x%x)" % info["characteristics"]
    isDll = bool(info["characteristics"] & IMAGE_DLL)
    if rel.casefold().endswith(".exe") and isDll:
        return "is a DLL image, required to be an executable of %s" % rel
    if rel.casefold().endswith(".dll") and not isDll:
        return "is an executable image, required to be a DLL of %s" % rel
    return None


def importedNames(info):
    return info["imports"] + info["delayImports"]


def checkBasename(owner, name):
    if not name or "/" in name or "\\" in name or ":" in name or "\0" in name or name in (".", ".."):
        raise pe.EngineError("%s: imports %r, which is not a file basename" % (owner, name))
    if not name.casefold().endswith(".dll"):
        raise pe.EngineError("%s: imports %s, which is not a .dll file name" % (owner, name))


def sourceListing(binDir):
    listing = {}
    for name in os.listdir(binDir):
        listing.setdefault(name.casefold(), []).append(name)
    return listing


def sourceFile(binDir, listing, name, owner, exact=False):
    """(actual file name, path) of the one file of binDir that name matches with its case folded."""
    found = listing.get(name.casefold(), [])
    if not found:
        raise pe.EngineError("%s: needs %s, which is not in %s and is not a system library of %s" % (
            owner, name, binDir, ", ".join(sorted(SYSTEM_DLLS))))
    if len(found) > 1:
        raise pe.EngineError("%s: %s matches %d files of %s differing only by case: %s" % (
            owner, name, len(found), binDir, ", ".join(sorted(found))))
    if exact and found[0] != name:
        raise pe.EngineError("%s holds %s, but the tool must be named exactly %s" % (binDir, found[0], name))
    path = os.path.join(binDir, found[0])
    if pe.isLinkLike(path) or not os.path.isfile(path):
        raise pe.EngineError("%s is not a regular file" % path)
    return found[0], path


def addPlanned(plan, folds, dest, source):
    held = folds.setdefault(dest.casefold(), dest)
    if held != dest:
        raise pe.EngineError("%s and %s differ only by case" % (held, dest))
    if plan.get(dest, source) != source:
        raise pe.EngineError("%s collides: %s and %s" % (dest, plan[dest], source))
    plan[dest] = source


def planClosure(plan, folds, binDir, listing, inspector):
    infos, queue = {}, sorted(d for d in plan if d.startswith("bin/"))
    while queue:
        dest = queue.pop()
        info = readPe(plan[dest], inspector)
        if info is None:
            raise pe.EngineError("%s: not a PE image" % plan[dest])
        problem = roleProblem(dest, info)
        if problem:
            raise pe.EngineError("%s: %s" % (plan[dest], problem))
        infos[dest] = info
        for name in importedNames(info):
            checkBasename(plan[dest], name)
            if name.casefold() in SYSTEM_DLLS:
                continue
            exact, path = sourceFile(binDir, listing, name, plan[dest])
            wanted = "bin/" + exact
            if wanted not in plan:
                queue.append(wanted)
            addPlanned(plan, folds, wanted, path)
    return infos


def bundledInspector(root):
    try:
        detectHost()
    except pe.EngineError as error:
        raise pe.EngineError("%s: cannot run the bundle's own bin/%s here (%s); pass --inspector" % (root, INSPECTOR, error))
    path = os.path.join(root, "bin", INSPECTOR)
    if pe.isLinkLike(path):
        raise pe.EngineError("bin/%s is a symlink or reparse point" % INSPECTOR)
    return path


def verifyLayout(root, version):
    major = version.split(".")[0]
    for rel in ["bin/" + t for t in TOOLS] + [INCLUDE % major, BUILTINS % major, "notices/provenance.json", LICENSE]:
        if not os.path.isfile(os.path.join(root, rel)):
            raise pe.EngineError("layout: missing %s" % rel)
    if os.path.getsize(os.path.join(root, LICENSE)) == 0:
        raise pe.EngineError("layout: %s is empty" % LICENSE)


def verifyEngine(root, host, version, inspector=None):
    """Audit the layout and every PE file of bin/ with the inspector; returns the number of PE files audited."""
    if host != pe.WINDOWS_X64:
        raise pe.EngineError("%s is not a %s bundle" % (root, pe.WINDOWS_X64))
    verifyLayout(root, version)
    if inspector and (not os.path.isfile(inspector) or not os.access(inspector, os.X_OK)):
        raise pe.EngineError("--inspector %s is not an executable file" % inspector)
    inspector = inspector or bundledInspector(root)
    files = [rel for rel in pe.listFiles(root) if rel.startswith("bin/")]
    folds = {}
    for rel in files:
        name = rel[len("bin/"):]
        if "/" in name or not name.casefold().endswith((".exe", ".dll")):
            raise pe.EngineError("%s: bin/ holds only .exe and .dll files directly" % rel)
        if folds.setdefault(name.casefold(), rel) != rel:
            raise pe.EngineError("%s and %s differ only by case" % (folds[name.casefold()], rel))
        if name.casefold() in SYSTEM_DLLS:
            raise pe.EngineError("%s would shadow the system library %s" % (rel, name))
        if pe.isLinkLike(os.path.join(root, rel)):
            raise pe.EngineError("%s is a symlink or reparse point" % rel)
    infos = {}
    for rel in files:
        path = os.path.join(root, rel)
        info = readPe(path, inspector)
        if info is None:
            raise pe.EngineError("%s: not a PE image" % rel)
        problem = roleProblem(rel, info)
        if problem:
            raise pe.EngineError("%s: %s" % (rel, problem))
        infos[rel] = info
    for rel, info in infos.items():
        for name in importedNames(info):
            checkBasename(rel, name)
            if name.casefold() not in SYSTEM_DLLS and name.casefold() not in folds:
                raise pe.EngineError("%s: imports %s, which is not in bin/ and is not a system library of %s" % (
                    rel, name, ", ".join(sorted(SYSTEM_DLLS))))
    return len(infos)


def refuseResourceLinks(llvmRoot):
    clang = os.path.join(llvmRoot, "lib", "clang")
    for held in (os.path.join(llvmRoot, "lib"), clang):
        if os.path.lexists(held) and pe.isLinkLike(held):
            raise pe.EngineError("symlink in resource directory: %s" % os.path.basename(held))
    for directory, dirnames, filenames in os.walk(clang):
        for name in dirnames + filenames:
            if pe.isLinkLike(os.path.join(directory, name)):
                raise pe.EngineError("symlink in resource directory: %s" % name)


def refuseOutside(llvmRoot, plan):
    for dest, source in sorted(plan.items()):
        if not pe.containsPath(llvmRoot, source):
            raise pe.EngineError("%s: source %s is outside the LLVM root %s" % (dest, source, llvmRoot))


def readLicense(path):
    if not path:
        raise pe.EngineError("--license is required: the upstream LLVM payload ships no license file")
    path = os.path.abspath(path)
    if os.path.islink(path) or not os.path.isfile(path):
        raise pe.EngineError("--license %s is not a regular file" % path)
    if os.path.getsize(path) == 0:
        raise pe.EngineError("--license %s is empty" % path)
    return path


def writeProvenance(root, versions, tools, license, files):
    receipt = {
        "kind": "local-windows-llvm-proof",
        "statement": "Prepared from a locally installed LLVM and an operator-supplied license file. Not an upstream-controlled build.",
        "redistributionCertified": False,
        "host": pe.WINDOWS_X64,
        "clangVersion": versions[0],
        "lldVersion": versions[1],
        "inspector": tools,
        "license": license,
        "systemDlls": sorted(SYSTEM_DLLS),
        "files": files,
    }
    pe.writeText(os.path.join(root, "notices", "provenance.json"), json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def prepareEngine(llvmRoot, licensePath, output):
    host = detectHost()
    llvmRoot, output = os.path.abspath(llvmRoot), os.path.abspath(output)
    if not os.path.isdir(llvmRoot):
        raise pe.EngineError("--llvm-root %s is not a directory" % llvmRoot)
    licensePath = readLicense(licensePath)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    if pe.containsPath(llvmRoot, os.path.dirname(output)):
        raise pe.EngineError("output must not be inside the source root")
    binDir = os.path.join(llvmRoot, "bin")
    if not os.path.isdir(binDir):
        raise pe.EngineError("%s has no bin directory" % llvmRoot)
    if pe.isLinkLike(binDir):
        raise pe.EngineError("%s is a symlink or reparse point" % binDir)
    refuseResourceLinks(llvmRoot)
    listing = sourceListing(binDir)
    for key, names in sorted(listing.items()):
        if key in SYSTEM_DLLS:
            raise pe.EngineError("%s holds %s, which would shadow the system library" % (binDir, ", ".join(sorted(names))))
    plan, folds = {}, {}
    for tool in TOOLS:
        addPlanned(plan, folds, "bin/" + tool, sourceFile(binDir, listing, tool, llvmRoot, exact=True)[1])
    refuseOutside(llvmRoot, plan)
    inspector = plan["bin/" + INSPECTOR]
    tools = {"version": pe.toolVersion(inspector, r"LLVM version (\d+\.\d+\.\d+)"), "sha256": pe.sha256File(inspector)}
    version = pe.toolVersion(plan["bin/clang.exe"], r"clang version (\d+\.\d+\.\d+)")
    lldVersion = pe.toolVersion(plan["bin/ld.lld.exe"], r"LLD (\d+\.\d+\.\d+)")
    if lldVersion != version:
        raise pe.EngineError("lld %s does not match clang %s" % (lldVersion, version))
    major = version.split(".")[0]
    resource = os.path.join(llvmRoot, "lib", "clang", major)
    if not os.path.isdir(resource):
        raise pe.EngineError("missing resource directory %s" % resource)
    for directory, dirnames, filenames in os.walk(resource):
        for name in filenames:
            source = os.path.join(directory, name)
            addPlanned(plan, folds, RESOURCE_PREFIX + major + "/" + os.path.relpath(source, resource).replace(os.sep, "/"), source)
    for rel in (INCLUDE % major, BUILTINS % major):
        if rel not in plan:
            raise pe.EngineError("missing %s in %s" % (rel, llvmRoot))
    infos = planClosure(plan, folds, binDir, listing, inspector)
    refuseOutside(llvmRoot, plan)
    licenseRecord = {"source": licensePath, "sha256": pe.sha256File(licensePath), "bytes": os.path.getsize(licensePath),
                     "copy": LICENSE, "statement": "supplied by the operator and not checked against the release"}

    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        for dest, source in sorted(plan.items()):
            target = os.path.join(partial, dest)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(source, target)
        os.makedirs(os.path.join(partial, "notices"), exist_ok=True)
        shutil.copyfile(licensePath, os.path.join(partial, LICENSE))
        files = [dict({"path": dest, "source": plan[dest], "sourceSha256": pe.sha256File(plan[dest])},
                      **({"imports": importedNames(infos[dest])} if dest in infos else {}))
                 for dest in sorted(plan) if not dest.startswith(RESOURCE_PREFIX)]
        writeProvenance(partial, (version, lldVersion), tools, licenseRecord, files)
        pe.writeContract(partial, host, version)
        verified = pe.verifyEngine(partial, inspector)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return output, verified, plan, licenseRecord


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--llvm-root")
    parser.add_argument("--license")
    parser.add_argument("--output")
    parser.add_argument("--verify", metavar="BUNDLE_DIR")
    parser.add_argument("--inspector")
    args = parser.parse_args(argv)
    try:
        if args.verify:
            host, version = pe.verifyContract(args.verify)
            if host != pe.WINDOWS_X64:
                raise pe.EngineError("%s is a %s bundle, not %s" % (args.verify, host, pe.WINDOWS_X64))
            print("verified host=%s version=%s pe=%d" % (host, version, verifyEngine(args.verify, host, version, args.inspector)))
            return 0
        if not (args.llvm_root and args.output):
            parser.error("--llvm-root and --output are required")
        output, (host, version, count), plan, licenseRecord = prepareEngine(args.llvm_root, args.license, args.output)
        with open(os.path.join(output, "IDENTITY"), encoding="utf-8") as f:
            identity = f.read().strip()
        sources = sorted({os.path.abspath(args.llvm_root), os.path.realpath(args.llvm_root)})
        print("prepared %s" % output)
        print("host=%s version=%s identity=%s" % (host, version, identity))
        print("files=%d pe=%d bytes=%d" % (len(pe.listFiles(output)), count,
                                           sum(os.path.getsize(os.path.join(output, r)) for r in pe.listFiles(output))))
        print("license=%s sha256=%s" % (licenseRecord["source"], licenseRecord["sha256"]))
        for rel, found in pe.sourcePathLiterals(output, sources, isPe).items():
            print("source path literal in data: %s x%d" % (rel, found))
        print("redistribution NOT certified; local proof from an installed LLVM and an operator-supplied license")
        return 0
    except pe.EngineError as error:
        print("prepareWindowsEngine: error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
