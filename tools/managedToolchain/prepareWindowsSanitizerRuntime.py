#!/usr/bin/env python3
"""Prepare the compiler-rt sanitizer files of x86_64-windows-gnu and aarch64-windows-gnu from LLVM sources on top of the source-built C runtime and its static C++ runtime. These are SOURCE ASSETS: nothing here links or runs a program with a bare -fsanitize flag.

    prepareWindowsSanitizerRuntime.py --engine ENGINE_DIR --runtime RUNTIME_DIR --output NEW_OVERLAY_DIR
        --llvm-project DIR [--llvm-project-rev SHA] [--target T ...] [--make MAKE] [--cmake CMAKE] [--ninja NINJA]
        [--python3 PYTHON] [--jobs N]
    installResource(RUNTIME_DIR, ENGINE_DIR/lib/clang/MAJOR)    from a bundle assembly, see below

RUNTIME_DIR holds the `windows/` that prepareWindowsSourceRuntime.py made with the overlay of
prepareWindowsSourceCppRuntime.py merged in, and is only read. NEW_OVERLAY_DIR receives new paths, each relative to
RUNTIME_DIR, which prepareCppRuntime.mergeOverlay merges without replacing a file:

    windows-sanitizers/resource/lib/windows/<archive>   the archives the driver reads from the resource directory
    windows/x86_64-windows-gnu/bin/libclang_rt.asan_dynamic-x86_64.dll    the ASan runtime, a standalone asset
    notices/windows-sanitizer-provenance.json, notices/windows-sanitizer/compiler-rt/LICENSE.TXT

    x86_64   libclang_rt.ubsan_standalone-x86_64.a, libclang_rt.ubsan_standalone_cxx-x86_64.a,
             libclang_rt.asan_dynamic-x86_64.dll.a, libclang_rt.asan_dynamic_runtime_thunk-x86_64.a and the DLL
    aarch64  the two UBSan archives; Windows ASan is x86_64 only, so any ASan file of aarch64 is refused

The DLL is no resource file and is never installed next to the compiler: it keeps the name its import library embeds
and sits in the target's bin directory for a test to copy beside a program. installResource(runtime, resourceRoot)
installs the archives of the receipt into the lib/clang/<major> directory of the engine that will link with them,
after checking every file against the receipt and against its own bytes, and refuses a file already there with other
contents and an archive at lib/<target triple>, which the driver reads before lib/windows.

For each target, in a private work directory and out of tree, the monorepo's compiler-rt directory is configured with
its own standalone fallback (no LLVM package: the llvm/cmake/modules of the checkout stand in for LLVMConfig, and
CMAKE_DISABLE_FIND_PACKAGE_LLVM keeps a host LLVM from being found), the staged engine clang driven by the target's
configs, the builtins of the C runtime, the sanitizer component asan and no other runtime component, built and
installed into a private prefix. A copy of the engine with the C runtime's builtins installed is the temporary SDK.
C sources and the CMake probes of C libraries see the C config and the C++ payload directory; C++ sources see the C++
config first and the C config after it, which is the order the C++ cohort is proven with.

Fail loud: an unpinned or dirty checkout, an engine, runtime or checkout that changed, a runtime that is not the
source C runtime with its C++ overlay of the same LLVM commit and version for every target, a target without
libsynchronization.a (the sanitizer runtime's own `synchronization.lib` default library), a configure that found an
LLVM package or no libc++, a prefix with an entry outside the allowlist or without a required one (an extra DLL of
UBSan, any ASan file of aarch64), an archive that is empty, import-only or has a member of another machine, an archive
without the symbols its role needs, an import library whose members do not all name the DLL, hold no import
descriptor or export what the DLL does not, a DLL that is not an x64 PE importing system DLLs, the UCRT and api sets
alone, an installed sanitizer header that differs from the engine's, a path the runtime already has, and a link or
reparse point anywhere under a staged path.

The files the install holds and the receipt does not carry (the stats and loop-detect archives, the sanitizer headers
and ignorelists) are recorded with their hashes; they are not required runtime, and a header the engine lacks is
listed as missing, never counted as API coverage. The assets are a local proof from pinned upstream sources; the
receipt says so and never certifies redistribution.
"""
import argparse
import json
import os
import re
import shutil
import struct
import sys
import tempfile

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws

RECEIPT_KIND = "source-built-windows-sanitizer-assets"
PROVENANCE = "notices/windows-sanitizer-provenance.json"
NOTICE_ROOT = "notices/windows-sanitizer"
NOTICE = NOTICE_ROOT + "/compiler-rt/LICENSE.TXT"
RESOURCE_ROOT = "windows-sanitizers/resource"
RESOURCE_LIBRARY = "lib/windows"
BASE_PROVENANCE = pwc.BASE_PROVENANCE
CPP_PROVENANCE = pwc.PROVENANCE
PROOFS = "none: no bare -fsanitize flag has been linked or run with these assets"
SYNCHRONIZATION = "libsynchronization.a"
LLVM_MARKERS = ("cmake/Modules/LLVMVersion.cmake", "llvm/cmake/modules/AddLLVM.cmake", "compiler-rt/CMakeLists.txt",
                "compiler-rt/cmake/Modules/CompilerRTMockLLVMCMakeConfig.cmake",
                "compiler-rt/lib/asan/CMakeLists.txt", "compiler-rt/lib/ubsan/CMakeLists.txt",
                "compiler-rt/LICENSE.TXT")
SOURCE_SUBDIRECTORY = "compiler-rt"
FIXED_DEFINITIONS = {
    "CMAKE_BUILD_TYPE": "Release", "CMAKE_SYSTEM_NAME": "Windows",
    "CMAKE_C_COMPILER_WORKS": "TRUE", "CMAKE_CXX_COMPILER_WORKS": "TRUE", "CMAKE_ASM_COMPILER_WORKS": "TRUE",
    "CMAKE_DISABLE_FIND_PACKAGE_LLVM": "TRUE", "LLVM_CONFIG_PATH": "",
    "COMPILER_RT_BUILD_BUILTINS": "OFF", "COMPILER_RT_BUILD_SANITIZERS": "ON", "COMPILER_RT_BUILD_XRAY": "OFF",
    "COMPILER_RT_BUILD_LIBFUZZER": "OFF", "COMPILER_RT_BUILD_PROFILE": "OFF", "COMPILER_RT_BUILD_CTX_PROFILE": "OFF",
    "COMPILER_RT_BUILD_MEMPROF": "OFF", "COMPILER_RT_BUILD_ORC": "OFF", "COMPILER_RT_BUILD_GWP_ASAN": "OFF",
    "COMPILER_RT_INCLUDE_TESTS": "OFF", "COMPILER_RT_USE_BUILTINS_LIBRARY": "ON",
    "COMPILER_RT_DEFAULT_TARGET_ONLY": "ON", "COMPILER_RT_SANITIZERS_TO_BUILD": "asan", "SANITIZER_CXX_ABI": "libc++",
}
MOCK_MESSAGE = "Attempting to mock the changes made by LLVMConfig.cmake"
CACHE_PROBE = re.compile(r"^COMPILER_RT_HAS_LIBCXX:INTERNAL=(.*)$", re.M)
CACHE_LLVM_DIR = re.compile(r"^LLVM_DIR:[A-Z]+=(.*)$", re.M)
ASAN_DLL_NAME = "libclang_rt.asan_dynamic-%s.dll"
DLL_MARKERS = ["__asan_should_detect_stack_use_after_return", "__asan_get_shadow_memory_dynamic_address",
               "__asan_report_load1"]
UBSAN_MARKERS = ["__ubsan_handle_add_overflow", "__ubsan_handle_type_mismatch_v1"]
UBSAN_CXX_MARKERS = ["__ubsan_handle_dynamic_type_cache_miss"]
THUNK_MARKERS = ["__asan_seh_interceptor"]
DLL_ONLY_SYMBOLS = DLL_MARKERS[:2]
NOT_CARRIED_LIBRARIES = ["libclang_rt.ubsan_loop_detect-%s.a", "libclang_rt.stats-%s.a",
                         "libclang_rt.stats_client-%s.a"]
SANITIZER_HEADER = re.compile(r"^include/sanitizer/[A-Za-z0-9_.+-]+\.h$")
IGNORELIST = re.compile(r"^share/[A-Za-z0-9_.+-]*ignorelist\.txt$")
BIGOBJ_CLASS_ID = bytes([0xc7, 0xa1, 0xba, 0xd1, 0xee, 0xba, 0xa9, 0x4b, 0xaf, 0x20, 0xfa, 0xf6, 0x6a, 0xa4, 0xdc, 0xb8])
BIGOBJ_HEADER_BYTES = 56
IMPORT_HEADER_BYTES = 20
DESCRIPTOR_PREFIX = b"__IMPORT_DESCRIPTOR_"
NULL_THUNK = (b"\x7f", b"_NULL_THUNK_DATA")
UNWANTED_IMPORT_STEMS = ("libc++", "libunwind", "libwinpthread", "msvcrt")
LIMITS = ["source assets only: no bare -fsanitize flag, no vptr check and no combined address,undefined link was "
          "compiled, linked or run with them; the ASan DLL was linked by the build and is inspected, never loaded",
          "Windows ASan is x86_64 only: the aarch64 assets are the two UBSan archives and nothing else",
          "the UBSan runtime is static only: a UBSan DLL is not part of the allowlist and is refused if the build "
          "makes one",
          "the DLL is a standalone asset: it is not in the resource tree and no compiler config, PATH or bundle "
          "layout reaches it",
          "no archive is normalized: the files are as the build and llvm-ar wrote them",
          "the stats, stats_client and ubsan_loop_detect archives, the sanitizer headers and the ignorelists the "
          "install makes are recorded, not carried",
          "no pthread, external or C11 thread API and no psapi import library is involved: the C runtime's Windows 10 "
          "headers select PSAPI_VERSION 2"]


def architecture(target):
    return pws.SOURCE_TARGETS[target]["builtins"]


def assetSpecs(target):
    """The files a runtime of target carries, in receipt order: {"name", "role", "symbols", "shadow"}. The shadow is the
    file name the driver reads first from lib/<target triple> when it exists."""
    arch = architecture(target)
    specs = [{"name": "libclang_rt.ubsan_standalone-%s.a" % arch, "role": "ubsan", "symbols": UBSAN_MARKERS,
              "shadow": "libclang_rt.ubsan_standalone.a"},
             {"name": "libclang_rt.ubsan_standalone_cxx-%s.a" % arch, "role": "ubsan-cxx", "symbols": UBSAN_CXX_MARKERS,
              "shadow": "libclang_rt.ubsan_standalone_cxx.a"}]
    if target == pw.TARGET:
        specs += [{"name": "libclang_rt.asan_dynamic-%s.dll.a" % arch, "role": "asan-import", "symbols": DLL_MARKERS,
                   "shadow": "libclang_rt.asan_dynamic.dll.a"},
                  {"name": "libclang_rt.asan_dynamic_runtime_thunk-%s.a" % arch, "role": "asan-thunk",
                   "symbols": THUNK_MARKERS, "shadow": "libclang_rt.asan_dynamic_runtime_thunk.a"},
                  {"name": ASAN_DLL_NAME % arch, "role": "asan-dll", "symbols": DLL_MARKERS, "shadow": None}]
    return specs


def resourcePath(name):
    return RESOURCE_LIBRARY + "/" + name


def overlayPath(target, spec):
    """The path of an asset of target relative to the runtime: the DLL in the target's bin directory, every archive in
    the resource tree."""
    if spec["role"] == "asan-dll":
        return "windows/%s/bin/%s" % (target, spec["name"])
    return RESOURCE_ROOT + "/" + resourcePath(spec["name"])


def ownedRoots(targets):
    """The runtime-relative directories a receipt of targets owns."""
    return [RESOURCE_ROOT, NOTICE_ROOT] + ["windows/%s/bin" % t for t in targets if t == pw.TARGET]


def collisionProblem(runtime, targets):
    """Why runtime already holds a path of this asset set, or None. A runtime carries one set and nothing is replaced."""
    taken = [p for p in ownedRoots(targets) + [PROVENANCE] if os.path.lexists(os.path.join(runtime, *p.split("/")))]
    if taken:
        return "%s already has %s: a runtime carries one sanitizer asset set and nothing is replaced" % (
            runtime, ", ".join(taken))
    return None


def inputReceipts(runtime, targets, version, major, llvmRev):
    """((C receipt, sha256), (C++ receipt, sha256)) once both describe the files of runtime for every target and were
    built from the one llvm-project commit, version and major the engine has; anything else is refused."""
    base = pwc.baseReceipt(runtime, targets)
    cpp, digest = pwc.readJson(runtime, CPP_PROVENANCE)
    problem = pwc.receiptProblem(cpp, runtime)
    if problem:
        raise pe.EngineError(problem)
    absent = [t for t in targets if t not in cpp["targets"]]
    if absent:
        raise pe.EngineError("the C++ runtime has no %s" % ", ".join(absent))
    for what, receipt in (("C", base[0]), ("C++", cpp)):
        recorded = receipt["sources"]["llvm-project"]
        found = (recorded.get("rev"), recorded.get("version"), recorded.get("major"))
        if found != (llvmRev, version, major):
            raise pe.EngineError("the %s runtime was built from llvm-project %s (LLVM %s, major %s), not %s (LLVM %s, "
                                 "major %s)" % ((what,) + found + (llvmRev, version, major)))
    return base, (cpp, digest)


def synchronizationProblem(runtime, targets):
    """Why a variant directory of a target lacks the libsynchronization.a the sanitizer runtime asks for, or None. The
    C runtime's own make builds and installs it; none is made or aliased here."""
    for target in targets:
        for variant in pws.SOURCE_VARIANTS:
            relative = "windows/%s/%s" % (pws.variantDirectory(target, variant), SYNCHRONIZATION)
            linked = pws.linkedComponent(runtime, relative)
            if linked:
                return "%s is a link" % linked
            path = os.path.join(runtime, *relative.split("/"))
            if not os.path.isfile(path):
                return "%s lacks %s: the C runtime does not carry what the sanitizer runtime links" % (
                    pws.variantDirectory(target, variant), SYNCHRONIZATION)
            problem = anyArchiveProblem(path, pw.TARGETS[target]["machine"])
            if problem:
                return problem
    return None


def toolFlags(stage, target):
    """(C flags, C++ flags) for the CMake init variables: C sees the C config and the payload directory through
    -Xlinker, which a compile leaves alone; C++ sees the C++ config first and the C config after it."""
    windows = os.path.join(stage, "runtime", "windows")
    base = os.path.join(windows, pws.variantConfig(target, "exe"))
    cxx = os.path.join(windows, os.path.basename(pwc.configPath(target, "exe")))
    payload = os.path.join(windows, os.path.basename(pwc.payloadDirectory(target)))
    return (["--no-default-config", "--config=" + base, "-Xlinker", "-L", "-Xlinker", payload],
            ["--no-default-config", "--config=" + cxx, "--config=" + base])


def sanitizerDefinitions(stage, target, prefix, python):
    """The -D definitions of the compiler-rt configure of target: the fixed ones, the staged engine's tools and the
    config flags of each language."""
    triple = pws.SOURCE_TARGETS[target]["clangTarget"]
    clang = pws.engineTool(stage, "clang")
    cFlags, cxxFlags = toolFlags(stage, target)
    definitions = dict(FIXED_DEFINITIONS)
    definitions.update({
        "CMAKE_INSTALL_PREFIX": prefix, "CMAKE_C_COMPILER": clang, "CMAKE_CXX_COMPILER": pws.engineTool(stage, "clang++"),
        "CMAKE_ASM_COMPILER": clang, "CMAKE_AR": pws.engineTool(stage, "llvm-ar"),
        "CMAKE_RANLIB": pws.engineTool(stage, "llvm-ranlib"), "CMAKE_C_COMPILER_TARGET": triple,
        "CMAKE_CXX_COMPILER_TARGET": triple, "CMAKE_ASM_COMPILER_TARGET": triple,
        "CMAKE_C_FLAGS_INIT": " ".join(cFlags), "CMAKE_CXX_FLAGS_INIT": " ".join(cxxFlags),
        "CMAKE_ASM_FLAGS_INIT": " ".join(cFlags), "Python3_EXECUTABLE": python})
    return definitions


def sanitizerCommand(llvm, stage, target, build, prefix, tools, python):
    """The configure command: the monorepo's compiler-rt directory as the source, so its standalone fallback applies."""
    command = [tools["cmake"], "-S", os.path.join(llvm, *SOURCE_SUBDIRECTORY.split("/")), "-B", build]
    if "ninja" in tools:
        command += ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + tools["ninja"]]
    else:
        command += ["-G", "Unix Makefiles"]
    definitions = sanitizerDefinitions(stage, target, prefix, python)
    return command + ["-D%s=%s" % (name, definitions[name]) for name in sorted(definitions)]


def configureProblem(cache, log, llvm):
    """Why a configure log and CMakeCache.txt show a build that did not use the checkout's own fallback with libc++
    found, or None: the mock message, the checkout's llvm directory as LLVM_MAIN_SRC_DIR, no LLVM_DIR found, and a
    libc++ probe that passed."""
    if MOCK_MESSAGE not in log:
        return "the configure did not take compiler-rt's own LLVM fallback (no %r in its output)" % MOCK_MESSAGE
    wanted = 'LLVM_MAIN_SRC_DIR: "%s"' % os.path.join(llvm, "llvm")
    if wanted not in log:
        return "the configure did not name %s" % wanted
    found = CACHE_LLVM_DIR.search(cache)
    if found and not found.group(1).endswith("-NOTFOUND"):
        return "the configure found an LLVM package at %s" % found.group(1)
    probe = CACHE_PROBE.search(cache)
    if not probe or probe.group(1) not in ("1", "TRUE", "ON", "YES"):
        return "the libc++ probe COMPILER_RT_HAS_LIBCXX is %r, not true" % (probe.group(1) if probe else None)
    return None


def buildSanitizers(llvm, stage, target, work, tools, python, environment, jobs):
    """Configure, build and install compiler-rt's sanitizer runtimes of target into a private prefix, never into the
    engine. Returns the prefix."""
    build, prefix = os.path.join(work, target + "-san-build"), os.path.join(work, target + "-san")
    configureLog = os.path.join(work, target + "-san-configure.log")
    pws.runBuild(sanitizerCommand(llvm, stage, target, build, prefix, tools, python), work, environment, configureLog)
    with open(os.path.join(build, "CMakeCache.txt"), encoding="utf-8", errors="replace") as f, \
            open(configureLog, encoding="utf-8", errors="replace") as g:
        problem = configureProblem(f.read(), g.read(), llvm)
    if problem:
        raise pe.EngineError("%s: %s" % (target, problem))
    pws.runBuild([tools["cmake"], "--build", build, "-j", str(jobs)], work, environment,
                 os.path.join(work, target + "-san-build.log"))
    pws.runBuild([tools["cmake"], "--install", build, "--prefix", prefix], work, environment,
                 os.path.join(work, target + "-san-install.log"))
    if not os.path.isdir(prefix):
        raise pe.EngineError("the sanitizer install made no %s" % prefix)
    return prefix


def installFiles(prefix):
    """Sorted `/`-separated paths of every file under prefix. A prefix that is not a directory, a link or reparse point
    anywhere under it, a file that is not regular and a name outside the safe ones are errors; nothing is opened."""
    if not os.path.isdir(prefix) or pe.isLinkLike(prefix):
        raise pe.EngineError("%s is not a directory" % prefix)
    found = []
    for directory, directories, names in os.walk(prefix):
        for name in directories + names:
            path = os.path.join(directory, name)
            if pe.isLinkLike(path):
                raise pe.EngineError("%s is a link" % path)
            if not pr.SAFE_NAME.match(name) or name in (".", ".."):
                raise pe.EngineError("%s holds the unsupported name %r" % (prefix, name))
        for name in names:
            if not os.path.isfile(os.path.join(directory, name)):
                raise pe.EngineError("%s is not a regular file" % os.path.join(directory, name))
            found.append(os.path.relpath(os.path.join(directory, name), prefix).replace(os.sep, "/"))
    return sorted(found)


def classifyInstall(files, target):
    """The files of an install of target that are carried by neither the allowlist nor a known not-carried kind, as
    an error, and else the not-carried ones. Every required asset must be present; an ASan file of a target that has
    no ASan and any other unexpected file are errors naming it."""
    arch = architecture(target)
    required = [resourcePath(s["name"]) for s in assetSpecs(target)]
    optional = [resourcePath(pattern % arch) for pattern in NOT_CARRIED_LIBRARIES]
    ignored = [f for f in files if f not in required and (
        f in optional or SANITIZER_HEADER.match(f) or IGNORELIST.match(f))]
    if target != pw.TARGET:
        asan = [f for f in files if f.startswith("lib/") and "asan" in f]
        if asan:
            raise pe.EngineError("%s: the install holds %s: Windows ASan is x86_64 only and none is carried" % (
                target, ", ".join(asan)))
    unexpected = [f for f in files if f not in required and f not in ignored]
    if unexpected:
        raise pe.EngineError("%s: the install holds %s, outside the allowlist %s" % (
            target, ", ".join(unexpected), ", ".join(required)))
    missing = [f for f in required if f not in files]
    if missing:
        raise pe.EngineError("%s: the install lacks %s" % (target, ", ".join(missing)))
    return ignored


def memberFacts(name, body):
    """What a member of a COFF archive is, from its bytes: {"kind": "object", "machine", "bigobj"} for an object of
    either COFF form, or {"kind": "import", "machine", "symbol", "dll", "export"} for a short import member."""
    if len(body) < IMPORT_HEADER_BYTES:
        raise pe.EngineError("member %s is %d bytes, not a COFF member" % (name, len(body)))
    sig1, sig2, version = struct.unpack_from("<HHH", body, 0)
    machine = pws.objectMachine(body)
    if (sig1, sig2) != (0, 0xFFFF):
        return {"kind": "object", "machine": machine, "bigobj": False}
    if version == 0:
        size = struct.unpack_from("<I", body, 12)[0]
        data = body[IMPORT_HEADER_BYTES:]
        parts = data.split(b"\0")
        if size != len(data) or len(parts) not in (3, 4) or parts[-1] != b"":
            raise pe.EngineError("member %s is a short import member whose size %d or strings do not fit" % (name, size))
        try:
            strings = [p.decode("ascii") for p in parts[:-1]]
        except UnicodeDecodeError:
            raise pe.EngineError("member %s names a symbol or DLL that is not ASCII" % name)
        return {"kind": "import", "machine": machine, "symbol": strings[0], "dll": strings[1],
                "export": strings[2] if len(strings) == 3 else ""}
    if version >= 2 and len(body) >= BIGOBJ_HEADER_BYTES and body[12:28] == BIGOBJ_CLASS_ID:
        return {"kind": "object", "machine": machine, "bigobj": True}
    raise pe.EngineError("member %s is an anonymous object of version %d that is neither a short import member nor a "
                         "bigobj" % (name, version))


def archiveMembers(path):
    """[(name, facts, bytes)] of the members of the archive at path."""
    with open(path, "rb") as f:
        data = f.read()
    return [(name, memberFacts(name, body), body) for name, body in pr.parseArchive(data)]


def machineMixProblem(label, members, machine):
    for name, facts, _ in members:
        if facts["machine"] != machine:
            return "%s member %s has machine %#x, not %#x" % (label, name, facts["machine"], machine)
    return None


def anyArchiveProblem(path, machine):
    """Why path is not an archive of at least one member, all of machine, whether objects or import members, or None."""
    label = os.path.basename(path)
    try:
        members = archiveMembers(path)
    except pe.EngineError as error:
        return "%s: %s" % (label, error)
    if not members:
        return "%s holds no member" % label
    return machineMixProblem(label, members, machine)


def staticProblem(path, machine):
    """Why path is not a static archive of object members of machine, or None. An empty archive and one with an import
    member are not a static runtime."""
    label = os.path.basename(path)
    problem = anyArchiveProblem(path, machine)
    if problem:
        return problem
    imports = [name for name, facts, _ in archiveMembers(path) if facts["kind"] == "import"]
    if imports:
        return "%s member %s is an import member, not an object" % (label, imports[0])
    return None


def importNames(members):
    """The names a DLL exports that the import members of an archive import."""
    return sorted({facts["export"] or facts["symbol"] for _, facts, _ in members if facts["kind"] == "import"})


def importProblem(path, machine, dll, markers):
    """Why path is not the import library of dll for machine, or None: every member of the archive is named dll and has
    machine, every import member names dll, an object member holds the import descriptor and another the null thunk
    of the DLL's stem, and each marker is imported."""
    label = os.path.basename(path)
    problem = anyArchiveProblem(path, machine)
    if problem:
        return problem
    members = archiveMembers(path)
    renamed = [name for name, _, _ in members if name != dll]
    if renamed:
        return "%s member %s is not named %s" % (label, renamed[0], dll)
    foreign = [facts["dll"] for _, facts, _ in members if facts["kind"] == "import" and facts["dll"] != dll]
    if foreign:
        return "%s imports from %s, not %s" % (label, foreign[0], dll)
    if not any(facts["kind"] == "import" for _, facts, _ in members):
        return "%s holds no import member" % label
    stem = dll[:-len(".dll")].encode("ascii")
    objects = [body for _, facts, body in members if facts["kind"] == "object"]
    if not any(DESCRIPTOR_PREFIX + stem in body for body in objects):
        return "%s holds no import descriptor %s%s" % (label, DESCRIPTOR_PREFIX.decode(), stem.decode())
    if not any(NULL_THUNK[0] + stem + NULL_THUNK[1] in body for body in objects):
        return "%s holds no null thunk of %s" % (label, stem.decode())
    names = importNames(members)
    missing = [m for m in markers if m not in names]
    if missing:
        return "%s does not import %s" % (label, ", ".join(missing))
    return None


def archiveNames(engine, path):
    """The external symbols the archive at path defines, by the engine's llvm-nm."""
    return {name for _, name in pc.archiveSymbols(engine, path)}


def symbolsProblem(engine, path, spec):
    """Why the archive at path does not define what its role needs, or defines what only the DLL may, or None."""
    names = archiveNames(engine, path)
    required = spec["symbols"]
    if spec["role"] == "asan-import":
        stem = spec["name"][:-len(".dll.a")]
        required = ["__IMPORT_DESCRIPTOR_" + stem, "__NULL_IMPORT_DESCRIPTOR", "\x7f" + stem + "_NULL_THUNK_DATA"]
    missing = [s for s in required if s not in names]
    if missing:
        return "%s does not define %s" % (os.path.basename(path), ", ".join(missing))
    if spec["role"] == "asan-thunk":
        clash = [s for s in DLL_ONLY_SYMBOLS if s in names]
        if clash:
            return "%s defines %s, which only the DLL exports" % (os.path.basename(path), ", ".join(clash))
    return None


def readDll(path):
    try:
        return pw.readPe(path)
    except (struct.error, ValueError, IndexError) as error:
        raise pe.EngineError("%s is not a readable PE file: %s" % (os.path.basename(path), error))


def dllProblem(info, spec, machine, names):
    """Why a DLL is not the x64 ASan runtime of spec, or None: machine, the DLL flag, the markers exported, every name
    the import library imports exported, and imports that are system DLLs, api sets and the UCRT alone (a libc++,
    libunwind, winpthread or msvcrt import is a refusal)."""
    imports = sorted({name.lower() for name in info["imports"]})
    if info["machine"] != machine:
        return "%s has machine %#x, not %#x" % (spec["name"], info["machine"], machine)
    if not info["characteristics"] & pw.DLL_CHARACTERISTIC:
        return "%s is not a DLL (characteristics %#x)" % (spec["name"], info["characteristics"])
    missing = [m for m in DLL_MARKERS if m not in info["exports"]]
    if missing:
        return "%s does not export %s" % (spec["name"], ", ".join(missing))
    unexported = [n for n in names if n not in info["exports"]]
    if unexported:
        return "the import library imports %s, which %s does not export" % (", ".join(unexported[:5]), spec["name"])
    other = [i for i in imports if i not in pwc.SYSTEM_IMPORTS and not i.startswith("api-ms-win-")]
    if other:
        return "%s imports %s: only system DLLs and api sets are allowed (%s are linked in)" % (
            spec["name"], ", ".join(other), ", ".join(UNWANTED_IMPORT_STEMS))
    if not any(i.startswith("api-ms-win-crt-") for i in imports):
        return "%s imports no UCRT api set: %s" % (spec["name"], imports)
    return None


def structureProblem(path, spec, target):
    """Why the file at path is not the asset spec of target by its own bytes, or None; no tool runs."""
    machine = pw.TARGETS[target]["machine"]
    if not os.path.isfile(path) or pe.isLinkLike(path):
        return "%s is not a regular file" % path
    role = spec["role"]
    if role in ("ubsan", "ubsan-cxx", "asan-thunk"):
        return staticProblem(path, machine)
    if role == "asan-import":
        return importProblem(path, machine, ASAN_DLL_NAME % architecture(target), spec["symbols"])
    return dllProblem(readDll(path), spec, machine, [])


def assetRecord(target, spec, source):
    record = {"name": spec["name"], "role": spec["role"], "target": target, "path": overlayPath(target, spec),
              "machine": "0x%x" % pw.TARGETS[target]["machine"], "sha256": pe.sha256File(source),
              "bytes": os.path.getsize(source)}
    if spec["role"] == "asan-dll":
        record["imports"] = sorted({n.lower() for n in readDll(source)["imports"]})
    else:
        record["members"] = len(archiveMembers(source))
    if spec["role"] == "asan-import":
        record["dll"] = ASAN_DLL_NAME % architecture(target)
    return record


def headerAudit(prefix, notCarried, engine, major):
    """{"matches", "missing", "differs"}: each installed sanitizer header and ignorelist against the engine's
    lib/clang/<major> file of the same name. A differing file is an error: the engine's headers would not be the
    runtime's API."""
    base = os.path.join(engine, "lib", "clang", major)
    audit = {"matches": [], "missing": [], "differs": []}
    for relative in notCarried:
        if not (SANITIZER_HEADER.match(relative) or IGNORELIST.match(relative)):
            continue
        reference = os.path.join(base, *relative.split("/"))
        if not os.path.isfile(reference):
            audit["missing"].append(relative)
        elif pe.sha256File(reference) == pe.sha256File(os.path.join(prefix, *relative.split("/"))):
            audit["matches"].append(relative)
        else:
            audit["differs"].append(relative)
    if audit["differs"]:
        raise pe.EngineError("installed %s differ from the engine's lib/clang/%s files" % (
            ", ".join(audit["differs"]), major))
    return audit


def inspectTarget(prefix, target, engine, major):
    """Validate the install in prefix for target and return {"assets": [(source, record)], "notCarried": [record],
    "headers": audit}. Nothing is written: a refusal here leaves no overlay."""
    files = installFiles(prefix)
    notCarried = classifyInstall(files, target)
    machine = pw.TARGETS[target]["machine"]
    assets, names, dll = [], [], None
    for spec in assetSpecs(target):
        source = os.path.join(prefix, *resourcePath(spec["name"]).split("/"))
        problem = structureProblem(source, spec, target)
        if not problem and spec["role"] in ("ubsan", "ubsan-cxx", "asan-thunk", "asan-import"):
            problem = symbolsProblem(engine, source, spec)
        if problem:
            raise pe.EngineError("%s: %s" % (target, problem))
        if spec["role"] == "asan-import":
            names = importNames(archiveMembers(source))
        if spec["role"] == "asan-dll":
            dll = (spec, source)
        else:
            assets.append((source, assetRecord(target, spec, source)))
    if dll:
        problem = dllProblem(readDll(dll[1]), dll[0], machine, names)
        if problem:
            raise pe.EngineError("%s: %s" % (target, problem))
        assets.append((dll[1], assetRecord(target, dll[0], dll[1])))
    return {"assets": assets, "notCarried": [{"path": f, "sha256": pe.sha256File(os.path.join(prefix, *f.split("/")))}
                                             for f in notCarried],
            "headers": headerAudit(prefix, notCarried, engine, major)}


def stageAssets(inspected, output):
    """Copy the validated assets of every target to their overlay paths under output and check each copy against the
    hash taken at validation. A path written twice is an error. Returns {target: [record]}."""
    records = {}
    for target, found in inspected.items():
        records[target] = []
        for source, record in found["assets"]:
            copy = os.path.join(output, *record["path"].split("/"))
            if os.path.lexists(copy):
                raise pe.EngineError("%s is staged twice" % record["path"])
            os.makedirs(os.path.dirname(copy), exist_ok=True)
            shutil.copyfile(source, copy)
            os.chmod(copy, 0o644)
            if pe.sha256File(copy) != record["sha256"]:
                raise pe.EngineError("%s changed while it was copied" % record["path"])
            records[target].append(record)
    return records


def copyNotice(output, llvm):
    source = os.path.realpath(os.path.join(llvm, SOURCE_SUBDIRECTORY, "LICENSE.TXT"))
    if os.path.commonpath([llvm, source]) != llvm or not os.path.isfile(source):
        raise pe.EngineError("notice compiler-rt/LICENSE.TXT is missing from %s or leaves it" % llvm)
    destination = os.path.join(output, *NOTICE.split("/"))
    os.makedirs(os.path.dirname(destination))
    shutil.copyfile(source, destination)
    return [NOTICE]


def writeProvenance(output, host, version, major, targets, inspected, records, notices, base, cpp, llvmRev, tools, python):
    receipt = {
        "kind": RECEIPT_KIND,
        "statement": "Compiler-rt sanitizer files built from a pinned LLVM source checkout with the prepared engine on "
                     "top of the source-built C runtime and its static C++ runtime. Source assets only, not an "
                     "upstream-distributed binary, not bit-reproducible by this tool, and not certified for "
                     "redistribution.",
        "redistributionCertified": False, "proofs": PROOFS,
        "producerHost": host, "engineVersion": version, "targets": targets, "cohort": "llvm-%s-source" % version,
        "engineRelative": pws.ENGINE_RELATIVE,
        "inputs": {"base": {"path": BASE_PROVENANCE, "kind": pws.RECEIPT_KIND, "sha256": base[1]},
                   "cpp": {"path": CPP_PROVENANCE, "kind": pwc.RECEIPT_KIND, "sha256": cpp[1]}},
        "sources": {"llvm-project": {"rev": llvmRev, "version": version, "major": major,
                                     "subdirectory": SOURCE_SUBDIRECTORY}},
        "tools": dict(pws.toolVersions(tools), python=python[1], clang=version),
        "recipe": {"definitions": FIXED_DEFINITIONS, "cFlags": "C config, then -Xlinker -L of the C++ payload",
                   "cxxFlags": "C++ config first, C config after it", "layout": "lib/windows"},
        "assets": records, "notCarried": {t: inspected[t]["notCarried"] for t in targets},
        "headers": {t: inspected[t]["headers"] for t in targets}, "notices": notices,
        "files": pwc.overlayRecords(output), "limits": LIMITS,
    }
    pe.writeText(os.path.join(output, *PROVENANCE.split("/")), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def ownedProblem(root, targets, listed):
    """Why the files under the directories a receipt of targets owns are not exactly listed, or a link is on the way."""
    present = set()
    for owned in ownedRoots(targets):
        base = os.path.join(root, *owned.split("/"))
        if not os.path.lexists(base):
            return "%s is missing" % owned
        for directory, directories, names in os.walk(base):
            for name in directories + names:
                if pe.isLinkLike(os.path.join(directory, name)):
                    return "%s is a link" % os.path.join(directory, name)
            present.update(os.path.relpath(os.path.join(directory, n), root).replace(os.sep, "/") for n in names)
    if present != set(listed):
        return "files %s are present or listed but not both" % sorted(present ^ set(listed))
    return None


def receiptProblem(receipt, root, inputRoot=None):
    """Why a receipt does not describe the overlay in root, or None: its kind, targets, the two input receipts' hashes
    (read from inputRoot when given), every listed file's place and hash with no link on the way and no owned file
    unlisted, and exactly the assets of each target at their paths with their hashes. A path is checked before it is
    opened."""
    if receipt.get("kind") != RECEIPT_KIND:
        return "receipt kind %r is not %r" % (receipt.get("kind"), RECEIPT_KIND)
    targets = receipt.get("targets")
    if not isinstance(targets, list) or not targets or len(set(targets)) != len(targets) \
            or any(t not in pws.SOURCE_TARGETS for t in targets):
        return "receipt targets %r are not distinct Windows source targets" % (targets,)
    if receipt.get("engineRelative") != pws.ENGINE_RELATIVE or receipt.get("proofs") != PROOFS:
        return "receipt engineRelative or proofs state is not this producer's"
    inputs = receipt.get("inputs")
    if not isinstance(inputs, dict) or {k: v.get("path") if isinstance(v, dict) else None for k, v in inputs.items()} != {
            "base": BASE_PROVENANCE, "cpp": CPP_PROVENANCE}:
        return "receipt inputs %r are not the C and C++ runtime receipts" % (inputs,)
    if inputRoot is not None:
        for name, relative in (("base", BASE_PROVENANCE), ("cpp", CPP_PROVENANCE)):
            try:
                digest = pwc.readJson(inputRoot, relative)[1]
            except (pe.EngineError, ValueError) as error:
                return str(error)
            if digest != inputs[name].get("sha256"):
                return "the %s runtime's receipt is not the one these assets were built on" % name
    listed = []
    for record in receipt.get("files") or []:
        try:
            relative = record["path"]
            for part in relative.split("/"):
                pr.checkName(part)
        except (KeyError, TypeError, AttributeError, pe.EngineError) as error:
            return "receipt file record %r: %s" % (record, error)
        if not any(relative.startswith(r + "/") for r in ownedRoots(targets)):
            return "receipt file %s is outside the paths the assets own" % relative
        linked = pws.linkedComponent(root, relative)
        if linked:
            return "%s is a link" % linked
        path = os.path.join(root, *relative.split("/"))
        if not os.path.isfile(path) or pe.sha256File(path) != record.get("sha256"):
            return "%s does not match the receipt" % relative
        listed.append(relative)
    if len(set(listed)) != len(listed):
        return "the receipt lists a file twice"
    problem = ownedProblem(root, targets, listed)
    if problem:
        return problem
    assets = receipt.get("assets")
    if not isinstance(assets, dict) or sorted(assets) != sorted(targets):
        return "receipt assets are not exactly those of %s" % targets
    for target in targets:
        specs = assetSpecs(target)
        records = assets[target]
        if not isinstance(records, list) or [(r.get("name"), r.get("role")) for r in records if isinstance(r, dict)] \
                != [(s["name"], s["role"]) for s in specs]:
            return "receipt assets of %s are not exactly %s" % (target, [s["name"] for s in specs])
        for record, spec in zip(records, specs):
            if record.get("path") != overlayPath(target, spec) or record["path"] not in listed:
                return "asset %s of %s is not at %s or not a listed file" % (spec["name"], target,
                                                                              overlayPath(target, spec))
            if pe.sha256File(os.path.join(root, *record["path"].split("/"))) != record.get("sha256"):
                return "asset record %s does not match the file" % record["path"]
    return None


def installResource(runtime, resourceRoot):
    """Install the archives of the receipt of the overlay in runtime into resourceRoot, the lib/clang/<major> directory
    of the engine that will link with them. Each is read at its canonical resource path, must match the receipt's hash
    and be the archive its role needs by its own bytes, before any is copied. A file already in resourceRoot is left
    alone if it has the same bytes and refused if not, and so is an archive at lib/<target triple>, which the driver
    reads before the one at lib/windows. The DLL is not a resource file and is never installed. Returns the relative
    paths of the archives now in resourceRoot."""
    receipt, _ = pwc.readJson(runtime, PROVENANCE)
    problem = receiptProblem(receipt, runtime, runtime)
    if problem:
        raise pe.EngineError(problem)
    copies, installed = [], []
    for target in receipt["targets"]:
        for record, spec in zip(receipt["assets"][target], assetSpecs(target)):
            if spec["role"] == "asan-dll":
                continue
            source = os.path.join(runtime, *record["path"].split("/"))
            problem = structureProblem(source, spec, target)
            if problem:
                raise pe.EngineError(problem)
            shadow = "lib/%s/%s" % (pws.SOURCE_TARGETS[target]["clangTarget"], spec["shadow"])
            destination = resourcePath(spec["name"])
            for relative in (shadow, destination):
                linked = pws.linkedComponent(resourceRoot, relative)
                if linked:
                    raise pe.EngineError("%s is a link" % linked)
            if os.path.lexists(os.path.join(resourceRoot, *shadow.split("/"))):
                raise pe.EngineError("%s would be read instead of %s" % (shadow, destination))
            target_path = os.path.join(resourceRoot, *destination.split("/"))
            installed.append(destination)
            if os.path.lexists(target_path):
                if not os.path.isfile(target_path) or pe.sha256File(target_path) != record["sha256"]:
                    raise pe.EngineError("%s already exists with other contents" % target_path)
            else:
                copies.append((source, target_path, record["sha256"]))
    for source, destination, digest in copies:
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copyfile(source, destination)
        os.chmod(destination, 0o644)
        if pe.sha256File(destination) != digest:
            raise pe.EngineError("%s was written with other contents than the receipt's" % destination)
    return installed


def prepareWindowsSanitizerRuntime(engine, runtime, output, llvm, llvmRev, tools, python, targets=None, jobs=None):
    """Write the sanitizer assets of `targets` (every Windows target when none) to the new directory `output`, built on
    a staged copy of the engine with the input runtime, compiled and linked by the build and run by nothing. The engine,
    the runtime and the checkout are read and never written: their hashes and the checkout's pin are taken before the
    build and again after it. Returns (output, receipt)."""
    engine, runtime, output = os.path.abspath(engine), os.path.abspath(runtime), os.path.abspath(output)
    targets = pw.selectWindowsTargets(targets)
    if jobs is not None and jobs < 1:
        raise pe.EngineError("jobs %d is not positive" % jobs)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    for root, what in ((engine, "engine"), (runtime, "runtime"), (llvm, "llvm-project checkout")):
        if pe.containsPath(root, output):
            raise pe.EngineError("output %s is inside the %s, which is never written" % (output, what))
    host, version, major = pr.engineMajor(engine)
    for name in ("clang", "clang++", "ld.lld", "llvm-ar", "llvm-ranlib", "llvm-nm"):
        pws.engineTool(engine, name)
    problem = collisionProblem(runtime, targets)
    if problem:
        raise pe.EngineError(problem)
    llvmRev = pws.pinnedRevisions(version, None, llvmRev)[1]
    base, cpp = inputReceipts(runtime, targets, version, major, llvmRev)
    problem = synchronizationProblem(runtime, targets)
    if problem:
        raise pe.EngineError(problem)
    source = pws.checkSourceRoot(llvm, llvmRev, "llvm-project", LLVM_MARKERS)
    pws.checkLlvmVersion(source, version)
    jobs = jobs or os.cpu_count() or 1
    inputs = {"engine": (engine, pc.treeDigest(engine)), "runtime": (runtime, pc.treeDigest(runtime))}
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    work = os.path.realpath(tempfile.mkdtemp(prefix="prepareWindowsSanitizerRuntime-"))
    try:
        pws.checkPlainPath(work, "work directory")
        pws.checkPlainPath(engine, "engine")
        environment = pws.buildEnvironment(work, dict(tools, python3=python[0]))
        stage = os.path.join(work, "stage")
        pws.stageTree(engine, os.path.join(runtime, "windows"), stage, major)
        inspected = {}
        for target in targets:
            prefix = buildSanitizers(source, stage, target, work, tools, python[0], environment, jobs)
            inspected[target] = inspectTarget(prefix, target, engine, major)
        records = stageAssets(inspected, partial)
        notices = copyNotice(partial, source)
        receipt = writeProvenance(partial, host, version, major, targets, inspected, records, notices, base, cpp,
                                  llvmRev, tools, python)
        problem = receiptProblem(receipt, partial, runtime)
        if problem:
            raise pe.EngineError(problem)
        pc.mergeOverlay(partial, os.path.join(stage, "runtime"))
        pws.checkSourceRoot(llvm, llvmRev, "llvm-project", LLVM_MARKERS)
        pws.checkLlvmVersion(source, version)
        for what, (path, digest) in inputs.items():
            if pc.treeDigest(path) != digest:
                raise pe.EngineError("the input %s %s changed during the build" % (what, path))
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return output, receipt


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--llvm-project", required=True)
    parser.add_argument("--llvm-project-rev")
    parser.add_argument("--make")
    parser.add_argument("--cmake")
    parser.add_argument("--ninja")
    parser.add_argument("--python3")
    parser.add_argument("--jobs", type=int)
    parser.add_argument("--target", action="append", default=[], help="a Windows target; every target when none")
    args = parser.parse_args(argv)
    if args.jobs is not None and args.jobs < 1:
        parser.error("--jobs %d is not positive" % args.jobs)
    try:
        tools = pws.resolveTools(None, args.make, args.cmake, args.ninja)
        output, receipt = prepareWindowsSanitizerRuntime(
            args.engine, args.runtime, args.output, args.llvm_project, args.llvm_project_rev, tools,
            pwc.resolvePython(args.python3), targets=args.target, jobs=args.jobs)
        print("%d files, %d assets of %d targets (source assets, no sanitizer flag proven)" % (
            len(receipt["files"]) + 1, sum(len(r) for r in receipt["assets"].values()), len(receipt["targets"])))
        print("overlay written to %s" % output)
    except pe.EngineError as error:
        print("prepareWindowsSanitizerRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
