#!/usr/bin/env python3
"""Prepare the static libunwind, libc++abi and libc++ of x86_64-windows-gnu and aarch64-windows-gnu from LLVM sources on top of a source-built C runtime, then prove them.

    prepareWindowsSourceCppRuntime.py --engine ENGINE_DIR --runtime RUNTIME_DIR --output NEW_OVERLAY_DIR
        --llvm-project DIR [--llvm-project-rev SHA] [--target T ...] [--make MAKE] [--cmake CMAKE] [--ninja NINJA]
        [--python3 PYTHON] [--jobs N]
    prepareWindowsSourceCppRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--deny PATH ...] [--execute]

RUNTIME_DIR holds the `windows/` that prepareWindowsSourceRuntime.py made and is only read. NEW_OVERLAY_DIR receives
new paths, each relative to RUNTIME_DIR, which prepareCppRuntime.mergeOverlay merges without replacing a file:

    windows/<target>.cxx/                    libc++.a, libc++abi.a, libunwind.a and include/, the install of that
                                             target's CMake prefix: c++/v1 with its own generated __config_site and
                                             the libc++abi headers, and the public libunwind headers
    windows/<target>.cxx.cfg                 pairs with windows/<target>.cfg
    windows/<target>.dll.cxx.cfg             pairs with windows/<target>.dll.cfg; the same payload
    notices/windows-source-cpp-provenance.json, notices/windows-source-cpp/<name>/LICENSE.TXT

The Windows paths are the Zig cohort's of prepareCppRuntime.py for x86_64-windows-gnu, so the two Windows cohorts of a
target are mutually exclusive: the input must hold none of the paths above and its
`windows/notices/windows-provenance.json` must be the receipt of the source-built C runtime. The Zig cohort's other
platforms (its Linux and Darwin configs, archives and notices), its shared `include/cxx` headers and its
`notices/cpp-provenance.json` may sit in the same runtime: nothing of them is read, replaced or listed in the receipt,
and the Windows includes of this cohort never reach `include/cxx` (a `-H` listing that does is refused). The C
runtime, its configs and the legacy .obj/.lib cross checks are not read for changes or touched.

The compiler orders the C++ config first and the base config after it, and a config's `$` lines are link inputs only:

    clang++ --no-default-config --config=<name>.cxx.cfg --config=<name>.cfg x.cpp -o x

The C++ config sets -stdlib=libc++, puts the target's c++/v1 directory first with an explicit -isystem (the base
config's -nostdinc leaves the driver no libc++ directory of its own), appends the installed public headers
(libunwind.h, unwind.h and the rest of the libunwind install) with -idirafter, so they come after every system
directory, searches the payload directory with -L and appends `$-lc++` and `$-lunwind`, which also lets a C link reach
a C++ archive; the driver does not add either to a C link and the base config's --unwindlib=none stays in force. The
C++ cohort never reaches a C link that does not name the C++ config.

For each target, in a private work directory and out of tree, the LLVM runtimes directory is configured with
libcxx/cmake/caches/MinGW.cmake (the upstream cache for ABI, compiler-rt and __USE_MINGW_ANSI_STDIO=1), the staged
engine clang driven by the target's C config, static libraries only and no tests, modules, benchmarks or docs, then
built and installed into a private prefix. The thread API is the upstream default of that recipe: the four
LIBCXX_HAS_*_THREAD_API options stay OFF, so the generated __config_site holds all four _LIBCPP_HAS_THREAD_API_*
as 0 and libcxx/include/__config selects the Win32 API for _WIN32; a site that selects Win32 itself is the same
effective API, and any other, or more than one, is refused. The staged engine is a copy of the given one with the C runtime's builtins
installed; the given engine and the input runtime are not written. The source checkout must be clean, at the pinned
commit and the engine's LLVM version before and after.

Fail loud: an unpinned or dirty checkout, a prefix with an entry outside include and lib, an installed library that is
not one of the three archives (or a shared library or import library), an archive that is empty, import-only or has a
member of another machine, an archive without the symbols the cohort needs, an installed header that is not a byte copy
of the pinned source (except the four generated include artifacts), a __config_site that does not
disable visibility annotations, set __USE_MINGW_ANSI_STDIO to 1, enable threads and select any thread API but Win32
(the default is none, which __config resolves to Win32), a link or reparse
point anywhere under an installed or staged path, and any compile or link warning. The proofs link both variants of
both targets plain and with thin and full LTO, and a C client of a C++ archive; they check the include order and
`-H` header paths, the exception defaults, the driver's `-###` link plan, the PE headers, imports, exception table
and a C control that must not change with the overlay. The build runs none of the proofs: `--prove --execute` on a
Windows host runs an executable only when this host's CPU runs that target.

The payload is a local proof from pinned upstream sources; its receipt says so and never certifies redistribution.
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

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSourceRuntime as pws

RECEIPT_KIND = "source-built-windows-cpp-runtime"
PROVENANCE = "notices/windows-source-cpp-provenance.json"
BASE_PROVENANCE = "windows/notices/" + pws.PROVENANCE
NOTICE_DIRECTORY = "notices/windows-source-cpp"
CXX_STANDARD = "-std=c++20"
CACHE = "libcxx/cmake/caches/MinGW.cmake"
LLVM_CPP_MARKERS = ("cmake/Modules/LLVMVersion.cmake", "runtimes/CMakeLists.txt", "libcxx/CMakeLists.txt",
                    "libcxxabi/CMakeLists.txt", "libunwind/CMakeLists.txt", CACHE, "libcxx/LICENSE.TXT",
                    "libcxxabi/LICENSE.TXT", "libunwind/LICENSE.TXT")
NOTICES = {"libcxx": "libcxx/LICENSE.TXT", "libcxxabi": "libcxxabi/LICENSE.TXT", "libunwind": "libunwind/LICENSE.TXT"}
ARCHIVES = ["libc++.a", "libc++abi.a", "libunwind.a"]
LEFT_OUT = ["libc++experimental.a"]
INSTALL_ROOTS = ["include", "lib"]
HEADER_ROOT = "c++/v1"
GENERATED_HEADERS = [HEADER_ROOT + "/" + name for name in
                     ("__config_site", "__assertion_handler", "module.modulemap", "libcxx.imp")]
LIBCXX_SOURCES = ["libcxx/include", "libcxxabi/include"]
UNWIND_SOURCES = ["libunwind/include"]
REQUIRED_HEADERS = GENERATED_HEADERS + [HEADER_ROOT + "/vector", HEADER_ROOT + "/cxxabi.h",
                    "libunwind.h", "__libunwind_config.h", "unwind.h", "unwind_itanium.h", "unwind_arm_ehabi.h"]
ABI_SYMBOLS = ["__cxa_throw", "__cxa_begin_catch", "__cxa_end_catch", "__gxx_personality_seh0"]
UNWIND_SYMBOLS = ["_Unwind_RaiseException", "_Unwind_Resume", "_Unwind_Backtrace"]
REQUIRED_SYMBOLS = {"libc++.a": ABI_SYMBOLS, "libc++abi.a": ABI_SYMBOLS, "libunwind.a": UNWIND_SYMBOLS}
LIBCXX_SYMBOL = re.compile(r"^_ZNSt\d+__\w+")
CONFIG_DEFINE = re.compile(r"^\s*#\s*define\s+([A-Za-z_]\w*)(?:\s+(\S.*?))?\s*$")
THREAD_APIS = ["PTHREAD", "EXTERNAL", "WIN32", "C11"]
EFFECTIVE_THREAD_API = "WIN32"
LINK_TAIL = ["c++", "unwind"]
UNWANTED_LIBRARIES = ["-lgcc", "-lgcc_eh", "-lgcc_s", "-lstdc++", "-lsupc++", "-lpthread"]
EXCEPTION_DEFAULTS = ["-fcxx-exceptions", "-fexceptions", "-exception-model=seh"]
SYSTEM_IMPORTS = {"kernel32.dll", "ntdll.dll", "advapi32.dll", "shell32.dll", "user32.dll", "bcrypt.dll", "ws2_32.dll"}
EXPECTED_MAIN = {
    pw.TARGET: "cpp sum=45 static=7 caught=deep destroyed=4 thread=10\nlong double size=16 delta=8.673617e-19\n",
    pw.ARM64_TARGET: "cpp sum=45 static=7 caught=deep destroyed=4 thread=10\nlong double size=8 delta=0.000000e+00\n"}
EXPECTED_UNWIND = "unwind steps=1 backtrace=1\n"
EXPECTED_CLIENT = "archive sum=12\n"
HEADER_LINE = re.compile(r"^\.+ (.+)$")
PROOFS = {
    "exe": {"variant": "exe", "fixture": "windowsSourceCppMain.cpp", "flags": []},
    "dll": {"variant": "dll", "fixture": "windowsSourceCppDll.cpp", "flags": ["-shared"]},
    "unwind": {"variant": "exe", "fixture": "windowsSourceCppUnwind.cpp", "flags": []},
}
FIXED_DEFINITIONS = {
    "CMAKE_BUILD_TYPE": "Release", "CMAKE_SYSTEM_NAME": "Windows",
    "CMAKE_C_COMPILER_WORKS": "TRUE", "CMAKE_CXX_COMPILER_WORKS": "TRUE", "CMAKE_ASM_COMPILER_WORKS": "TRUE",
    "LLVM_ENABLE_RUNTIMES": "libunwind;libcxxabi;libcxx", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR": "OFF",
    "LIBUNWIND_USE_COMPILER_RT": "ON", "LIBCXXABI_USE_COMPILER_RT": "ON", "LIBCXX_USE_COMPILER_RT": "ON",
    "LIBCXXABI_USE_LLVM_UNWINDER": "ON", "LIBCXX_CXX_ABI": "libcxxabi", "LIBCXX_ENABLE_ABI_LINKER_SCRIPT": "OFF",
    "LIBUNWIND_ENABLE_SHARED": "OFF", "LIBCXXABI_ENABLE_SHARED": "OFF", "LIBCXX_ENABLE_SHARED": "OFF",
    "LIBUNWIND_ENABLE_STATIC": "ON", "LIBCXXABI_ENABLE_STATIC": "ON", "LIBCXX_ENABLE_STATIC": "ON",
    "LIBCXX_ENABLE_STATIC_ABI_LIBRARY": "ON", "LIBUNWIND_INSTALL_HEADERS": "ON", "LIBCXX_INSTALL_MODULES": "OFF",
    "LLVM_INCLUDE_TESTS": "OFF", "LIBUNWIND_INCLUDE_TESTS": "OFF", "LIBCXXABI_INCLUDE_TESTS": "OFF",
    "LIBCXX_INCLUDE_TESTS": "OFF", "LIBCXX_INCLUDE_BENCHMARKS": "OFF", "LIBCXX_INCLUDE_DOCS": "OFF",
    "LIBUNWIND_LIBDIR_SUFFIX": "", "LIBCXXABI_LIBDIR_SUFFIX": "", "LIBCXX_LIBDIR_SUFFIX": "",
}
LIMITS = ["the preparation runs no Windows binary: --prove --execute on a Windows host runs an executable only when "
          "its CPU is this host's (x86_64 files also on an ARM64 host), and a DLL is linked and inspected, never loaded",
          "static libraries only: libc++, libc++abi and libunwind are linked into the program, no libc++.dll exists",
          "no sanitizer runtime and no C++ vptr check: compiler-rt's sanitizers are a later step",
          "the thread API is the upstream default of the fixed recipe, Win32 through libcxx/include/__config; no "
          "pthread, external or C11 thread API is built, linked or accepted",
          "libc++experimental.a is installed by the build and is left out of the payload",
          "no archive is normalized: the files are as the build and llvm-ar wrote them",
          "only the Windows cohorts are mutually exclusive: this one and prepareCppRuntime.py's Zig cohort of the same "
          "Windows target cannot share a runtime, while its Linux and Darwin cohorts and shared headers can"]


def payloadDirectory(target):
    return "windows/%s.cxx" % target


def configPath(target, variant):
    return "windows/%s.cxx.cfg" % pws.variantDirectory(target, variant)


def baseConfigPath(target, variant):
    return "windows/" + pws.variantConfig(target, variant)


def ownedRoots(targets):
    """The runtime-relative paths a receipt of targets may own, directories first."""
    roots = [NOTICE_DIRECTORY] + [payloadDirectory(t) for t in targets]
    configs = [configPath(t, v) for t in targets for v in pws.SOURCE_VARIANTS]
    return roots, configs


def resolvePython(python3=None):
    """(absolute path, version line) of a Python 3 for runtimes/CMakeLists.txt, which requires one."""
    path = python3 or shutil.which("python3") or shutil.which("python")
    if not path:
        raise pe.EngineError("the host has no python3; pass --python3")
    version = pe.run([path, "--version"]).strip()
    if not version.startswith("Python 3."):
        raise pe.EngineError("%s is %r, not Python 3" % (path, version))
    return os.path.abspath(path), version


def readJson(runtime, relative):
    linked = pws.linkedComponent(runtime, relative)
    if linked:
        raise pe.EngineError("%s is a link" % linked)
    path = os.path.join(runtime, *relative.split("/"))
    if not os.path.isfile(path):
        raise pe.EngineError("%s is missing" % path)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f), pe.sha256File(path)
    except ValueError as error:
        raise pe.EngineError("%s is not JSON: %s" % (path, error))


def baseReceipt(runtime, targets):
    """(the source C runtime's receipt, its sha256) once it is the receipt of that runtime for every target and
    describes the files in runtime/windows; anything else, the Zig runtime included, is refused."""
    receipt, digest = readJson(runtime, BASE_PROVENANCE)
    if receipt.get("kind") != pws.RECEIPT_KIND:
        raise pe.EngineError("%s is kind %r, not the source-built C runtime %r" % (
            BASE_PROVENANCE, receipt.get("kind"), pws.RECEIPT_KIND))
    absent = [t for t in targets if t not in receipt.get("targets", [])]
    if absent:
        raise pe.EngineError("the C runtime has no %s" % ", ".join(absent))
    problem = pws.receiptProblem(receipt, os.path.join(runtime, "windows"))
    if problem:
        raise pe.EngineError(problem)
    return receipt, digest


def collisionProblem(runtime, targets):
    """Why runtime holds a path of this cohort, which are also the Windows paths of the Zig cohort for the same
    target, or None. The Zig cohort's other platforms, its shared include/cxx and its notices/cpp-provenance.json are
    not paths of this cohort and are no collision."""
    roots, configs = ownedRoots(targets)
    paths = roots + configs + [PROVENANCE]
    taken = [p for p in paths if os.path.lexists(os.path.join(runtime, *p.split("/")))]
    if taken:
        return "%s already has %s: the Zig and the source C++ cohorts of a Windows target exclude each other and " \
               "nothing is replaced" % (runtime, ", ".join(taken))
    return None


def runtimesDefinitions(stage, target, prefix, python):
    """The -D definitions of the runtimes configure of target: the fixed ones, the staged engine's tools and the
    C config of the target as the init flags of every language."""
    spec = pws.SOURCE_TARGETS[target]
    config = os.path.join(stage, "runtime", "windows", pws.variantConfig(target, "exe"))
    flags = " ".join(["--no-default-config", "--config=" + config])
    triple = spec["clangTarget"]
    clang = pws.engineTool(stage, "clang")
    definitions = dict(FIXED_DEFINITIONS)
    definitions.update({
        "CMAKE_INSTALL_PREFIX": prefix, "CMAKE_C_COMPILER": clang, "CMAKE_CXX_COMPILER": pws.engineTool(stage, "clang++"),
        "CMAKE_ASM_COMPILER": clang, "CMAKE_AR": pws.engineTool(stage, "llvm-ar"),
        "CMAKE_RANLIB": pws.engineTool(stage, "llvm-ranlib"), "CMAKE_C_COMPILER_TARGET": triple,
        "CMAKE_CXX_COMPILER_TARGET": triple, "CMAKE_ASM_COMPILER_TARGET": triple, "CMAKE_C_FLAGS_INIT": flags,
        "CMAKE_CXX_FLAGS_INIT": flags, "CMAKE_ASM_FLAGS_INIT": flags, "Python3_EXECUTABLE": python})
    return definitions


def runtimesCommand(llvm, stage, target, build, prefix, tools, python):
    """The configure command: the upstream MinGW cache first, then the definitions, so a definition decides."""
    command = [tools["cmake"], "-C", os.path.join(llvm, *CACHE.split("/")), "-S", os.path.join(llvm, "runtimes"),
               "-B", build]
    if "ninja" in tools:
        command += ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + tools["ninja"]]
    else:
        command += ["-G", "Unix Makefiles"]
    definitions = runtimesDefinitions(stage, target, prefix, python)
    return command + ["-D%s=%s" % (name, definitions[name]) for name in sorted(definitions)]


def buildRuntimes(llvm, stage, target, work, tools, python, environment, jobs):
    """Configure, build and install the three runtimes of target into a private prefix, never into the engine.
    Returns the prefix."""
    build, prefix = os.path.join(work, target + "-cxx-build"), os.path.join(work, target + "-cxx")
    runBuild = pws.runBuild
    runBuild(runtimesCommand(llvm, stage, target, build, prefix, tools, python), work, environment,
             os.path.join(work, target + "-cxx-configure.log"))
    runBuild([tools["cmake"], "--build", build, "-j", str(jobs)], work, environment,
             os.path.join(work, target + "-cxx-build.log"))
    runBuild([tools["cmake"], "--install", build, "--prefix", prefix], work, environment,
             os.path.join(work, target + "-cxx-install.log"))
    if not os.path.isdir(prefix):
        raise pe.EngineError("the runtimes install made no %s" % prefix)
    return prefix


def installProblem(prefix):
    """Why the install in prefix is not exactly include/ and lib/ holding the three archives (and at most the left out
    one) and regular headers, with no link or reparse point and nothing opened first, or None."""
    if pe.isLinkLike(prefix) or not os.path.isdir(prefix):
        return "%s is not a directory" % prefix
    entries = sorted(os.listdir(prefix))
    if entries != INSTALL_ROOTS:
        return "%s holds %s, not %s" % (prefix, entries, INSTALL_ROOTS)
    for name in entries:
        if pe.isLinkLike(os.path.join(prefix, name)) or not os.path.isdir(os.path.join(prefix, name)):
            return "%s/%s is not a directory" % (prefix, name)
    library = os.path.join(prefix, "lib")
    names = sorted(os.listdir(library))
    for name in names:
        if pe.isLinkLike(os.path.join(library, name)) or not os.path.isfile(os.path.join(library, name)):
            return "lib/%s is not a regular file" % name
    unexpected = [n for n in names if n not in ARCHIVES + LEFT_OUT]
    if unexpected:
        return "lib holds %s: only %s are installed" % (", ".join(unexpected), ", ".join(ARCHIVES))
    missing = [n for n in ARCHIVES if n not in names]
    if missing:
        return "lib lacks %s" % ", ".join(missing)
    include = os.path.join(prefix, "include")
    present = []
    for directory, directories, files in os.walk(include):
        for name in directories + files:
            path = os.path.join(directory, name)
            if pe.isLinkLike(path):
                return "%s is a link" % path
            if not pr.SAFE_NAME.match(name) or name in (".", ".."):
                return "include holds the unsupported name %r" % name
        present += [os.path.relpath(os.path.join(directory, name), include).replace(os.sep, "/") for name in files]
    absent = [h for h in REQUIRED_HEADERS if h not in present]
    if absent:
        return "include lacks %s" % ", ".join(absent)
    return None


def sourceHeader(llvm, relative):
    """The pinned source path an installed header (relative to include/) must be a byte copy of, or None."""
    if relative.startswith(HEADER_ROOT + "/"):
        rest, roots = relative[len(HEADER_ROOT) + 1:], LIBCXX_SOURCES
    else:
        rest, roots = relative, UNWIND_SOURCES
    for root in roots:
        candidate = os.path.join(llvm, *root.split("/"), *rest.split("/"))
        if os.path.isfile(candidate):
            return candidate
    return None


def headerProblem(prefix, llvm):
    """Why an installed header is not a byte copy of the pinned source's, a generated one aside, or None."""
    include = os.path.join(prefix, "include")
    for directory, _, files in os.walk(include):
        for name in sorted(files):
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, include).replace(os.sep, "/")
            if relative in GENERATED_HEADERS:
                continue
            source = sourceHeader(llvm, relative)
            if source is None:
                return "installed header %s is in no pinned source include directory" % relative
            if pe.sha256File(source) != pe.sha256File(path):
                return "installed header %s differs from the pinned source's" % relative
    return None


def configSiteFacts(text):
    """((every {name: value} #define of a generated __config_site, the effective thread API, the thread APIs the site
    itself selects), None), or (None, why it is not the static-only, ANSI-stdio, threaded, Win32 config site of this
    cohort). The upstream default of the recipe selects none, and libcxx/include/__config then resolves the Win32 API
    for _WIN32, which is the effective one; a site that selects Win32 itself is the same, and PTHREAD, EXTERNAL or C11
    (the options the recipe never sets), several selections, a value that is not 0 or 1 and a site without threads are
    refused."""
    defines = {}
    for line in text.splitlines():
        found = CONFIG_DEFINE.match(line)
        if found:
            defines[found.group(1)] = found.group(2) or ""
    if "_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS" not in defines:
        return None, "__config_site does not define _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS: the libraries are not static-only"
    if defines.get("__USE_MINGW_ANSI_STDIO") != "1":
        return None, "__config_site defines __USE_MINGW_ANSI_STDIO as %r, not 1" % defines.get("__USE_MINGW_ANSI_STDIO")
    if defines.get("_LIBCPP_HAS_THREADS") != "1":
        return None, "__config_site defines _LIBCPP_HAS_THREADS as %r, not 1" % defines.get("_LIBCPP_HAS_THREADS")
    for api in THREAD_APIS:
        name = "_LIBCPP_HAS_THREAD_API_" + api
        if defines.get(name) not in ("0", "1"):
            return None, "__config_site defines %s as %r, not 0 or 1" % (name, defines.get(name))
    selected = [api for api in THREAD_APIS if defines["_LIBCPP_HAS_THREAD_API_" + api] == "1"]
    if len(selected) > 1:
        return None, "__config_site selects the thread APIs %s, not at most one" % selected
    if selected not in ([], [EFFECTIVE_THREAD_API]):
        return None, "__config_site selects the %s thread API: the recipe sets no thread API option, which leaves %s " \
                     "through libcxx/include/__config, and builds no other" % (selected[0], EFFECTIVE_THREAD_API)
    return (defines, EFFECTIVE_THREAD_API, selected), None


def symbolProblem(engine, path, required, libcxx):
    """Why the archive at path does not define each of required, or (libcxx) a libc++ symbol too, or None."""
    names = {name for _, name in pc.archiveSymbols(engine, path)}
    missing = [s for s in required if s not in names]
    if missing:
        return "%s does not define %s" % (os.path.basename(path), ", ".join(missing))
    if libcxx and not any(LIBCXX_SYMBOL.match(name) for name in names):
        return "%s defines no libc++ symbol" % os.path.basename(path)
    return None


def stagePayload(prefix, target, llvm, engine, output):
    """Validate the install in prefix for target and copy its three archives and its include tree to
    output/windows/<target>.cxx. Nothing is written before every check passed. Returns the receipt payload record."""
    problem = installProblem(prefix) or headerProblem(prefix, llvm)
    if problem:
        raise pe.EngineError("%s: %s" % (target, problem))
    machine = pw.TARGETS[target]["machine"]
    for name in ARCHIVES:
        path = os.path.join(prefix, "lib", name)
        problem = pws.builtinsProblem(path, machine) or symbolProblem(
            engine, path, REQUIRED_SYMBOLS[name], name == "libc++.a")
        if problem:
            raise pe.EngineError("%s: %s" % (target, problem))
    with open(os.path.join(prefix, "include", *GENERATED_HEADERS[0].split("/")), encoding="utf-8") as f:
        facts, problem = configSiteFacts(f.read())
    if problem:
        raise pe.EngineError("%s: %s" % (target, problem))
    defines, threadApi, siteSelects = facts
    directory = os.path.join(output, *payloadDirectory(target).split("/"))
    os.makedirs(directory)
    archives = []
    for name in ARCHIVES:
        copy = os.path.join(directory, name)
        shutil.copyfile(os.path.join(prefix, "lib", name), copy)
        os.chmod(copy, 0o644)
        with open(copy, "rb") as f:
            members = len(pr.parseArchive(f.read()))
        archives.append({"name": name, "sha256": pe.sha256File(copy), "bytes": os.path.getsize(copy),
                         "machine": "0x%x" % machine, "members": members})
    pr.copyTree(os.path.join(prefix, "include"), os.path.join(directory, "include"))
    site = os.path.join(directory, "include", *GENERATED_HEADERS[0].split("/"))
    return {"directory": payloadDirectory(target), "archives": archives, "threadApi": threadApi,
            "threadApiSite": siteSelects,
            "configSite": {"sha256": pe.sha256File(site), "defines": defines},
            "headers": pc.treeDigest(os.path.join(directory, "include")),
            "leftOut": [n for n in sorted(os.listdir(os.path.join(prefix, "lib"))) if n in LEFT_OUT]}


def renderCxxConfig(target):
    """Text of windows/<target>[.dll].cxx.cfg: the same for both variants, and relative to the config directory. The
    -idirafter directory is the install's include root, the late public path of libunwind.h and unwind.h."""
    directory = "<CFGDIR>/%s" % payloadDirectory(target).split("/")[-1]
    lines = [pr.configLine(["-stdlib=libc++"]), pr.configLine(["-isystem", directory + "/include/" + HEADER_ROOT]),
             pr.configLine(["-idirafter", directory + "/include"]),
             pr.configLine(["-Xlinker", "-L", "-Xlinker", directory])]
    lines += ["$" + pr.configLine(["-l" + stem]) for stem in LINK_TAIL]
    return "\n".join(lines) + "\n"


def copyNotices(output, llvm):
    records = []
    for name, relative in sorted(NOTICES.items()):
        source = os.path.realpath(os.path.join(llvm, *relative.split("/")))
        if os.path.commonpath([llvm, source]) != llvm or not os.path.isfile(source):
            raise pe.EngineError("notice %s is missing from %s or leaves it" % (relative, llvm))
        destination = os.path.join(output, *NOTICE_DIRECTORY.split("/"), name, "LICENSE.TXT")
        os.makedirs(os.path.dirname(destination))
        shutil.copyfile(source, destination)
        records.append("%s/%s/LICENSE.TXT" % (NOTICE_DIRECTORY, name))
    return records


def overlayRecords(output):
    records = [{"path": relative.replace(os.sep, "/"), "sha256": pe.sha256File(os.path.join(output, relative))}
               for relative in pc.overlayFiles(output)]
    return sorted(records, key=lambda record: record["path"])


def variantRecords(targets, payloads):
    return [{"target": t, "variant": v, "config": configPath(t, v), "base": baseConfigPath(t, v),
             "directory": payloadDirectory(t), "threadApi": payloads[t]["threadApi"]}
            for t in targets for v in pws.SOURCE_VARIANTS]


def writeProvenance(output, host, version, major, targets, payloads, notices, base, llvm, llvmRev, tools, python):
    receipt = {
        "kind": RECEIPT_KIND,
        "statement": "Built from a pinned LLVM source checkout with the prepared engine on top of the source-built "
                     "C runtime. Not an upstream-distributed binary and not bit-reproducible by this tool.",
        "redistributionCertified": False,
        "producerHost": host, "engineVersion": version, "targets": targets, "cohort": "llvm-%s-source" % version,
        "engineRelative": pws.ENGINE_RELATIVE,
        "base": {"path": BASE_PROVENANCE, "kind": pws.RECEIPT_KIND, "sha256": base[1]},
        "sources": {"llvm-project": {"rev": llvmRev, "version": version, "major": major, "cache": CACHE,
                                     "cacheSha256": pe.sha256File(os.path.join(llvm, *CACHE.split("/")))}},
        "tools": dict(pws.toolVersions(tools), python=python[1], clang=version),
        "recipe": {"definitions": FIXED_DEFINITIONS, "cache": CACHE, "cxxStandard": CXX_STANDARD,
                   "linkTail": LINK_TAIL, "configOrder": "C++ config first, base config after"},
        "payloads": payloads, "variants": variantRecords(targets, payloads), "notices": notices,
        "files": overlayRecords(output), "limits": LIMITS,
    }
    pe.writeText(os.path.join(output, *PROVENANCE.split("/")), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def ownedProblem(runtime, targets, listed):
    """Why the files under the paths a receipt of targets owns are not exactly listed, or a link is on the way."""
    roots, configs = ownedRoots(targets)
    present = set()
    for root in roots:
        base = os.path.join(runtime, *root.split("/"))
        if not os.path.lexists(base):
            return "%s is missing" % root
        for directory, directories, names in os.walk(base):
            for name in directories + names:
                if pe.isLinkLike(os.path.join(directory, name)):
                    return "%s is a link" % os.path.join(directory, name)
            present.update(os.path.relpath(os.path.join(directory, n), runtime).replace(os.sep, "/") for n in names)
    present.update(c for c in configs if os.path.lexists(os.path.join(runtime, *c.split("/"))))
    if present != set(listed):
        return "files %s are present or listed but not both" % sorted(present ^ set(listed))
    return None


def receiptProblem(receipt, runtime):
    """Why a receipt does not describe the overlay in runtime, or None: its kind, targets, the base receipt's hash,
    every listed file's place and hash with no link on the way and no owned file unlisted, the variants, and the
    archive records. A path is checked before it is opened."""
    if receipt.get("kind") != RECEIPT_KIND:
        return "receipt kind %r is not %r" % (receipt.get("kind"), RECEIPT_KIND)
    targets = receipt.get("targets")
    if not isinstance(targets, list) or not targets or len(set(targets)) != len(targets) \
            or any(t not in pws.SOURCE_TARGETS for t in targets):
        return "receipt targets %r are not distinct Windows source targets" % (targets,)
    if receipt.get("engineRelative") != pws.ENGINE_RELATIVE:
        return "receipt engineRelative %r is not %r" % (receipt.get("engineRelative"), pws.ENGINE_RELATIVE)
    base = receipt.get("base")
    if not isinstance(base, dict) or base.get("path") != BASE_PROVENANCE or base.get("kind") != pws.RECEIPT_KIND:
        return "receipt base %r is not the source C runtime's receipt" % (base,)
    try:
        baseReceiptJson, digest = readJson(runtime, BASE_PROVENANCE)
    except (pe.EngineError, ValueError) as error:
        return str(error)
    if digest != base.get("sha256") or baseReceiptJson.get("kind") != pws.RECEIPT_KIND:
        return "the C runtime's receipt is not the one this overlay was built on"
    roots, configs = ownedRoots(targets)
    listed = []
    for record in receipt.get("files") or []:
        try:
            relative = record["path"]
            for part in relative.split("/"):
                pr.checkName(part)
        except (KeyError, TypeError, AttributeError, pe.EngineError) as error:
            return "receipt file record %r: %s" % (record, error)
        if not any(relative.startswith(r + "/") for r in roots) and relative not in configs:
            return "receipt file %s is outside the paths the overlay owns" % relative
        linked = pws.linkedComponent(runtime, relative)
        if linked:
            return "%s is a link" % linked
        path = os.path.join(runtime, *relative.split("/"))
        if not os.path.isfile(path) or pe.sha256File(path) != record.get("sha256"):
            return "%s does not match the receipt" % relative
        listed.append(relative)
    if len(set(listed)) != len(listed):
        return "the receipt lists a file twice"
    problem = ownedProblem(runtime, targets, listed)
    if problem:
        return problem
    pairs = [(t, v) for t in targets for v in pws.SOURCE_VARIANTS]
    variants = receipt.get("variants")
    if not isinstance(variants, list) or sorted((v.get("target"), v.get("variant")) for v in variants
                                                 if isinstance(v, dict)) != sorted(pairs):
        return "receipt variants are not exactly %s" % pairs
    for variant in variants:
        target, kind = variant["target"], variant["variant"]
        if variant.get("config") != configPath(target, kind) or variant.get("base") != baseConfigPath(target, kind) \
                or variant.get("directory") != payloadDirectory(target) or variant["config"] not in listed:
            return "receipt variant %s %s names other configs or a config that is not a listed file" % (target, kind)
    for target in targets:
        payload = (receipt.get("payloads") or {}).get(target)
        if not isinstance(payload, dict) or [a.get("name") for a in payload.get("archives") or []] != ARCHIVES:
            return "receipt payload of %s does not list %s" % (target, ARCHIVES)
        for archive in payload["archives"]:
            relative = payloadDirectory(target) + "/" + archive["name"]
            if relative not in listed or pe.sha256File(os.path.join(runtime, *relative.split("/"))) != archive.get("sha256"):
                return "archive record %s does not match the file" % relative
        for kind in pws.SOURCE_VARIANTS:
            with open(os.path.join(runtime, *configPath(target, kind).split("/")), encoding="utf-8") as f:
                if f.read() != renderCxxConfig(target):
                    return "%s is not the config this producer writes" % configPath(target, kind)
        if payload.get("threadApi") != EFFECTIVE_THREAD_API or payload.get("threadApiSite") not in (
                [], [EFFECTIVE_THREAD_API]):
            return "receipt payload of %s records the thread API %r (site %r), not %s" % (
                target, payload.get("threadApi"), payload.get("threadApiSite"), EFFECTIVE_THREAD_API)
    return None


def pairFlags(runtime, target, variant):
    return ["--no-default-config", "--config=" + os.path.join(runtime, *configPath(target, variant).split("/")),
            "--config=" + os.path.join(runtime, *baseConfigPath(target, variant).split("/"))]


def baseFlags(runtime, target, variant):
    return ["--no-default-config", "--config=" + os.path.join(runtime, *baseConfigPath(target, variant).split("/"))]


def selectionProblem(plan, runtime, target, variant, kind):
    """Why the one ld.lld line of a `-###` plan does not show the driver choosing the variant's startup object,
    crtbegin.o and crtend.o, the C tail, the builtins of the resource directory, the payload directory and one
    `-lunwind` after a `-lc++` (kind `cxx`, a clang++ link: the driver adds its own `-lc++`, so one or more) or
    exactly one `-lc++` (kind `client`, a clang link of C objects: nothing is added by the driver), and no libgcc,
    libstdc++ or pthread library (the Win32 thread API needs none), or None."""
    directory = os.path.normpath(os.path.join(runtime, "windows", pws.variantDirectory(target, variant)))
    payload = os.path.normpath(os.path.join(runtime, *payloadDirectory(target).split("/")))
    lines = [re.findall(r'"([^"]*)"', line) for line in plan.splitlines()]
    links = [words for words in lines if words and os.path.basename(words[0]).startswith("ld.lld")]
    if len(links) != 1:
        return "the plan has %d ld.lld lines, not one" % len(links)
    words = links[0]
    startups = [os.path.normpath(w) for w in words if os.path.basename(w) in pws.STARTUP_OBJECTS]
    wanted = os.path.join(directory, pws.SOURCE_VARIANTS[variant]["startup"])
    if startups != [wanted]:
        return "startup objects %s are not %s" % (startups, wanted)
    normalized = [os.path.normpath(w) for w in words]
    for object_ in ("crtbegin.o", "crtend.o"):
        if os.path.join(directory, object_) not in normalized:
            return "the plan does not link %s from %s" % (object_, directory)
    absent = ["-l" + stem for stem in ("mingw32", "moldname", "mingwex", "msvcrt") + tuple(pws.SYSTEM_LIBRARIES)
              if "-l" + stem not in words]
    if absent:
        return "the plan lacks %s" % ", ".join(absent)
    searched = [os.path.normpath(words[i + 1]) for i, w in enumerate(words[:-1]) if w == "-L"] + [
        os.path.normpath(w[2:]) for w in words if w.startswith("-L") and len(w) > 2]
    if payload not in searched:
        return "the plan does not search the payload directory %s: %s" % (payload, searched)
    version = re.search(r"clang version (\d+)", plan)
    if version is None:
        return "the plan names no compiler version"
    resource = os.path.normpath(os.path.join(runtime, "windows", pws.ENGINE_RELATIVE, "lib", "clang",
                                            version.group(1), "lib", "windows", pws.builtinsName(target)))
    builtins = [os.path.normpath(w) for w in words if os.path.basename(w) == pws.builtinsName(target)]
    if not builtins or set(builtins) != {resource}:
        return "the plan does not link %s from %s: %s" % (pws.builtinsName(target), resource, builtins)
    count = words.count("-lc++")
    if (kind == "client" and count != 1) or (kind == "cxx" and count < 1):
        return "the plan has %d -lc++, which a %s link does not allow" % (count, kind)
    if words.count("-lunwind") != 1:
        return "the plan has %d -lunwind, not one" % words.count("-lunwind")
    if words.index("-lc++") > words.index("-lunwind"):
        return "the plan links -lunwind before -lc++"
    unwanted = [w for w in words if w in UNWANTED_LIBRARIES]
    if unwanted:
        return "the plan links %s" % ", ".join(unwanted)
    return None


def headerPaths(stderr):
    return [os.path.normpath(m.group(1)) for line in stderr.splitlines() for m in [HEADER_LINE.match(line)] if m]


def headersProblem(stderr, root):
    """Why the `-H` listing of a compile has a header outside root or one of the Zig cohort's include/cxx, or None.
    The listing must name at least a libc++ header."""
    root = os.path.normpath(root)
    paths = headerPaths(stderr)
    if not paths:
        return "the -H listing names no header"
    foreign = [p for p in paths if os.path.commonpath([root, p]) != root or "/include/cxx/" in p.replace(os.sep, "/")]
    if foreign:
        return "headers outside the staged tree or of include/cxx: %s" % foreign[:5]
    if not any(HEADER_ROOT in p.replace(os.sep, "/") for p in paths):
        return "no header came from %s" % HEADER_ROOT
    return None


def includeOrderProblem(entries, target):
    """Why the include search list (the tree root replaced by $ROOT) of a pair compile does not put the target's c++/v1
    first, hold a libc directory and only staged paths, and end with the install's include root (the late public
    directory of libunwind.h and unwind.h), or None."""
    libcxx = "$ROOT/runtime/%s/include/%s" % (payloadDirectory(target), HEADER_ROOT)
    public = "$ROOT/runtime/%s/include" % payloadDirectory(target)
    libc = [e for e in entries if "/include/libc/" in e]
    if entries[:1] != [libcxx] or not libc or any(not e.startswith("$ROOT/") for e in entries):
        return "include order %s does not put %s first and only staged paths" % (entries, libcxx)
    if entries.count(public) != 1 or entries[-1] != public:
        return "include order %s does not end with the public header directory %s once" % (entries, public)
    return None


def publicHeadersProblem(stderr, root, target):
    """Why the `-H` listing of a compile that includes <libunwind.h> through the pair alone is not headersProblem-clean
    or does not name the install's libunwind.h, or None."""
    problem = headersProblem(stderr, root)
    if problem:
        return problem
    wanted = os.path.normpath(os.path.join(root, "runtime", *payloadDirectory(target).split("/"), "include",
                                          "libunwind.h"))
    if wanted not in headerPaths(stderr):
        return "libunwind.h did not come from %s" % wanted
    return None


def exceptionTableSize(path):
    """Size of the exception directory of a PE32+ file, the .pdata of both x86_64 and ARM64."""
    with open(path, "rb") as f:
        data = f.read()
    base = struct.unpack_from("<I", data, 0x3c)[0]
    return struct.unpack_from("<II", data, base + 24 + 112 + 3 * 8)[1]


def peProblem(proof, info, target, table):
    """Why a linked file is not the static-only UCRT executable or DLL of the proof for target, or None. Imports must be
    system DLLs and api-ms-win-*, with the UCRT among them; any libc++, libunwind, winpthread or msvcrt import fails."""
    expected = pw.TARGETS[target]
    imports = {name.lower() for name in info["imports"]}
    if info["machine"] != expected["machine"]:
        return "machine %#x is not %s" % (info["machine"], expected["machineName"])
    if bool(info["characteristics"] & pw.DLL_CHARACTERISTIC) != (proof == "dll"):
        return "characteristics %#x do not match a %s" % (info["characteristics"], proof)
    if proof != "dll" and info["subsystem"] != pw.SUBSYSTEM_CONSOLE:
        return "subsystem %d is not console" % info["subsystem"]
    if proof == "dll" and "cppProbe" not in info["exports"]:
        return "exports %s lack cppProbe" % info["exports"]
    other = sorted(i for i in imports if i not in SYSTEM_IMPORTS and not i.startswith("api-ms-win-"))
    if other or "kernel32.dll" not in imports or not any(i.startswith("api-ms-win-crt-") for i in imports):
        return "imports %s are not system DLLs and the UCRT (unexpected %s)" % (sorted(imports), other)
    return None if table else "no exception table"


def cxxSteps(stage, work, target):
    """([(name, command)], {(proof, mode): linked file}, [objects that must hold bitcode], [(name, `-###` plan, proof)])."""
    runtime = os.path.join(stage, "runtime")
    clangxx = os.path.join(stage, "bin", "clang++")
    steps, outputs, bitcode, plans = [], {}, [], []
    for name, proof in PROOFS.items():
        pair = pairFlags(runtime, target, proof["variant"])
        fixture = os.path.join(pr.FIXTURES, proof["fixture"])
        suffix = ".dll" if proof["variant"] == "dll" else ".exe"
        for mode, flags in pws.LTO_MODES:
            obj, output = os.path.join(work, name + mode + ".o"), os.path.join(work, name + mode + suffix)
            steps.append(("%s %s compile" % (name, mode), [clangxx] + pair + [CXX_STANDARD, "-O2"] + flags
                          + ["-c", fixture, "-o", obj]))
            steps.append(("%s %s link" % (name, mode), [clangxx] + pair + flags + proof["flags"] + [obj, "-o", output]))
            outputs[(name, mode)] = output
            if flags:
                bitcode.append(obj)
        plans.append(("%s plan" % name, [clangxx] + pair + proof["flags"] + [
            "-###", os.path.join(work, name + "plain.o"), "-o", os.path.join(work, name + "plan" + suffix)], name))
    return steps, outputs, bitcode, plans


def checkCompile(run, stage, work, target):
    """The ABI fixture, the `-H` paths of the main fixture and the exception defaults of the driver through the pair
    of the exe variant; and for both variants the include search list and the `-H` paths of the unwind fixture, which
    includes the public <libunwind.h> and <unwind.h> with no flag but the pair."""
    runtime, clangxx = os.path.join(stage, "runtime"), os.path.join(stage, "bin", "clang++")
    pair = pairFlags(runtime, target, "exe")
    pc.step(run, target + " ABI headers", [clangxx] + pair + [CXX_STANDARD, "-fsyntax-only",
                                                              "-DEXPECT_" + pw.TARGETS[target]["machineName"],
                                                              os.path.join(pr.FIXTURES, "windowsSourceCppAbi.cpp")])
    fixture = os.path.join(pr.FIXTURES, PROOFS["exe"]["fixture"])
    unwind = os.path.join(pr.FIXTURES, PROOFS["unwind"]["fixture"])
    for variant in pws.SOURCE_VARIANTS:
        both = pairFlags(runtime, target, variant)
        listing = pc.step(run, "%s %s include order" % (target, variant),
                          [clangxx] + both + ["-E", "-v", "-x", "c++", os.devnull], stderr=True).stderr
        problem = includeOrderProblem(pc.searchList(listing, os.path.normpath(stage)), target)
        if problem:
            raise pe.EngineError("%s %s: %s" % (target, variant, problem))
        public = pc.step(run, "%s %s public unwind headers" % (target, variant),
                         [clangxx] + both + [CXX_STANDARD, "-fsyntax-only", "-H", unwind], stderr=True).stderr
        problem = publicHeadersProblem(public, stage, target)
        if problem:
            raise pe.EngineError("%s %s: %s" % (target, variant, problem))
    headers = pc.step(run, target + " -H headers", [clangxx] + pair + [CXX_STANDARD, "-fsyntax-only", "-H", fixture],
                      stderr=True).stderr
    problem = headersProblem(headers, stage)
    if problem:
        raise pe.EngineError("%s: %s" % (target, problem))
    flags = pc.step(run, target + " exception defaults", [clangxx] + pair + ["-###", "-c", fixture, "-o",
                                                                             os.path.join(work, "flags.o")],
                    stderr=True).stderr
    cc1 = next((l.split() for l in flags.splitlines() if '"-cc1"' in l.split()), None)
    missing = [f for f in EXCEPTION_DEFAULTS if not cc1 or '"%s"' % f not in cc1]
    if missing:
        raise pe.EngineError("%s: the driver's C++ defaults lack %s" % (target, ", ".join(missing)))


def checkClient(run, stage, work, target):
    """A C client of a C++ static archive links through the pair and not through the base config alone. Returns the
    linked client."""
    runtime = os.path.join(stage, "runtime")
    clang, clangxx = os.path.join(stage, "bin", "clang"), os.path.join(stage, "bin", "clang++")
    pair, base = pairFlags(runtime, target, "exe"), baseFlags(runtime, target, "exe")
    path = lambda name: os.path.join(work, name)
    pc.step(run, target + " archive compile", [clangxx] + pair + [CXX_STANDARD, "-O2", "-c", os.path.join(
        pr.FIXTURES, "windowsSourceCppArchive.cpp"), "-o", path("archive.o")])
    pc.step(run, target + " archive", [os.path.join(stage, "bin", "llvm-ar"), "--format=gnu", "crs",
                                       path("libclient.a"), path("archive.o")])
    pc.step(run, target + " client compile", [clang] + base + ["-O2", "-c", os.path.join(
        pr.FIXTURES, "windowsSourceCppClient.c"), "-o", path("client.o")])
    pc.step(run, target + " client link", [clang] + pair + [path("client.o"), path("libclient.a"), "-o",
                                                            path("client.exe")])
    plan = pc.step(run, target + " client plan", [clang] + pair + ["-###", path("client.o"), path("libclient.a"), "-o",
                                                                   path("clientPlan.exe")], stderr=True).stderr
    problem = selectionProblem(plan, runtime, target, "exe", "client")
    if problem:
        raise pe.EngineError("%s client plan: %s" % (target, problem))
    refused = run([clang] + base + [path("client.o"), path("libclient.a"), "-o", path("clientBase.exe")])
    if refused.returncode == 0 or "undefined symbol" not in refused.stderr:
        raise pe.EngineError("%s: the C client linked or failed otherwise without the C++ config: %s" % (
            target, refused.stderr.strip()))
    return path("client.exe")


def checkTarget(run, stage, work, target, execute=False):
    """Compile and link every proof of target through its config pair plain and with thin and full LTO, check the
    plans, bitcode, PE files and the C client, and with execute run the executables the host can run. Any nonzero
    exit or stderr is an error. Returns {(proof, mode): linked file}."""
    runtime = os.path.join(stage, "runtime")
    steps, outputs, bitcode, plans = cxxSteps(stage, work, target)
    for name, command in steps:
        pc.step(run, "%s %s" % (target, name), command)
    checkCompile(run, stage, work, target)
    for name, command, proof in plans:
        plan = pc.step(run, "%s %s" % (target, name), command, stderr=True).stderr
        problem = selectionProblem(plan, runtime, target, PROOFS[proof]["variant"], "cxx")
        if problem:
            raise pe.EngineError("%s %s: %s" % (target, name, problem))
    for path in bitcode:
        with open(path, "rb") as f:
            if f.read(4) not in pws.BITCODE_MAGICS:
                raise pe.EngineError("%s: %s is not LTO bitcode" % (target, os.path.basename(path)))
    outputs[("client", "plain")] = checkClient(run, stage, work, target)
    for (name, mode), path in sorted(outputs.items()):
        proof = "dll" if name == "dll" else "exe"
        problem = peProblem(proof, pw.readPe(path), target, exceptionTableSize(path))
        if problem:
            raise pe.EngineError("%s %s %s: %s" % (target, name, mode, problem))
    if execute and not pws.canExecute(target):
        raise pe.EngineError("this host cannot run %s files" % target)
    if execute:
        expected = {"exe": EXPECTED_MAIN[target], "unwind": EXPECTED_UNWIND, "client": EXPECTED_CLIENT}
        for (name, mode), path in sorted(outputs.items()):
            if name in expected:
                pws.runOutput(path, expected[name], "%s %s %s" % (target, name, mode))
    return outputs


def controlResults(run, root, work, target, variant):
    """(include search list, object, linked file) of the C control through the base config of variant alone."""
    runtime, clang = os.path.join(root, "runtime"), os.path.join(root, "bin", "clang")
    base = baseFlags(runtime, target, variant)
    shared = ["-shared"] if variant == "dll" else []
    scratch = os.path.join(work, "control-%s-%s-%s" % (target, variant, os.path.basename(root)))
    os.makedirs(scratch)
    obj, out = os.path.join(scratch, "c.o"), os.path.join(scratch, "c.out")
    listing = pc.step(run, "C include list", [clang] + base + ["-E", "-v", "-x", "c", os.devnull], stderr=True).stderr
    pc.step(run, "C compile", [clang] + base + ["-O2", "-c", os.path.join(pr.FIXTURES, "windowsSourceCppControl.c"),
                                                "-o", obj])
    pc.step(run, "C link", [clang] + base + shared + ["-Wl,--no-insert-timestamp", obj, "-o", out])
    with open(obj, "rb") as f, open(out, "rb") as g:
        return pc.searchList(listing, os.path.normpath(root)), f.read(), g.read()


def checkControl(run, stage, control, work, target):
    """The C control through each base config is the same with the C++ overlay as without it."""
    for variant in pws.SOURCE_VARIANTS:
        results = [controlResults(run, root, work, target, variant) for root in (stage, control)]
        for name, withOverlay, without in zip(("include list", "object", "linked file"), *results):
            if withOverlay != without:
                raise pe.EngineError("%s %s: the C %s changes with the C++ overlay" % (target, variant, name))


def makeControl(stage, work, remove=()):
    """A tree beside stage whose runtime is a copy of stage's without the runtime-relative paths of remove, with
    every engine entry a symlink to stage's: the C control's tree."""
    root = os.path.join(work, "control")
    runtime = os.path.join(root, "runtime")
    os.makedirs(root)
    shutil.copytree(os.path.join(stage, "runtime"), runtime, symlinks=True)
    for relative in remove:
        path = os.path.join(runtime, *relative.split("/"))
        if os.path.lexists(path):
            os.remove(path)
    view = os.path.join(work, "control engine view")
    os.makedirs(view)
    for name in sorted(os.listdir(stage)):
        if name != "runtime":
            os.symlink(os.path.join(stage, name), os.path.join(view, name))
    pr.linkEngineBeside(view, root, runtime)
    return root


def checkRuntime(run, stage, control, work, receipt, execute=False):
    """checkControl and checkTarget for every target of receipt. Returns {(target, proof, mode): linked file}."""
    found = {}
    for target in receipt["targets"]:
        scratch = os.path.join(work, "cxx-" + target)
        os.makedirs(scratch)
        checkControl(run, stage, control, scratch, target)
        outputs = checkTarget(run, stage, scratch, target, execute and pws.canExecute(target))
        found.update({(target, name, mode): path for (name, mode), path in outputs.items()})
    return found


def hostRun(work):
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    return lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          universal_newlines=True)


def prepareWindowsSourceCppRuntime(engine, runtime, output, llvm, llvmRev, tools, python, targets=None, jobs=None):
    """Write the overlay of `targets` (every Windows target when none) to the new directory `output`, proven on a
    staged copy of the engine with the input runtime and the overlay, without running anything it links. Returns
    (output, receipt)."""
    engine, runtime, output = os.path.abspath(engine), os.path.abspath(runtime), os.path.abspath(output)
    targets = pw.selectWindowsTargets(targets)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    host, version, major = pr.engineMajor(engine)
    for name in ("clang", "clang++", "ld.lld", "llvm-ar", "llvm-ranlib", "llvm-nm"):
        pws.engineTool(engine, name)
    problem = collisionProblem(runtime, targets)
    if problem:
        raise pe.EngineError(problem)
    base = baseReceipt(runtime, targets)
    llvmRev = pws.pinnedRevisions(version, None, llvmRev)[1]
    recorded = base[0]["sources"]["llvm-project"]
    if recorded["rev"] != llvmRev or recorded["major"] != major:
        raise pe.EngineError("the C runtime was built from llvm-project %s (LLVM %s), not %s (LLVM %s)" % (
            recorded["rev"], recorded["major"], llvmRev, major))
    source = pws.checkSourceRoot(llvm, llvmRev, "llvm-project", LLVM_CPP_MARKERS)
    pws.checkLlvmVersion(source, version)
    jobs = jobs or os.cpu_count() or 1
    inputDigest = pc.treeDigest(runtime)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    work = os.path.realpath(tempfile.mkdtemp(prefix="prepareWindowsSourceCppRuntime-"))
    try:
        pws.checkPlainPath(work, "work directory")
        pws.checkPlainPath(engine, "engine")
        environment = pws.buildEnvironment(work, dict(tools, python3=python[0]))
        stage = os.path.join(work, "stage")
        pws.stageTree(engine, os.path.join(runtime, "windows"), stage, major)
        payloads = {}
        for target in targets:
            prefix = buildRuntimes(source, stage, target, work, tools, python[0], environment, jobs)
            payloads[target] = stagePayload(prefix, target, source, stage, partial)
        for target in targets:
            for variant in pws.SOURCE_VARIANTS:
                pe.writeText(os.path.join(partial, *configPath(target, variant).split("/")),
                             renderCxxConfig(target))
        notices = copyNotices(partial, source)
        receipt = writeProvenance(partial, host, version, major, targets, payloads, notices, base, source, llvmRev,
                                  tools, python)
        control = makeControl(stage, work)
        pc.mergeOverlay(partial, os.path.join(stage, "runtime"))
        checkRuntime(hostRun(work), stage, control, work, receipt)
        pws.checkSourceRoot(llvm, llvmRev, "llvm-project", LLVM_CPP_MARKERS)
        if pc.treeDigest(runtime) != inputDigest:
            raise pe.EngineError("the input runtime %s changed during the build" % runtime)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return output, receipt


def prove(engine, runtime, denied, execute=False):
    """Relocate the engine and the runtime (the C runtime with the overlay merged) to a path with a space, check the
    receipt against the files, and run checkRuntime on a copy of the engine with the overlay's `windows/` files, and
    against a control without them. On macOS the checks run in a sandbox that cannot read the originals or any --deny
    path; elsewhere --deny is refused, because nothing would enforce it, and the linked files are only scanned for the
    original paths."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    if denied and sys.platform != "darwin":
        raise pe.EngineError("--deny is enforced by the macOS sandbox only and this host has none")
    pe.verifyEngine(engine)
    receipt, _ = readJson(runtime, PROVENANCE)
    problem = receiptProblem(receipt, runtime)
    if problem:
        raise pe.EngineError(problem)
    base, _ = baseReceipt(runtime, receipt["targets"])
    major = pr.engineMajor(engine)[2]
    if receipt["sources"]["llvm-project"]["major"] != major or base["sources"]["llvm-project"]["major"] != major:
        raise pe.EngineError("the receipts are LLVM %s, the engine is LLVM %s" % (
            receipt["sources"]["llvm-project"]["major"], major))
    if execute and not any(pws.canExecute(t) for t in receipt["targets"]):
        raise pe.EngineError("--execute: this host cannot run any target of the receipt")
    work = os.path.realpath(tempfile.mkdtemp(prefix="windows-source-cpp-proof-"))
    root = os.path.join(work, "relocated tree")
    try:
        pws.stageTree(engine, os.path.join(runtime, "windows"), root, major)
        secrets = [engine, runtime] + [os.path.realpath(p) for p in denied]
        if sys.platform == "darwin":
            profile = os.path.join(work, "deny.sb")
            pe.writeText(profile, "(version 1)(allow default)" + "".join(
                '(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (p, p) for p in secrets) + "\n")
            if pr.sandboxed(profile, work, [os.path.join(engine, "bin", "clang"), "--version"]).returncode == 0:
                raise pe.EngineError("sandbox does not deny the original engine")
            run = lambda command: pr.sandboxed(profile, work, command)
        else:
            run = hostRun(work)
        control = makeControl(root, work, [r["path"] for r in receipt["files"] if r["path"].startswith("windows/")])
        outputs = checkRuntime(run, root, control, work, receipt, execute)
        for (target, name, mode), path in sorted(outputs.items()):
            with open(path, "rb") as f:
                data = f.read()
            leaked = [p for p in secrets if p.encode("utf-8") in data]
            if leaked:
                raise pe.EngineError("%s output %s %s holds source paths %s" % (target, name, mode, leaked))
        for target in receipt["targets"]:
            print("%s: %d linked files checked; %s" % (target, sum(1 for k in outputs if k[0] == target),
                  "executables run" if execute and pws.canExecute(target) else "not run"))
        print("relocated=%s sandbox=%s" % (root, "macos" if sys.platform == "darwin" else "none"))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--output")
    parser.add_argument("--llvm-project")
    parser.add_argument("--llvm-project-rev")
    parser.add_argument("--make")
    parser.add_argument("--cmake")
    parser.add_argument("--ninja")
    parser.add_argument("--python3")
    parser.add_argument("--jobs", type=int)
    parser.add_argument("--target", action="append", default=[], help="a Windows target; every target when none")
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--execute", action="store_true", help="with --prove only: run the executables the host can run")
    parser.add_argument("--prove", action="store_true")
    args = parser.parse_args(argv)
    buildOnly = ("output", "llvm_project", "llvm_project_rev", "make", "cmake", "ninja", "python3", "jobs", "target")
    proveOnly = ("deny", "execute")
    try:
        if args.prove:
            given = [n for n in buildOnly if getattr(args, n) not in (None, [])]
            if given:
                parser.error("%s go with the build, not --prove" % ", ".join("--" + n.replace("_", "-") for n in given))
            prove(args.engine, args.runtime, args.deny, args.execute)
        else:
            given = [n for n in proveOnly if getattr(args, n)]
            if given:
                parser.error("%s only go with --prove: the build runs nothing it links" % ", ".join(
                    "--" + n for n in given))
            missing = [n for n in ("output", "llvm_project") if not getattr(args, n)]
            if missing:
                parser.error("%s required" % ", ".join("--" + n.replace("_", "-") for n in missing))
            tools = pws.resolveTools(None, args.make, args.cmake, args.ninja)
            output, receipt = prepareWindowsSourceCppRuntime(
                args.engine, args.runtime, args.output, args.llvm_project, args.llvm_project_rev, tools,
                resolvePython(args.python3), targets=args.target, jobs=args.jobs)
            print("%d files, %d variants proven" % (len(receipt["files"]) + 1, len(receipt["variants"])))
            print("overlay written to %s" % output)
    except pe.EngineError as error:
        print("prepareWindowsSourceCppRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
