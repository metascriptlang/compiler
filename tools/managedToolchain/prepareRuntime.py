#!/usr/bin/env python3
"""Prepare target runtime payloads with a local Zig, then prove them with clang and lld alone.

    prepareRuntime.py --zig ZIG --engine ENGINE_DIR --output NEW_DIR [--target T ...]
    prepareRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--zig ZIG] [--deny PATH ...]

Production runs Zig once per target on a fixture with private caches, so every runtime file
is attributable to that run, and copies the ordered inputs of the link line and the ordered
include directories of the compile line it printed. Each target gets a native clang config
file (`clang --config RUNTIME/T.cfg -c x.c`, then `clang --config RUNTIME/T.cfg x.o -o out`);
the payload carries no Zig. Each config also names its target directory as the linker's library
search root, and a glibc stub `libNAME.so.N` gets the regular alias `libNAME.so` (a relative
symlink in the same directory), so the `-lm -lpthread` a build line appends are found without the
caller knowing the layout. A wasm32-wasi runtime has its math in `libc.a`, so the `-lm` a build line
appends gets the standard empty `libm.a` beside it, made with the engine's `llvm-ar` in GNU format
(the sysroot convention of an empty archive for each library flag the libc already satisfies); the
receipt records it and verification refuses an archive that is not empty. The engine is found from the config file by a relative path
(`--engine-relative`): siblings by default (`../engine`), or `..` when the runtime is a child of
the engine root, as in a full bundle.

The payload is a local proof from an installed Zig, not an upstream-controlled build; its
provenance receipt says so and never certifies redistribution.
"""
import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import prepareEngine as pe

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
ZIG_TIMEOUT_SECONDS = 3600
CONFIG_TOKEN = re.compile(r"^[A-Za-z0-9_.+=:/<>,@%-]+$")
SHARED_OBJECT = re.compile(r"\.so(\.\d+)*$")
EMPTY_ARCHIVE = b"!<arch>\n"
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.+-]+$")
VERSIONED_STUB = re.compile(r"^lib([A-Za-z0-9_+-]+)\.so\.\d+$")
# Zig's `ld` stub is the dynamic linker (soname ld-linux-*.so.2 or .so.1); glibc has no `libld.so` for it.
NO_LINKER_NAME = ("ld",)
LINK_VALUED = ("-o", "-z", "--entry", "-m", "--dynamic-linker", "-mllvm")
PIC_FLAGS = ("-fno-PIE", "-fPIE", "-fno-PIC", "-fPIC", "-fno-pie", "-fpie", "-fno-pic", "-fpic")
WASI_LICENSES = ("LICENSE", "LICENSE-APACHE", "LICENSE-APACHE-LLVM", "LICENSE-MIT")
EXPECTED_OUTPUT = "ok sum=14 sqrt=1.414 wide=120 eps=1\n"
LLVM_X86_SOURCES = ["https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-%s/llvm/lib/Target/X86/X86.td" % v
                    for v in ("21.1.0", "22.1.1")]

REMOVED_DISABLED_FEATURES = [{
    "feature": "-amx-transpose", "zig": "0.16.0", "engineMajor": "22", "target": target,
    "cpu": "x86-64", "absentMacroPrefix": "__AMX_",
    "reason": "defined by LLVM 21 (FeatureAMXTRANSPOSE) and removed by LLVM 22; x86-64 enables no AMX feature in either",
    "sources": LLVM_X86_SOURCES,
} for target in ("x86_64-linux-gnu.2.31", "x86_64-windows-gnu")]


def llvmSource(version, path, line=None):
    """A pinned LLVM source URL; without a line it names the whole file, for a definition the version lacks."""
    return "https://github.com/llvm/llvm-project/blob/llvmorg-%s/llvm/%s%s" % (
        version, path, "#L%d" % line if line else "")


def aarch64Source(version, name, line=None):
    return llvmSource(version, "lib/Target/AArch64/" + name, line)


AARCH64_GENERIC = [aarch64Source("21.1.0", "AArch64Processors.td", 1127), aarch64Source("21.1.0", "AArch64Processors.td", 1138),
                   aarch64Source("22.1.1", "AArch64Processors.td", 1388), aarch64Source("22.1.1", "AArch64Processors.td", 1399)]
FIELD_DEFAULT = [llvmSource("21.1.0", "utils/TableGen/SubtargetEmitter.cpp", 159),
                 llvmSource("22.1.1", "utils/TableGen/SubtargetEmitter.cpp", 172)]

REMOVED_DISABLED_FEATURES += [{
    "feature": feature, "zig": "0.16.0", "engineMajor": "22", "target": "aarch64-windows-gnu", "cpu": "generic",
    "absentMacroPrefix": macro, "reason": reason, "sources": sources + AARCH64_GENERIC,
} for feature, macro, reason, sources in (
    ("-no-zcz-fp", None,
     "LLVM 22 renames no-zcz-fp (HasZeroCycleZeroingFP) to no-zcz-fpr64 (HasZeroCycleZeroingFPR64); a disabled "
     "feature leaves its field at the generated default, true for both, and emitFMov0 emits movi d in both",
     [aarch64Source("21.1.0", "AArch64Features.td", 637), aarch64Source("22.1.1", "AArch64Features.td", 700),
      aarch64Source("21.1.0", "AArch64AsmPrinter.cpp", 1829), aarch64Source("22.1.1", "AArch64AsmPrinter.cpp", 1922)]
     + FIELD_DEFAULT),
    ("-tme", "__ARM_FEATURE_TME",
     "defined in LLVM 21 and without a definition in LLVM 22; generic enables no TME, so ignoring the disabled "
     "feature leaves the same state",
     [aarch64Source("21.1.0", "AArch64Features.td", 397), aarch64Source("22.1.1", "AArch64Features.td")]),
    ("-zcz", None,
     "LLVM 22 replaces the aggregate zcz (implying zcz-gp) with zcz-gpr32, zcz-gpr64 and zcz-fpr128; generic "
     "enables none of them in either version and their fields default false",
     [aarch64Source("21.1.0", "AArch64Features.td", 640), aarch64Source("22.1.1", "AArch64Features.td", 687),
      aarch64Source("22.1.1", "AArch64Features.td", 690), aarch64Source("22.1.1", "AArch64Features.td", 693)]
     + FIELD_DEFAULT),
    ("-zcz-gp", None,
     "LLVM 22 splits zcz-gp (HasZeroCycleZeroingGP) into zcz-gpr32 and zcz-gpr64; generic enables none, the fields "
     "default false, and copyPhysReg zeroes through ORR in both",
     [aarch64Source("21.1.0", "AArch64Features.td", 630), aarch64Source("22.1.1", "AArch64Features.td", 687),
      aarch64Source("22.1.1", "AArch64Features.td", 690), aarch64Source("21.1.0", "AArch64InstrInfo.cpp", 5192),
      aarch64Source("22.1.1", "AArch64InstrInfo.cpp", 5491), aarch64Source("22.1.1", "AArch64InstrInfo.cpp", 5536)]
     + FIELD_DEFAULT),
)]

# The aarch64 GNU Linux production records the same four disabled features of the same generic cpu
# (checked against the Zig 0.16.0 compile line), and every source above is target independent, so each
# entry holds for it. The list is apart from REMOVED_DISABLED_FEATURES, whose entries each name one
# feature once for the Windows consumers; translateFeatures reads both.
REMOVED_DISABLED_FEATURES_AARCH64_LINUX = [dict(e, target="aarch64-linux-gnu.2.31") for e in REMOVED_DISABLED_FEATURES
                                           if e["target"] == "aarch64-windows-gnu"]

GNU_LINUX = {
    "fixture": "runtimeLinux.c", "zigLinkArgs": ["-lm", "-lpthread"], "linker": "ld.lld",
    "driverFlags": ["-no-pie"],
    "notices": {"zig": ["../LICENSE"], "glibc": ["libc/glibc/LICENSES"]},
}

TARGETS = {
    "wasm32-wasi": {
        "fixture": "runtimeWasi.c", "zigLinkArgs": [], "linker": "wasm-ld", "driverFlags": [],
        "clangTarget": "wasm32-wasip1", "emptyArchives": ["libm.a"],
        "notices": {"zig": ["../LICENSE"], "musl": ["libc/musl/COPYRIGHT"],
                    "wasi-libc": ["libc/wasi/" + n for n in WASI_LICENSES]},
    },
    "x86_64-linux-gnu.2.31": GNU_LINUX,
    "aarch64-linux-gnu.2.31": GNU_LINUX,
}
# What a linked glibc executable of each GNU target must be: ELF machine and the loader it names.
# The loader's soname is `.so.2` on x86_64 and `.so.1` on aarch64, so each target spells its own.
ELF_TARGETS = {
    "x86_64-linux-gnu.2.31": {"machine": 62, "name": "x86_64", "interpreter": "/lib64/ld-linux-x86-64.so.2"},
    "aarch64-linux-gnu.2.31": {"machine": 183, "name": "aarch64", "interpreter": "/lib/ld-linux-aarch64.so.1"},
}


def parseCompileArgv(line):
    """Read the target, cpu, position-independence flags, defines and ordered -isystem
    directories from a `zig clang` line."""
    tokens = line.split()
    found = {"target": None, "cpu": None, "pic": [], "defines": [], "features": [], "isystem": []}
    i = 0
    while i < len(tokens):
        token = tokens[i]
        following = tokens[i + 1] if i + 1 < len(tokens) else None
        if token == "-target" and following:
            found["target"] = following
            i += 1
        elif token == "-isystem" and following:
            found["isystem"].append(following)
            i += 1
        elif tokens[i:i + 4:2] == ["-Xclang", "-Xclang"] and tokens[i + 1:i + 2] == ["-target-cpu"]:
            found["cpu"] = tokens[i + 3]
            i += 3
        elif tokens[i:i + 4:2] == ["-Xclang", "-Xclang"] and tokens[i + 1:i + 2] == ["-target-feature"]:
            found["features"].append(tokens[i + 3])
            i += 3
        elif token in PIC_FLAGS:
            found["pic"].append(token)
        elif token.startswith("-D") and token != "-DNDEBUG":
            found["defines"].append(token)
        i += 1
    for key in ("target", "cpu"):
        if not found[key]:
            raise pe.EngineError("compile line has no %s: %s" % (key, line))
    if not found["isystem"]:
        raise pe.EngineError("compile line has no -isystem: %s" % line)
    return found


def parseLinkArgv(line, output, objectName, cacheRoot):
    """Split a linker line into (linker, items). An item is ("arg", text), ("input", path) for a
    runtime file under cacheRoot, or ("user", None) for the fixture object. `-o OUTPUT` is
    dropped: the clang driver spells it."""
    tokens = line.split()
    items, i = [], 1
    while i < len(tokens):
        token = tokens[i]
        if token == "-o":
            if tokens[i + 1:i + 2] != [output]:
                raise pe.EngineError("link line writes %s, not %s" % (tokens[i + 1:i + 2], output))
            i += 2
        elif token in LINK_VALUED:
            if i + 1 >= len(tokens):
                raise pe.EngineError("link option %s has no value" % token)
            items += [("arg", token), ("arg", tokens[i + 1])]
            i += 2
        elif token.startswith("-"):
            items.append(("arg", token))
            i += 1
        elif os.path.basename(token) == objectName:
            items.append(("user", None))
            i += 1
        else:
            real = os.path.realpath(token)
            if not os.path.isabs(token) or not os.path.isfile(real) or os.path.islink(token):
                raise pe.EngineError("link input %s is not an absolute regular file" % token)
            if os.path.commonpath([cacheRoot, real]) != cacheRoot:
                raise pe.EngineError("link input %s is not from this run's private cache" % token)
            items.append(("input", real))
            i += 1
    if sum(1 for kind, _ in items if kind == "user") != 1:
        raise pe.EngineError("link line names the fixture object %s %d times" % (
            objectName, sum(1 for kind, _ in items if kind == "user")))
    return os.path.basename(tokens[0]), items


def selectLines(stderr, fixture, output):
    """The one compile line of the fixture and the one link line that writes output."""
    compile_, link = [], []
    for line in stderr.splitlines():
        tokens = line.split()
        if tokens[1:3] == ["clang", fixture]:
            compile_.append(line)
        elif "-o" in tokens and output in tokens[tokens.index("-o") + 1:tokens.index("-o") + 2]:
            link.append(line)
    if len(compile_) != 1 or len(link) != 1:
        raise pe.EngineError("expected one compile and one link line, found %d and %d" % (
            len(compile_), len(link)))
    return compile_[0], link[0]


def selectTargets(names):
    chosen = list(names) if names else list(TARGETS)
    for name in chosen:
        if name not in TARGETS:
            raise pe.EngineError("target %s is not supported; allowed: %s" % (name, ", ".join(TARGETS)))
    if len(set(chosen)) != len(chosen):
        raise pe.EngineError("duplicate target in %s" % chosen)
    return chosen


def checkName(name):
    if not SAFE_NAME.match(name) or name in (".", ".."):
        raise pe.EngineError("unsupported file name %r" % name)
    return name


def configLine(tokens):
    for token in tokens:
        if not CONFIG_TOKEN.match(token):
            raise pe.EngineError("config token %r would need quoting" % token)
    return " ".join(tokens)


def renderConfig(target, spec, compile_, items, directories, engineRelative, major):
    """Text of RUNTIME/<target>.cfg. Compile and link both read it; linker arguments travel
    as -Xlinker pairs, which `-c` leaves alone and which stay safe around commas."""
    here = "<CFGDIR>"
    engine = "%s/%s" % (here, engineRelative)
    lines = [configLine(["-target", spec.get("clangTarget") or compile_["target"]]),
             configLine(["-Xclang", "-target-cpu", "-Xclang", compile_["cpu"]])]
    if target in ELF_TARGETS:
        lines.append(configLine(["--sysroot=%s/%s" % (here, target)]))
    lines += [configLine(["-Xclang", "-target-feature", "-Xclang", f]) for f in compile_["features"]]
    if compile_["pic"]:
        lines.append(configLine(compile_["pic"]))
    lines += [configLine([d]) for d in compile_["defines"]]
    lines.append("-nostdinc")
    lines.append(configLine(["-isystem", "%s/lib/clang/%s/include" % (engine, major)]))
    lines += [configLine(["-isystem", "%s/include/libc/%s" % (here, d)]) for d in directories]
    lines += ["-nostdlib"] + [configLine([f]) for f in spec["driverFlags"]]
    lines.append(configLine(["--ld-path=%s/bin/%s" % (engine, spec["linker"])]))
    lines.append(configLine(["-Xlinker", "-L", "-Xlinker", "%s/%s" % (here, target)]))
    for kind, value in items:
        if kind == "arg":
            lines.append(configLine(["-Xlinker", value]))
        elif kind == "input":
            lines.append(configLine(["-Xlinker", "%s/%s/%s" % (here, target, checkName(os.path.basename(value)))]))
    return "\n".join(lines) + "\n"


def translateFeatures(features, target, cpu, zigVersion, engineMajor):
    """Split Zig's recorded CPU features into (features the config carries, removed disabled
    features with their reason). Only an entry of REMOVED_DISABLED_FEATURES matching the whole
    Zig, engine, target and cpu is left out; every other feature is carried and the engine
    must honor it."""
    carried, notCarried = [], []
    for feature in features:
        entry = next((e for e in REMOVED_DISABLED_FEATURES + REMOVED_DISABLED_FEATURES_AARCH64_LINUX
                      if e["feature"] == feature
                      and (e["zig"], e["engineMajor"], e["target"], e["cpu"]) == (
                          zigVersion, engineMajor, target, cpu)), None)
        if entry:
            notCarried.append(entry)
        else:
            carried.append(feature)
    return carried, notCarried


def runZig(zig, target, work):
    """One Zig compile and link of the target's fixture. Returns (stderr, cacheRoot, output)."""
    spec = TARGETS[target]
    private = os.path.join(work, target)
    cache = os.path.join(private, "global")
    output = os.path.join(private, "fixture.out")
    os.makedirs(cache)
    os.makedirs(os.path.join(private, "local"))
    environment = {"PATH": "/usr/bin:/bin", "HOME": private, "TMPDIR": private,
                   "ZIG_GLOBAL_CACHE_DIR": cache, "ZIG_LOCAL_CACHE_DIR": os.path.join(private, "local"),
                   "ZIG_VERBOSE_CC": "1", "ZIG_VERBOSE_LINK": "1"}
    fixture = os.path.join(FIXTURES, spec["fixture"])
    command = [zig, "cc", "-target", target, "-O2", fixture] + spec["zigLinkArgs"] + ["-o", output]
    try:
        done = subprocess.run(command, cwd=private, env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True,
                              timeout=ZIG_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise pe.EngineError("zig timed out after %d s for %s" % (ZIG_TIMEOUT_SECONDS, target))
    if done.returncode != 0:
        raise pe.EngineError("zig failed for %s (%d): %s" % (target, done.returncode, done.stderr.strip()))
    return done.stderr, os.path.realpath(cache), output


def zigIdentity(zig):
    version = pe.run([zig, "version"]).strip()
    return {"version": version, "sha256": pe.sha256File(zig)}


def copyTree(source, destination):
    for directory, dirnames, filenames in os.walk(source):
        for name in dirnames + filenames:
            if os.path.islink(os.path.join(directory, name)):
                raise pe.EngineError("symlink in %s: %s" % (source, name))
    shutil.copytree(source, destination)
    for directory, _, filenames in os.walk(destination):
        for name in filenames:
            os.chmod(os.path.join(directory, name), 0o644)


def copyHeaders(isystem, output, zigLib):
    """Copy the libc include directories in order, skipping Zig's own builtin headers (the
    engine's replace them). Returns (copied names in order, absent names)."""
    if isystem[0] != os.path.join(zigLib, "include"):
        raise pe.EngineError("first include directory %s is not %s/include" % (isystem[0], zigLib))
    root = os.path.join(zigLib, "libc", "include")
    copied, absent = [], []
    for directory in isystem[1:]:
        if os.path.dirname(directory) != root:
            raise pe.EngineError("include directory %s is not directly under %s" % (directory, root))
        name = checkName(os.path.basename(directory))
        if not os.path.isdir(directory):
            absent.append(name)
            continue
        target = os.path.join(output, "include", "libc", name)
        if os.path.exists(target):
            raise pe.EngineError("include directory %s is listed twice" % name)
        copyTree(directory, target)
        copied.append(name)
    return copied, absent


def parseArchive(data):
    """Members of a GNU-format ar archive as [(name, bytes)], without its symbol table."""
    if data[:8] != b"!<arch>\n":
        raise pe.EngineError("not an ar archive")
    members, longNames, offset = [], b"", 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) < 60 or header[58:60] != b"`\n":
            raise pe.EngineError("bad ar member header at %d" % offset)
        name, size = header[:16].decode("ascii").rstrip(), int(header[48:58])
        body = data[offset + 60:offset + 60 + size]
        if len(body) != size:
            raise pe.EngineError("ar member at %d is truncated" % offset)
        offset += 60 + size + size % 2
        if name == "/" or name == "/SYM64/":
            continue
        if name == "//":
            longNames = body
            continue
        if name.startswith("/") and name[1:].isdigit():
            start = int(name[1:])
            name = longNames[start:longNames.index(b"/\n", start)].decode("utf-8")
        elif name.endswith("/"):
            name = name[:-1]
        else:
            raise pe.EngineError("unsupported ar member name %r" % name)
        members.append((name, body))
    return members


def normalizeInput(engine, path):
    """Strip debug info (all symbols from a link-time stub, which keeps its dynamic symbols) and, for an archive, give members plain ordered names: Zig records the
    private cache path of each member and the source paths of its compile in them."""
    strip = os.path.join(engine, "bin", "llvm-strip")
    if SHARED_OBJECT.search(path):
        pe.run([strip, "--strip-all", path])
        return
    if not path.endswith(".a"):
        if path.endswith(".o"):
            pe.run([strip, "--strip-debug", path])
        return
    with open(path, "rb") as f:
        members = parseArchive(f.read())
    scratch = tempfile.mkdtemp(prefix="normalizeInput-", dir=os.path.dirname(path))
    try:
        names = []
        for index, (name, body) in enumerate(members):
            plain = "%04d-%s" % (index, checkName(os.path.basename(name)))
            with open(os.path.join(scratch, plain), "wb") as f:
                f.write(body)
            names.append(plain)
        pe.run([strip, "--strip-debug"] + [os.path.join(scratch, n) for n in names])
        rebuilt = os.path.join(scratch, "rebuilt.a")
        pe.run([os.path.join(engine, "bin", "llvm-ar"), "rcsD", rebuilt] + [os.path.join(scratch, n) for n in names])
        shutil.copyfile(rebuilt, path)
    finally:
        shutil.rmtree(scratch)


def copyInputs(items, output, target, engine):
    """Copy the runtime inputs of the link line into output/<target>/, one file per name."""
    destination = os.path.join(output, target)
    os.makedirs(destination, exist_ok=True)
    records = []
    for kind, value in items:
        if kind != "input":
            continue
        name = checkName(os.path.basename(value))
        copy = os.path.join(destination, name)
        if os.path.exists(copy):
            raise pe.EngineError("%s: two runtime inputs are named %s" % (target, name))
        if not os.path.isfile(value):
            raise pe.EngineError("%s: runtime input %s is missing" % (target, value))
        shutil.copyfile(value, copy)
        os.chmod(copy, 0o644)
        normalizeInput(engine, copy)
        records.append({"name": name, "producedSha256": pe.sha256File(value),
                        "sha256": pe.sha256File(copy), "bytes": os.path.getsize(copy)})
    if not records:
        raise pe.EngineError("%s: the link line has no runtime input" % target)
    return records


def linkLibraryAliases(directory, names):
    """Give each versioned stub `libNAME.so.N` of names the alias `libNAME.so`, a relative symlink
    to the stub beside it, so `-lNAME` finds it. An alias that would land on an existing name,
    or on one that two stubs both claim, is refused. Returns [{"alias", "target"}]."""
    records = []
    for name in names:
        match = VERSIONED_STUB.match(name)
        if not match or match.group(1) in NO_LINKER_NAME:
            continue
        alias = "lib%s.so" % match.group(1)
        if os.path.lexists(os.path.join(directory, alias)):
            raise pe.EngineError("%s: library alias %s for %s collides with an existing file" % (
                directory, alias, name))
        os.symlink(name, os.path.join(directory, alias))
        records.append({"alias": alias, "target": name})
    verifyLibraryAliases(directory, records)
    return records


def verifyLibraryAliases(directory, records):
    """The symlinks of directory are exactly records, each a plain name for a regular file there."""
    found = sorted(n for n in os.listdir(directory) if os.path.islink(os.path.join(directory, n)))
    if found != sorted(r["alias"] for r in records):
        raise pe.EngineError("%s: symlinks %s are not the recorded aliases %s" % (
            directory, found, [r["alias"] for r in records]))
    for record in records:
        path, target = os.path.join(directory, record["alias"]), record["target"]
        if os.readlink(path) != target or os.path.basename(target) != target:
            raise pe.EngineError("%s: alias %s is not a relative link to %s" % (directory, record["alias"], target))
        real = os.path.join(directory, target)
        if os.path.islink(real) or not os.path.isfile(real):
            raise pe.EngineError("%s: alias %s points at %s, which is not a regular file" % (
                directory, record["alias"], target))


def createEmptyArchives(engine, directory, names):
    """Make each of names in directory as an archive with no member, the way a libc sysroot
    answers a library flag it already satisfies. An archive that would land on an existing name
    is refused. Returns [{"name", "sha256", "bytes"}]."""
    records = []
    for name in names:
        path = os.path.join(directory, checkName(name))
        if os.path.lexists(path):
            raise pe.EngineError("%s: empty archive %s collides with an existing file" % (directory, name))
        pe.run([os.path.join(engine, "bin", "llvm-ar"), "--format=gnu", "crs", path])
        os.chmod(path, 0o644)
        records.append({"name": name, "sha256": pe.sha256File(path), "bytes": os.path.getsize(path)})
    verifyEmptyArchives(directory, records)
    return records


def verifyEmptyArchives(directory, records):
    """Each record is a regular file of directory holding exactly an archive header and no
    member, with the recorded hash and size, so it satisfies a -l flag and defines no symbol."""
    for record in records:
        path = os.path.join(directory, record["name"])
        if os.path.islink(path) or not os.path.isfile(path):
            raise pe.EngineError("%s: empty archive %s is not a regular file" % (directory, record["name"]))
        with open(path, "rb") as f:
            data = f.read()
        if data != EMPTY_ARCHIVE or parseArchive(data):
            raise pe.EngineError("%s: %s is not an empty archive (%d bytes)" % (directory, record["name"], len(data)))
        if pe.sha256File(path) != record["sha256"] or len(data) != record["bytes"]:
            raise pe.EngineError("%s: empty archive %s differs from its record" % (directory, record["name"]))


def copyNotices(output, zigLib, spec):
    """Copy the license files named for the target from the Zig tree; a missing one is an error."""
    zigRoot = os.path.dirname(zigLib)
    records = []
    for directory, relatives in sorted(spec["notices"].items()):
        for relative in relatives:
            source = os.path.realpath(os.path.join(zigLib, relative))
            if os.path.commonpath([zigRoot, source]) != zigRoot:
                raise pe.EngineError("notice %s leaves the Zig tree" % relative)
            if not os.path.isfile(source):
                raise pe.EngineError("notice %s is missing from %s" % (relative, zigLib))
            target = os.path.join(output, "notices", directory, os.path.basename(source))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target):
                if pe.sha256File(target) != pe.sha256File(source):
                    raise pe.EngineError("notices/%s/%s has two different sources" % (
                        directory, os.path.basename(source)))
                continue
            shutil.copyfile(source, target)
            records.append("notices/%s/%s" % (directory, os.path.basename(source)))
    return records


def engineMajor(engine):
    host, version, _ = pe.verifyEngine(engine)
    return host, version, version.split(".")[0]


def copyTargetHeaders(isystem, output, zigLib, copied):
    """The libc include directories of a target not yet in output (the glibc targets share
    `generic-glibc` and `any-linux-any`); a name already copied must be the same Zig directory.
    Returns (the directory names this target's config lists in order, the names absent in Zig)."""
    fresh = [d for d in isystem[1:] if os.path.basename(d) not in copied]
    for d in isystem[1:]:
        if copied.get(os.path.basename(d), d) != d:
            raise pe.EngineError("include directory %s is also %s" % (d, copied[os.path.basename(d)]))
    new, _ = copyHeaders([isystem[0]] + fresh, output, zigLib)
    copied.update({os.path.basename(d): d for d in fresh if os.path.basename(d) in new})
    names = [os.path.basename(d) for d in isystem[1:]]
    return [n for n in names if n in copied], [n for n in names if n not in copied]


def produceTarget(zig, zigVersion, engine, target, work, output, engineRelative, major, copied):
    spec = TARGETS[target]
    stderr, cacheRoot, out = runZig(zig, target, work)
    fixture = os.path.join(FIXTURES, spec["fixture"])
    compileLine, linkLine = selectLines(stderr, fixture, out)
    compile_ = parseCompileArgv(compileLine)
    objectName = os.path.splitext(spec["fixture"])[0] + ".o"
    linker, items = parseLinkArgv(linkLine, out, objectName, cacheRoot)
    if linker != spec["linker"]:
        raise pe.EngineError("%s linked with %s, expected %s" % (target, linker, spec["linker"]))
    zigLib = os.path.dirname(compile_["isystem"][0])
    if re.search(r"\s", zigLib):
        raise pe.EngineError("Zig lib directory %s has whitespace" % zigLib)
    directories, absent = copyTargetHeaders(compile_["isystem"], output, zigLib, copied)
    inputs = copyInputs(items, output, target, engine)
    aliases = linkLibraryAliases(os.path.join(output, target), [i["name"] for i in inputs])
    emptyArchives = createEmptyArchives(engine, os.path.join(output, target), spec.get("emptyArchives", []))
    notices = copyNotices(output, zigLib, spec)
    carried, notCarried = translateFeatures(compile_["features"], target, compile_["cpu"], zigVersion, major)
    pe.writeText(os.path.join(output, target + ".cfg"),
                 renderConfig(target, spec, dict(compile_, features=carried), items, directories,
                              engineRelative, major))
    return {
        "target": target, "zigTarget": compile_["target"],
        "clangTarget": spec.get("clangTarget") or compile_["target"], "cpu": compile_["cpu"],
        "cpuFeatures": compile_["features"], "cpuFeaturesNotCarried": notCarried,
        "positionIndependence": compile_["pic"],
        "defines": compile_["defines"], "linker": linker,
        "linkArgs": [value if kind == "arg" else "$RT/%s/%s" % (target, os.path.basename(value))
                     if kind == "input" else "$OBJECT" for kind, value in items],
        "includeDirectories": directories, "includeDirectoriesAbsentInZig": absent,
        "inputs": inputs, "libraryAliases": aliases, "emptyArchives": emptyArchives,
        "notices": notices,
        "zigFlagsNotCarried": "debug info, -O level, -DNDEBUG, frame pointer and unwind flags",
        "inputsNormalized": "debug sections stripped, stub symbol tables stripped; archive members renamed NNNN-name and the archive rebuilt deterministically",
    }


def writeProvenance(output, zigId, host, engineVersion, engineRelative, records):
    receipt = {
        "kind": "local-zig-runtime-proof",
        "statement": "Produced by running a locally installed Zig once per target on a fixture. "
                     "Not an upstream-controlled build and not bit-reproducible by this tool.",
        "redistributionCertified": False,
        "zig": zigId, "producerHost": host, "engineVersion": engineVersion,
        "engineRelative": engineRelative, "targets": records,
        "noticeGaps": ["no license file ships in the Zig tree for libc/include/any-linux-any "
                       "(Linux uapi headers) or the glibc stub inputs beyond libc/glibc/LICENSES"],
    }
    os.makedirs(os.path.join(output, "notices"), exist_ok=True)
    pe.writeText(os.path.join(output, "notices", "runtime-provenance.json"),
                 json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def checkEngineRelative(engineRelative):
    """The engine path as seen from the runtime directory: one or more leading `..`, then plain
    names (`../engine`, or `..` alone for an engine root holding the runtime as a child). The
    engine is never inside the runtime. Returns the number of `..`."""
    parts = engineRelative.split("/")
    ups = 0
    while ups < len(parts) and parts[ups] == "..":
        ups += 1
    if ups == 0 or not all(SAFE_NAME.match(p) and p not in (".", "..") for p in parts[ups:]):
        raise pe.EngineError("--engine-relative %r must be a plain relative path of `..` steps then names" % engineRelative)
    return ups


def renameNoReplace(source, destination):
    """Move source to destination atomically, failing when destination exists even if empty."""
    libc = ctypes.CDLL(None, use_errno=True)
    paths = (os.fsencode(source), os.fsencode(destination))
    if sys.platform == "darwin":
        result = libc.renamex_np(paths[0], paths[1], 0x4)
    elif sys.platform.startswith("linux"):
        result = libc.renameat2(-100, paths[0], -100, paths[1], 1)
    else:
        raise pe.EngineError("no atomic no-replace rename is known for %s" % sys.platform)
    if result != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise pe.EngineError("output %s exists; it is never replaced" % destination)
        raise OSError(code, os.strerror(code), destination)


def prepareRuntime(zig, engine, output, targets, engineRelative="../engine"):
    zig, engine, output = (os.path.abspath(p) for p in (zig, engine, output))
    targets = selectTargets(targets)
    checkEngineRelative(engineRelative)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    if not os.access(zig, os.X_OK):
        raise pe.EngineError("--zig %s is not executable" % zig)
    host, version, major = engineMajor(engine)
    zigId = zigIdentity(zig)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    work = tempfile.mkdtemp(prefix="prepareRuntime-")
    try:
        copied = {}
        records = [produceTarget(zig, zigId["version"], engine, t, work, partial, engineRelative, major, copied)
                   for t in targets]
        verifyConfigs(engine, partial, engineRelative, records, work)
        writeProvenance(partial, zigId, host, version, engineRelative, records)
        os.chmod(partial, 0o755)
        renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return output, records


def checkConfig(run, clang, config, target, work, absentMacroPrefixes, libraries=()):
    """Compile and link the target's fixture through the config, then link it again with
    -l<name> for each of libraries. Any nonzero exit or any stderr (an unhonored CPU feature
    warns) is an error. Returns the linked binary."""
    fixture = os.path.join(FIXTURES, TARGETS[target]["fixture"])
    obj, binary = os.path.join(work, target + ".o"), os.path.join(work, target + ".bin")
    steps = [("compile", [clang] + config + ["-O2", "-c", fixture, "-o", obj]),
             ("link", [clang] + config + [obj, "-o", binary]),
             ("library search", [clang] + config + [obj] + ["-l" + n for n in libraries]
              + ["-o", binary + ".search"]) if libraries else None,
             ("macros", [clang] + config + ["-dM", "-E", "-x", "c", "/dev/null"])]
    for name, command in filter(None, steps):
        done = run(command)
        if done.returncode != 0:
            raise pe.EngineError("%s %s failed: %s" % (target, name, done.stderr.strip()))
        if done.stderr.strip():
            raise pe.EngineError("%s %s warned: %s" % (target, name, done.stderr.strip()))
    present = [prefix for prefix in absentMacroPrefixes if "#define " + prefix in done.stdout]
    if present:
        raise pe.EngineError("%s config defines %s macros" % (target, present))
    return binary


def linkEngineBeside(engine, directory, runtime):
    """engineRelative names an existing ancestor of the copied runtime (the engine root holds
    the runtime as a child): every engine entry becomes a symlink in that ancestor, and an entry
    that would land on an existing name is refused."""
    if os.path.islink(directory) or directory == runtime or not pe.containsPath(directory, runtime):
        raise pe.EngineError("engine path %s collides with the runtime copy" % directory)
    for name in sorted(os.listdir(engine)):
        entry = os.path.join(directory, name)
        if os.path.lexists(entry):
            raise pe.EngineError("engine entry %s collides with %s" % (name, entry))
        os.symlink(os.path.join(engine, name), entry)


def verifyConfigs(engine, runtime, engineRelative, records, work):
    """Run checkConfig for each produced target on a copy of the runtime whose engine path
    resolves as the config says."""
    depth = checkEngineRelative(engineRelative)
    copy = os.path.join(work, "verify", *(["up"] * depth), "runtime")
    shutil.copytree(runtime, copy, symlinks=True)
    link = os.path.normpath(os.path.join(copy, engineRelative))
    if os.path.lexists(link):
        linkEngineBeside(engine, link, copy)
    else:
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(engine, link)
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    run = lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, universal_newlines=True)
    for record in records:
        prefixes = [e["absentMacroPrefix"] for e in record["cpuFeaturesNotCarried"] if e["absentMacroPrefix"]]
        checkConfig(run, os.path.join(link, "bin", "clang"),
                    ["--config", os.path.join(copy, record["target"] + ".cfg")],
                    record["target"], work, prefixes,
                    libraryNames(record["libraryAliases"], record["emptyArchives"]))


def libraryNames(aliases, archives=()):
    """The -l names that reach the aliases and the empty archives: `libm.so` and `libm.a` are `-lm`."""
    return [a["alias"][len("lib"):-len(".so")] for a in aliases] + [
        a["name"][len("lib"):-len(".a")] for a in archives]


def sandboxed(profile, work, command):
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    return subprocess.run(["/usr/bin/sandbox-exec", "-f", profile] + command, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)


def elfProblem(path, target="x86_64-linux-gnu.2.31"):
    expected = ELF_TARGETS[target]
    with open(path, "rb") as f:
        head = f.read(20)
    machine = int.from_bytes(head[18:20], "little")
    if head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1 or machine != expected["machine"]:
        return "not an %s ELF64 file" % expected["name"]
    return None


def elfInterpreterProblem(path, target):
    """The ELF's PT_INTERP is exactly the loader of target, a single NUL-terminated path."""
    expected = ELF_TARGETS[target]["interpreter"]
    with open(path, "rb") as f:
        data = f.read()
    offset, size, count = (int.from_bytes(data[a:a + n], "little") for a, n in ((32, 8), (54, 2), (56, 2)))
    found = []
    for i in range(count):
        header = offset + i * size
        if int.from_bytes(data[header:header + 4], "little") == 3:
            start, length = (int.from_bytes(data[header + a:header + a + 8], "little") for a in (8, 32))
            found.append(data[start:start + length])
    if found != [expected.encode("ascii") + b"\0"]:
        return "interpreter is %s, not %s" % ([f.rstrip(b"\0").decode("ascii", "replace") for f in found], expected)
    return None


def glibcSymbolProblem(nm, path, limit=(2, 31), requiredSymbol="printf"):
    needed = [l.split()[-1] for l in pe.run([nm, "-D", path]).splitlines() if "@GLIBC_" in l]
    versions = [tuple(int(n) for n in re.search(r"@GLIBC_([\d.]+)", s).group(1).split(".")) for s in needed]
    if not any(s.startswith(requiredSymbol + "@") for s in needed):
        return "no versioned %s in %s" % (requiredSymbol, needed)
    if any(v > limit for v in versions):
        return "needs a glibc newer than %s: %s" % (limit, needed)
    return None


def prove(engine, runtime, denied, zig=None, targets=None):
    """Relocate engine and runtime where the receipt's engineRelative puts them and run the
    fixtures through `clang --config` under a sandbox that cannot read the originals, Zig or any
    --deny path. A runtime that is a child of the engine root travels inside the engine copy."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    pe.verifyEngine(engine)
    targets = selectTargets(targets)
    with open(os.path.join(runtime, "notices", "runtime-provenance.json")) as f:
        receipt = json.load(f)
    depth = checkEngineRelative(receipt["engineRelative"])
    work = os.path.realpath(tempfile.mkdtemp(prefix="runtime-proof-"))
    root = os.path.join(work, "relocated tree")
    movedRuntime = os.path.join(root, *(["inner"] * (depth - 1)), "runtime")
    movedEngine = os.path.normpath(os.path.join(movedRuntime, receipt["engineRelative"]))
    embedded = engine != runtime and pe.containsPath(engine, runtime)
    if embedded and movedRuntime != os.path.join(movedEngine, os.path.relpath(runtime, engine)):
        raise pe.EngineError("runtime sits inside the engine at %s, not where engineRelative %s puts it" % (
            os.path.relpath(runtime, engine), receipt["engineRelative"]))
    shutil.copytree(engine, movedEngine, symlinks=True)
    if not embedded:
        if os.path.lexists(movedRuntime):
            raise pe.EngineError("engine entry collides with the runtime at %s" % movedRuntime)
        shutil.copytree(runtime, movedRuntime, symlinks=True)
    secrets = ([engine] if embedded else [engine, runtime]) + [os.path.realpath(p) for p in denied]
    if zig:
        secrets.append(os.path.dirname(os.path.realpath(zig)))
    profile = os.path.join(work, "deny.sb")
    pe.writeText(profile, "(version 1)(allow default)" + "".join(
        '(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (p, p) for p in secrets) + "\n")
    control = sandboxed(profile, work, [os.path.join(engine, "bin", "clang"), "--version"])
    if control.returncode == 0:
        raise pe.EngineError("sandbox does not deny the original engine")
    if zig and sandboxed(profile, work, [os.path.realpath(zig), "version"]).returncode == 0:
        raise pe.EngineError("sandbox does not deny Zig")

    clang, nm = os.path.join(movedEngine, "bin", "clang"), os.path.join(movedEngine, "bin", "llvm-nm")
    for target in targets:
        config = ["--config", os.path.join(movedRuntime, target + ".cfg")]
        recorded = next(r for r in receipt["targets"] if r["target"] == target)
        if "libraryAliases" not in recorded:
            raise pe.EngineError("%s receipt records no libraryAliases; prepare the runtime again" % target)
        prefixes = [e["absentMacroPrefix"] for e in recorded["cpuFeaturesNotCarried"] if e["absentMacroPrefix"]]
        if "emptyArchives" not in recorded:
            raise pe.EngineError("%s receipt records no emptyArchives; prepare the runtime again" % target)
        verifyLibraryAliases(os.path.join(movedRuntime, target), recorded["libraryAliases"])
        verifyEmptyArchives(os.path.join(movedRuntime, target), recorded["emptyArchives"])
        libraries = libraryNames(recorded["libraryAliases"], recorded["emptyArchives"])
        binary = checkConfig(lambda command: sandboxed(profile, work, command), clang, config, target,
                             work, prefixes, libraries)
        with open(binary, "rb") as f:
            data = f.read()
        leaked = [p for p in secrets if p.encode("utf-8") in data]
        if leaked:
            raise pe.EngineError("%s output holds source paths %s" % (target, leaked))
        if target == "wasm32-wasi":
            wasmtime = shutil.which("wasmtime")
            if not wasmtime:
                raise pe.EngineError("wasmtime not found; the wasm32-wasi run is not proven")
            for program in [binary] + ([binary + ".search"] if libraries else []):
                ran = subprocess.run([wasmtime, program], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     universal_newlines=True)
                if ran.returncode != 0 or ran.stdout != EXPECTED_OUTPUT:
                    raise pe.EngineError("%s run of %s: %r %r" % (target, os.path.basename(program),
                                                                  ran.stdout, ran.stderr))
            print("%s: linked and ran (also with -l%s): %s" % (target, " -l".join(libraries), EXPECTED_OUTPUT.strip()))
        else:
            problem = elfProblem(binary, target) or elfInterpreterProblem(binary, target) or glibcSymbolProblem(nm, binary)
            if problem:
                raise pe.EngineError("%s: %s" % (target, problem))
            print("%s: linked, ELF and glibc symbol versions checked; not run (host is not Linux)" % target)
    print("relocated=%s denied=%d zig=%s" % (root, len(secrets), "denied" if zig else "not given"))
    shutil.rmtree(work)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zig")
    parser.add_argument("--engine", required=True)
    parser.add_argument("--output")
    parser.add_argument("--runtime")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--engine-relative", default="../engine")
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--prove", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.prove:
            if not args.runtime:
                parser.error("--prove needs --runtime")
            prove(args.engine, args.runtime, args.deny, args.zig, args.target)
        else:
            if not (args.zig and args.output):
                parser.error("--zig and --output are required")
            output, records = prepareRuntime(args.zig, args.engine, args.output, args.target,
                                             args.engine_relative)
            for record in records:
                print("%s: %d inputs, %d include directories" % (
                    record["target"], len(record["inputs"]), len(record["includeDirectories"])))
            print("runtime written to %s" % output)
    except pe.EngineError as error:
        print("prepareRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
