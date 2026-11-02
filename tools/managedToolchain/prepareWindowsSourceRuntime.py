#!/usr/bin/env python3
"""Prepare the x86_64-windows-gnu and aarch64-windows-gnu runtimes from mingw-w64 and LLVM sources with the prepared engine, then prove them.

    prepareWindowsSourceRuntime.py --engine ENGINE_DIR --output NEW_RUNTIME_DIR
        --mingw-w64 DIR [--mingw-w64-rev SHA] --llvm-project DIR [--llvm-project-rev SHA]
        [--target T ...] [--sh SH] [--make MAKE] [--cmake CMAKE] [--ninja NINJA] [--jobs N]
    prepareWindowsSourceRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--deny PATH ...] [--execute]
    installResource(WINDOWS_DIR, ENGINE_DIR/lib/clang/MAJOR)    from a bundle assembly, see below

This is the producer of the same `windows/` directory prepareWindowsRuntime.py makes from a Zig, with no Zig and no
prebuilt host library in it: the C runtime startup objects, the import libraries and libmingwex come from mingw-w64's
own configure and make, the builtins from LLVM's compiler-rt, the threads from winpthreads. Nothing is downloaded
and nothing is taken from HEAD: both source roots are explicit git checkouts that must be clean and sit exactly at
the given commit, before and after the build, and the compiler-rt checkout must be the engine's exact LLVM version.
Without --mingw-w64-rev the pin of MINGW_W64_PIN is used, and without --llvm-project-rev the commit of LLVM_PINS for the
engine's version; an engine version with no entry needs the explicit revision. HEAD is never a default.

For each target, in a private work directory and always out of tree:

    mingw-w64-headers   configure --enable-idl --with-default-win32-winnt=0x0A00 --with-default-msvcrt=ucrt; make install
    mingw-w64-crt       configure --host=<arch>-w64-mingw32 --with-default-msvcrt=ucrt; make; make install, with the
                        engine's clang, llvm-ar, llvm-ranlib and llvm-dlltool (crt1/2.o, dllcrt1/2.o, crt2u.o,
                        libmingw32, libmingwex, libmoldname, the UCRT as libmsvcrt, every import library)
    compiler-rt         cmake on compiler-rt/lib/builtins for the Windows target, installed as
                        libclang_rt.builtins-<arch>.a
    winpthreads         configure --disable-shared --enable-static; make; make install, including version.rc with
                        the engine's llvm-rc in windres mode and clang as its explicit target preprocessor;
                        libwinpthread.a and the install's libpthread.a alias

The variants are an executable and a DLL, with the configs named as prepareWindowsRuntime.py names them:

    windows/<target>.cfg   windows/<target>.dll.cfg

A config leaves the C runtime to clang's own MinGW driver: no -nostdlib, no startup object and no `-l` line in it.
The driver picks crt2.o, crt2u.o (-municode) or dllcrt2.o (-shared) with crtbegin.o and crtend.o, adds the sanitizer
imports and the `-l` tail of mingw32, builtins, moldname, mingwex, msvcrt and the system import libraries, and
reads libpthread for -pthread. The config only points it at the files: `--sysroot` (which also stops it from
looking for a GCC), `-B` (where the driver looks for the startup objects, which sit flat in the variant directory
beside the archives) and `-L`, with `--rtlib=compiler-rt` and `--unwindlib=none` so a C link needs no libgcc.
The configs carry no CPU feature and no define: the headers are configured for Windows 10 and the UCRT, and the
proof compiles an ABI fixture that fails when they are not.

The builtins are not in the variant directories: the driver reads them from the resource directory of the compiler,
lib/clang/<major>/lib/windows/libclang_rt.builtins-<arch>.a. They are staged at `windows/resource/lib/windows/` and
listed with their hashes and machine in the receipt (`resourceFiles`). A bundle assembly installs them with
`installResource(windows, <engine>/lib/clang/<major>)`, which refuses a changed file, a wrong machine, a file the
resource directory already holds with other bytes and a builtins library at lib/<target triple>, which the driver
would read first. The proof installs them into a copy of the engine, never into
the engine it was given.

Fail loud: an unpinned or dirty source root, a missing tool, a build that exits nonzero, an installed file whose COFF
machine is not the target's, a missing startup object, crtbegin.o, crtend.o, import library or archive the driver
reads, a header that two sources both install with different bytes, and any compile or link warning are errors. The
proof links every variant with and without thin and full LTO, linking a nonconstant hello and nan, nanl, isnan, pow,
fmod program (and a wmain one with -municode), checks from clang's own `-###` plan that the driver chose the startup
objects, the tail and the builtins of the directory and the resource directory, checks the PE headers and the UCRT
imports. The stack executable and DLL proofs compile and link with -fstack-protector-strong, so the driver adds libssp and
libssp_nonshared: mingw-w64 builds the protector's helpers into libmingwex and installs neither archive, so the
build makes both as empty archives unless the CRT install holds the pair. The build runs none of the proofs: a POSIX
host builds and links, and `--prove --execute` on a Windows host (x86_64 files on an x86_64 or ARM64 one, ARM64 files
on an ARM64 one) runs the executables from the finished runtime. The build itself is not supported on Windows: its
configure and make paths are POSIX paths.

The payload is a local proof from pinned upstream sources; its provenance receipt says so and never certifies
redistribution.
"""
import argparse
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile

import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw

PROVENANCE = pw.PROVENANCE
RECEIPT_KIND = "source-built-windows-runtime"
ENGINE_RELATIVE = pw.ENGINE_RELATIVE
WINNT = "0x0A00"
HEADER_DIRECTORY = "mingw-w64"
BUILD_TIMEOUT_SECONDS = 3600
RUN_TIMEOUT_SECONDS = 60
STACK_BYTES = 16777216
SHA1 = re.compile(r"^[0-9a-f]{40}$")
PLAIN_PATH = re.compile(r"^[A-Za-z0-9_./+-]+$")
VERSION_LINES = [re.compile(r"set\(LLVM_VERSION_%s (\d+)\)" % part) for part in ("MAJOR", "MINOR", "PATCH")]
MINGW_W64_PIN = "0d6dfbc348dfad714761c0a7151615767f96bcb5"
LLVM_PINS = {"22.1.1": "fef02d48c08db859ef83f84232ed78bd9d1c323a",
             "23.1.0": "ea7d852a70e8bdfaf601d6626a760f9771b2c4b4"}
BITCODE_MAGICS = (b"BC\xc0\xde", b"\xde\xc0\x17\x0b")
SYSTEM_LIBRARIES = ["advapi32", "shell32", "user32", "kernel32"]
SSP_LIBRARIES = ["ssp", "ssp_nonshared"]
SSP_ARCHIVES = ["lib%s.a" % stem for stem in SSP_LIBRARIES]
STACK_PROTECTOR = "-fstack-protector-strong"
STACK_FAIL_SYMBOL = "__stack_chk_fail"
RESOURCE_DIRECTORY = "resource"
RESOURCE_LIBRARY = "lib/windows"
STARTUP_OBJECTS = ["crt2.o", "crt2u.o", "dllcrt2.o"]
REQUIRED_OBJECTS = STARTUP_OBJECTS + ["crtbegin.o", "crtend.o"]
REQUIRED_LIBRARIES = ["mingw32", "moldname", "mingwex", "msvcrt", "winpthread", "pthread", "synchronization"] + SSP_LIBRARIES \
    + SYSTEM_LIBRARIES
EXPECTED_MATH = "hello windows-source\nmath pow=1024 fmod=2 nan=1 nanl=1 isnan=1\n"
EXPECTED_WIDE = "wide argc=1 first=1 pow=1024 nan=1\n"
EXPECTED_STACK = "stack sum=45\n"
MINGW_MARKERS = ("mingw-w64-headers/configure", "mingw-w64-crt/configure",
                 "mingw-w64-libraries/winpthreads/configure", "COPYING")
LLVM_MARKERS = ("compiler-rt/lib/builtins/CMakeLists.txt", "cmake/Modules/LLVMVersion.cmake",
                "compiler-rt/LICENSE.TXT")
NOTICES = {"mingw-w64": ("mingw", ["COPYING", "COPYING.MinGW-w64/COPYING.MinGW-w64.txt",
                                    "COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt", "DISCLAIMER",
                                    "DISCLAIMER.PD"]),
           "winpthreads": ("mingw", ["mingw-w64-libraries/winpthreads/COPYING"]),
           "compiler-rt": ("llvm", ["compiler-rt/LICENSE.TXT"])}
LIMITS = ["the preparation runs no Windows binary and cannot run on Windows: --prove --execute on a Windows host runs "
          "the x86_64 executables, and the aarch64 ones only on an aarch64 Windows host; a DLL is linked and "
          "inspected, never loaded",
          "compiler-rt is the builtins library alone: no sanitizer, profile or fuzzer runtime",
          "libc++, libc++abi and libunwind are not built here, so the C++ overlay of prepareCppRuntime.py is not "
          "carried by this runtime",
          "no archive is normalized: the files are as mingw-w64's make and llvm-ar wrote them, and a path of "
          "the private work directory can remain in them if a source file embeds it",
          "libssp.a and libssp_nonshared.a, which the driver adds under a stack protector flag, are empty archives "
          "when the CRT install holds none: mingw-w64 builds the protector's helpers into libmingwex"]

SOURCE_TARGETS = {
    pw.TARGET: {"host": "x86_64-w64-mingw32", "clangTarget": "x86_64-w64-windows-gnu", "cpu": "x86-64",
                "crtFlags": ["--disable-lib32", "--enable-lib64"], "builtins": "x86_64"},
    pw.ARM64_TARGET: {"host": "aarch64-w64-mingw32", "clangTarget": "aarch64-w64-windows-gnu", "cpu": "generic",
                      "crtFlags": ["--disable-lib32", "--disable-lib64", "--enable-libarm64"], "builtins": "aarch64"},
}
DRIVER_FLAGS = ["--rtlib=compiler-rt", "--unwindlib=none"]
SOURCE_VARIANTS = {
    "exe": {"startup": "crt2.o", "driverFlags": [], "suffix": "", "stack": STACK_BYTES, "imageBase": 0x140000000},
    "dll": {"startup": "dllcrt2.o", "driverFlags": ["-shared"], "suffix": ".dll", "stack": None,
            "imageBase": 0x180000000},
}
PROOFS = {
    "exe": {"variant": "exe", "compileFlags": [], "flags": [], "startup": "crt2.o", "fixture": "windowsSourceMath.c",
            "runs": EXPECTED_MATH},
    "dll": {"variant": "dll", "compileFlags": [], "flags": [], "startup": "dllcrt2.o",
            "fixture": "windowsSourceMathDll.c", "runs": None, "export": "mathProbe"},
    "wide": {"variant": "exe", "compileFlags": [], "flags": ["-municode"], "startup": "crt2u.o",
             "fixture": "windowsSourceWide.c", "runs": EXPECTED_WIDE},
    "stack": {"variant": "exe", "compileFlags": [STACK_PROTECTOR], "flags": [STACK_PROTECTOR], "startup": "crt2.o",
              "fixture": "windowsSourceStack.c", "runs": EXPECTED_STACK},
    "stackdll": {"variant": "dll", "compileFlags": [STACK_PROTECTOR], "flags": [STACK_PROTECTOR], "startup": "dllcrt2.o",
                 "fixture": "windowsSourceStackDll.c", "runs": None, "export": "stackSum"},
}
LTO_MODES = (("plain", []), ("thin", ["-flto=thin"]), ("full", ["-flto=full"]))


def variantDirectory(target, variant):
    return target + SOURCE_VARIANTS[variant]["suffix"]


def variantConfig(target, variant):
    return variantDirectory(target, variant) + ".cfg"


def checkPlainPath(path, what):
    """A path that goes through a configure or CMake command line unquoted."""
    if not PLAIN_PATH.match(path):
        raise pe.EngineError("%s %s has a character that would need quoting" % (what, path))
    return path


def checkSourceRoot(root, rev, what, markers):
    """The real path of a git checkout at exactly rev with no change and no untracked file, holding markers."""
    if not SHA1.match(rev or ""):
        raise pe.EngineError("%s revision %r is not a full lowercase commit hash" % (what, rev))
    root = os.path.realpath(root)
    missing = [m for m in markers if not os.path.isfile(os.path.join(root, m))]
    if missing:
        raise pe.EngineError("%s %s lacks %s" % (what, root, ", ".join(missing)))
    head = pe.run(["git", "-C", root, "rev-parse", "HEAD"]).strip()
    if head != rev:
        raise pe.EngineError("%s %s is at %s, not the pinned %s" % (what, root, head, rev))
    if pe.run(["git", "-C", root, "status", "--porcelain", "--untracked-files=all"]).strip():
        raise pe.EngineError("%s %s has uncommitted or untracked files" % (what, root))
    return root


def checkLlvmVersion(llvm, version):
    """The checkout's LLVM version must be the engine's, major, minor and patch: the builtins are the compiler's own."""
    with open(os.path.join(llvm, "cmake", "Modules", "LLVMVersion.cmake"), encoding="utf-8") as f:
        text = f.read()
    found = [pattern.search(text) for pattern in VERSION_LINES]
    if not all(found):
        raise pe.EngineError("%s names no LLVM_VERSION_MAJOR, MINOR and PATCH" % llvm)
    checkout = ".".join(m.group(1) for m in found)
    if checkout != version:
        raise pe.EngineError("llvm-project %s is LLVM %s, the engine is LLVM %s" % (llvm, checkout, version))


def pinnedRevisions(version, mingwRev=None, llvmRev=None):
    """(mingw-w64 commit, llvm-project commit): the explicit ones, else the pins. No pin for the engine's version and
    no explicit commit is an error, never a branch head."""
    llvmRev = llvmRev or LLVM_PINS.get(version)
    if not llvmRev:
        raise pe.EngineError("no llvm-project pin for engine LLVM %s (pinned: %s); pass --llvm-project-rev" % (
            version, ", ".join(sorted(LLVM_PINS))))
    return mingwRev or MINGW_W64_PIN, llvmRev


def engineTool(engine, name):
    path = os.path.join(engine, "bin", name)
    for candidate in (path, path + ".exe"):
        if os.path.isfile(candidate):
            return path
    raise pe.EngineError("engine %s has no %s" % (engine, name))


def resolveTools(sh=None, make=None, cmake=None, ninja=None):
    """{name: path} of the host tools the upstream recipes need: a POSIX sh, GNU make and CMake; Ninja when found."""
    found = {"sh": sh or shutil.which("sh"), "make": make or shutil.which("gmake") or shutil.which("make"),
             "cmake": cmake or shutil.which("cmake"), "ninja": ninja or shutil.which("ninja")}
    missing = [n for n in ("sh", "make", "cmake") if not found[n]]
    if missing:
        raise pe.EngineError("the host has no %s; pass --%s" % (", ".join(missing), missing[0]))
    if "GNU Make" not in pe.run([found["make"], "--version"]):
        raise pe.EngineError("%s is not GNU make" % found["make"])
    return {name: os.path.abspath(path) for name, path in found.items() if path}


def toolVersions(tools):
    return {name: pe.run([tools[name], "--version"]).splitlines()[0] for name in ("make", "cmake", "ninja")
            if name in tools}


def buildEnvironment(work, tools):
    directories = [os.path.dirname(path) for path in tools.values()] + ["/usr/bin", "/bin"]
    environment = {"PATH": os.pathsep.join(dict.fromkeys(directories)), "HOME": work, "TMPDIR": work, "LC_ALL": "C"}
    if sys.platform == "win32":
        environment.update({"SystemRoot": os.environ["SystemRoot"], "TEMP": work, "TMP": work})
    return environment


def runBuild(command, cwd, environment, log):
    """Run one build command with its output in log; a nonzero exit or a timeout is an error holding the log's tail."""
    try:
        with open(log, "w", encoding="utf-8") as out:
            done = subprocess.run(command, cwd=cwd, env=environment, stdout=out, stderr=subprocess.STDOUT,
                                  universal_newlines=True, timeout=BUILD_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise pe.EngineError("%s timed out after %d s" % (" ".join(command[:3]), BUILD_TIMEOUT_SECONDS))
    if done.returncode != 0:
        with open(log, encoding="utf-8", errors="replace") as f:
            tail = "".join(f.readlines()[-40:])
        raise pe.EngineError("%s failed (%d):\n%s" % (" ".join(command[:3]), done.returncode, tail))


def compilerFlags(engine, major, spec, headers):
    """The words after the clang path that make it compile for the target against the engine's builtin headers and
    the installed mingw-w64 headers alone, whatever configuration or system the host has."""
    return ["--no-default-config", "--target=" + spec["clangTarget"], "-nostdinc",
            "-isystem", os.path.join(engine, "lib", "clang", major, "include"), "-isystem", headers]


def buildHeaders(mingw, work, tools, environment):
    """configure and install mingw-w64-headers once; returns the installed include directory."""
    build, prefix = os.path.join(work, "headers-build"), os.path.join(work, "headers")
    os.makedirs(build)
    runBuild([tools["sh"], os.path.join(mingw, "mingw-w64-headers", "configure"), "--prefix=" + prefix,
              "--enable-idl", "--with-default-win32-winnt=" + WINNT, "--with-default-msvcrt=ucrt"],
             build, environment, os.path.join(work, "headers-configure.log"))
    runBuild([tools["make"], "install"], build, environment, os.path.join(work, "headers-install.log"))
    include = os.path.join(prefix, "include")
    if not os.path.isfile(os.path.join(include, "_mingw.h")):
        raise pe.EngineError("the headers install has no %s" % os.path.join(include, "_mingw.h"))
    return include


def findInstalledDirectory(prefix, marker):
    found = [directory for directory, _, files in os.walk(prefix) if marker in files]
    if len(found) != 1:
        raise pe.EngineError("%s holds %s in %d directories, not one" % (prefix, marker, len(found)))
    return found[0]


def buildCrt(mingw, engine, major, headers, target, work, tools, environment, jobs):
    """mingw-w64-crt's configure and make for the target; returns the directory its make installed the files in."""
    spec = SOURCE_TARGETS[target]
    build, prefix = os.path.join(work, target + "-crt-build"), os.path.join(work, target + "-crt")
    os.makedirs(build)
    words = compilerFlags(engine, major, spec, headers)
    cc = " ".join([engineTool(engine, "clang")] + words)
    cxx = " ".join([engineTool(engine, "clang++")] + words)
    runBuild([tools["sh"], os.path.join(mingw, "mingw-w64-crt", "configure"), "--host=" + spec["host"],
              "--prefix=" + prefix] + spec["crtFlags"] + [
                  "--with-default-msvcrt=ucrt", "--enable-silent-rules", "CC=" + cc, "CXX=" + cxx,
                  "AR=" + engineTool(engine, "llvm-ar") + " --format=gnu", "RANLIB=" + engineTool(engine, "llvm-ranlib"),
                  "DLLTOOL=" + engineTool(engine, "llvm-dlltool"), "CFLAGS=-O2"],
             build, environment, os.path.join(work, target + "-crt-configure.log"))
    runBuild([tools["make"], "-j%d" % jobs], build, environment, os.path.join(work, target + "-crt-make.log"))
    runBuild([tools["make"], "install"], build, environment, os.path.join(work, target + "-crt-install.log"))
    return findInstalledDirectory(prefix, "crt2.o")


def buildCompilerRt(llvm, engine, major, headers, target, work, tools, environment, jobs):
    """compiler-rt's builtins for the target through CMake; returns the installed libclang_rt.builtins-<arch>.a."""
    spec = SOURCE_TARGETS[target]
    build, prefix = os.path.join(work, target + "-rt-build"), os.path.join(work, target + "-rt")
    clang, clangxx = engineTool(engine, "clang"), engineTool(engine, "clang++")
    cflags = " ".join(compilerFlags(engine, major, spec, headers))
    triple = spec["clangTarget"]
    command = [tools["cmake"], "-S", os.path.join(llvm, "compiler-rt", "lib", "builtins"), "-B", build,
               "-G", "Ninja" if "ninja" in tools else "Unix Makefiles"]
    if "ninja" in tools:
        command.append("-DCMAKE_MAKE_PROGRAM=" + tools["ninja"])
    command += ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" + prefix, "-DCMAKE_SYSTEM_NAME=Windows",
                "-DCMAKE_C_COMPILER=" + clang, "-DCMAKE_CXX_COMPILER=" + clangxx, "-DCMAKE_ASM_COMPILER=" + clang,
                "-DCMAKE_AR=" + engineTool(engine, "llvm-ar"), "-DCMAKE_RANLIB=" + engineTool(engine, "llvm-ranlib"),
                "-DCMAKE_C_COMPILER_WORKS=1", "-DCMAKE_CXX_COMPILER_WORKS=1", "-DCMAKE_ASM_COMPILER_WORKS=1",
                "-DCMAKE_C_COMPILER_TARGET=" + triple, "-DCMAKE_CXX_COMPILER_TARGET=" + triple,
                "-DCMAKE_ASM_COMPILER_TARGET=" + triple,
                "-DCMAKE_C_FLAGS_INIT=" + cflags, "-DCMAKE_CXX_FLAGS_INIT=" + cflags,
                "-DCMAKE_ASM_FLAGS_INIT=--no-default-config",
                "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=TRUE", "-DCOMPILER_RT_USE_BUILTINS_LIBRARY=TRUE",
                "-DCOMPILER_RT_BUILD_BUILTINS=TRUE", "-DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=FALSE",
                "-DLLVM_CONFIG_PATH="]
    runBuild(command, work, environment, os.path.join(work, target + "-rt-configure.log"))
    runBuild([tools["cmake"], "--build", build, "-j", str(jobs)], work, environment,
             os.path.join(work, target + "-rt-build.log"))
    runBuild([tools["cmake"], "--install", build, "--prefix", prefix], work, environment,
             os.path.join(work, target + "-rt-install.log"))
    library = os.path.join(prefix, "lib", "windows", builtinsName(target))
    if not os.path.isfile(library):
        raise pe.EngineError("compiler-rt did not install %s" % library)
    return library


def builtinsName(target):
    return "libclang_rt.builtins-%s.a" % SOURCE_TARGETS[target]["builtins"]


def resourcePath(target):
    """Where the driver reads the builtins of target, relative to the lib/clang/<major> directory of the compiler."""
    return RESOURCE_LIBRARY + "/" + builtinsName(target)


def buildWinpthreads(mingw, engine, major, headers, target, work, tools, environment, jobs):
    """Configure, build and install the complete upstream static library and its pthread alias."""
    spec = SOURCE_TARGETS[target]
    root = os.path.join(mingw, "mingw-w64-libraries", "winpthreads")
    build, prefix = os.path.join(work, target + "-winpthreads-build"), os.path.join(work, target + "-winpthreads")
    os.makedirs(build)
    windres = os.path.join(build, spec["host"] + "-windres")
    os.symlink(os.path.realpath(engineTool(engine, "llvm-rc")), windres)
    flags = compilerFlags(engine, major, spec, headers)
    cc = " ".join([engineTool(engine, "clang")] + flags + ["--ld-path=" + engineTool(engine, "ld.lld")]
                  + DRIVER_FLAGS)
    rcflags = ["--preprocessor=" + engineTool(engine, "clang")]
    rcflags += ["--preprocessor-arg=" + flag for flag in flags + ["-E", "-xc", "-DRC_INVOKED"]]
    runBuild([tools["sh"], os.path.join(root, "configure"), "--host=" + spec["host"], "--prefix=" + prefix,
              "--disable-shared", "--enable-static", "CC=" + cc,
              "AR=" + engineTool(engine, "llvm-ar") + " --format=gnu", "RANLIB=" + engineTool(engine, "llvm-ranlib"),
              "DLLTOOL=" + engineTool(engine, "llvm-dlltool"), "RC=" + windres, "RCFLAGS=" + " ".join(rcflags),
              "CFLAGS=-O2"], build, environment, os.path.join(work, target + "-winpthreads-configure.log"))
    runBuild([tools["make"], "-j%d" % jobs], build, environment, os.path.join(work, target + "-winpthreads-make.log"))
    runBuild([tools["make"], "install"], build, environment, os.path.join(work, target + "-winpthreads-install.log"))
    libraries = findInstalledDirectory(prefix, "libwinpthread.a")
    paths = [os.path.join(libraries, name) for name in ("libwinpthread.a", "libpthread.a")]
    if any(pe.isLinkLike(path) or not os.path.isfile(path) for path in paths) or pe.sha256File(paths[0]) != pe.sha256File(paths[1]):
        raise pe.EngineError("%s: the installed pthread alias is missing, linked or differs from libwinpthread.a" % target)
    return paths


def objectMachine(data):
    """The COFF machine of an object file or of an import library member."""
    if len(data) < 8:
        raise pe.EngineError("a COFF member is %d bytes" % len(data))
    first, second = struct.unpack_from("<HH", data, 0)
    return struct.unpack_from("<H", data, 6)[0] if (first, second) == (0, 0xFFFF) else first


def machineProblem(path, machine):
    """Why path, an object or an archive, holds a member that is not for machine, or None."""
    with open(path, "rb") as f:
        data = f.read()
    if os.path.basename(path).endswith(".o"):
        members = [(os.path.basename(path), data)]
    else:
        members = pr.parseArchive(data)
    for name, body in members:
        found = objectMachine(body)
        if found != machine:
            return "%s member %s has machine %#x, not %#x" % (os.path.basename(path), name, found, machine)
    return None


def provideSspArchives(engine, libraries):
    """Leave libssp.a and libssp_nonshared.a in the CRT install, which the driver reads under any stack protector flag.
    mingw-w64 installs neither, so each is made as an empty archive; an installed pair stays as it is. Only one of the
    two, or a name that is not a regular file, is an error, and nothing is overwritten. Returns the records of the
    archives made."""
    present = [name for name in SSP_ARCHIVES if os.path.lexists(os.path.join(libraries, name))]
    if not present:
        return pr.createEmptyArchives(engine, libraries, SSP_ARCHIVES)
    if len(present) != len(SSP_ARCHIVES):
        raise pe.EngineError("%s holds %s but not %s; the pair is never completed or replaced" % (
            libraries, ", ".join(present), ", ".join(n for n in SSP_ARCHIVES if n not in present)))
    for name in present:
        path = os.path.join(libraries, name)
        if pe.isLinkLike(path) or not os.path.isfile(path):
            raise pe.EngineError("%s is not a regular file" % path)
    return []


def collectFiles(libraries, threads):
    """{name: path} of every `.a` and `.o` the CRT install and winpthreads made, and the names of the other files of
    the CRT install. A name two of them share is an error."""
    files, leftOut = {}, []
    for name in sorted(os.listdir(libraries)):
        path = os.path.join(libraries, name)
        if os.path.isfile(path) and name.endswith((".a", ".o")):
            files[pr.checkName(name)] = path
        else:
            leftOut.append(name)
    for path in threads:
        name = pr.checkName(os.path.basename(path))
        if name in files:
            raise pe.EngineError("%s is made twice" % name)
        files[name] = path
    return files, leftOut


def checkTargetFiles(files, target):
    """Every file the MinGW driver reads from a variant directory present, and every member of the target's machine."""
    required = REQUIRED_OBJECTS + ["lib%s.a" % stem for stem in REQUIRED_LIBRARIES]
    missing = sorted({name for name in required if name not in files})
    if missing:
        raise pe.EngineError("%s: the runtime lacks %s" % (target, ", ".join(missing)))
    machine = pw.TARGETS[target]["machine"]
    for name in sorted(files):
        problem = machineProblem(files[name], machine)
        if problem:
            raise pe.EngineError("%s: %s" % (target, problem))


def linkedComponent(root, relative):
    """The first of root and the components of the `/`-separated relative path below it that exists and is a symlink,
    junction or other reparse point, or None. Stops at the first component that does not exist."""
    path = root
    for part in [""] + relative.split("/"):
        path = os.path.join(path, part) if part else path
        if not os.path.lexists(path):
            return None
        if pe.isLinkLike(path):
            return path
    return None


def builtinsProblem(path, machine):
    """Why path is not an archive of at least one object member of machine, or None. An empty archive and an archive of
    import members only are not builtins."""
    problem = machineProblem(path, machine)
    if problem:
        return problem
    with open(path, "rb") as f:
        members = pr.parseArchive(f.read())
    if not members:
        return "%s holds no member" % os.path.basename(path)
    for name, body in members:
        if struct.unpack_from("<HH", body, 0) == (0, 0xFFFF):
            return "%s member %s is an import member, not an object" % (os.path.basename(path), name)
    return None


def resourceRecordsProblem(receipt):
    """Why the receipt's resourceFiles are not exactly one record of the canonical resource path per receipt target,
    or None. Nothing is opened."""
    records, targets = receipt.get("resourceFiles"), receipt["targets"]
    if not isinstance(records, list) or not records:
        return "receipt lists no resource file"
    seen = []
    for record in records:
        if not isinstance(record, dict) or record.get("target") not in targets:
            return "resource record %r is not of a receipt target (%s)" % (record, ", ".join(targets))
        if record.get("path") != resourcePath(record["target"]):
            return "resource file %s of %s is not %s" % (record.get("path"), record["target"],
                                                         resourcePath(record["target"]))
        if not isinstance(record.get("sha256"), str):
            return "resource record of %s has no sha256" % record["target"]
        seen.append(record["target"])
    if len(set(seen)) != len(seen):
        return "resource files name %s more than once" % ", ".join(sorted(t for t in set(seen) if seen.count(t) > 1))
    if set(seen) != set(targets):
        return "resource files lack %s" % ", ".join(sorted(set(targets) - set(seen)))
    return None


def stageBuiltins(builtins, target, output):
    """Copy the built libclang_rt.builtins-<arch>.a of target to output/resource/lib/windows after checking that it is
    an archive of object members of the target's COFF machine. Returns its receipt record."""
    machine = pw.TARGETS[target]["machine"]
    if os.path.lexists(builtins) and pe.isLinkLike(builtins):
        raise pe.EngineError("%s: %s is a link" % (target, builtins))
    problem = builtinsProblem(builtins, machine)
    if problem:
        raise pe.EngineError("%s: %s" % (target, problem))
    copy = os.path.join(output, RESOURCE_DIRECTORY, *resourcePath(target).split("/"))
    os.makedirs(os.path.dirname(copy), exist_ok=True)
    if os.path.lexists(copy):
        raise pe.EngineError("%s is staged twice" % builtinsName(target))
    shutil.copyfile(builtins, copy)
    os.chmod(copy, 0o644)
    return {"target": target, "path": resourcePath(target),
            "machine": "0x%x" % machine, "sha256": pe.sha256File(copy), "bytes": os.path.getsize(copy)}


def installResource(windows, resourceRoot):
    """Install the source-built compiler-rt files of the runtime in windows into resourceRoot, the lib/clang/<major>
    directory of the engine that will link with it. Each file is read from windows/resource at the path the receipt
    gives, which must be the builtins name of its target, and is checked against the receipt's hash and machine
    before any is copied. A file already in resourceRoot is left alone if it has the same bytes and refused if not,
    and so is a builtins library at lib/<target triple>, which the driver reads before the one at lib/windows.
    Returns the relative paths of the files now in resourceRoot."""
    linked = linkedComponent(windows, "notices/" + PROVENANCE)
    if linked:
        raise pe.EngineError("%s is a link" % linked)
    with open(os.path.join(windows, "notices", PROVENANCE), encoding="utf-8") as f:
        receipt = json.load(f)
    problem = receiptProblem(receipt, windows)
    if problem:
        raise pe.EngineError(problem)
    copies = []
    for record in receipt["resourceFiles"]:
        source = os.path.join(windows, RESOURCE_DIRECTORY, *record["path"].split("/"))
        problem = builtinsProblem(source, pw.TARGETS[record["target"]]["machine"])
        if problem:
            raise pe.EngineError(problem)
        shadow = "lib/%s/libclang_rt.builtins.a" % SOURCE_TARGETS[record["target"]]["clangTarget"]
        for relative in (shadow, record["path"]):
            linked = linkedComponent(resourceRoot, relative)
            if linked:
                raise pe.EngineError("%s is a link" % linked)
        if os.path.lexists(os.path.join(resourceRoot, *shadow.split("/"))):
            raise pe.EngineError("%s would be linked instead of %s" % (shadow, record["path"]))
        destination = os.path.join(resourceRoot, *record["path"].split("/"))
        if os.path.lexists(destination):
            if not os.path.isfile(destination) or pe.sha256File(destination) != record["sha256"]:
                raise pe.EngineError("%s already exists with other contents" % destination)
        else:
            copies.append((source, destination, record["sha256"]))
    for source, destination, digest in copies:
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copyfile(source, destination)
        os.chmod(destination, 0o644)
        if pe.sha256File(destination) != digest:
            raise pe.EngineError("%s was written with other contents than the receipt's" % destination)
    return [record["path"] for record in receipt["resourceFiles"]]


def copyFiles(files, output, directory):
    """Copy files into output/directory. Returns [{"name", "sha256", "bytes"}]."""
    os.makedirs(os.path.join(output, directory))
    records = []
    for name in sorted(files):
        copy = os.path.join(output, directory, name)
        shutil.copyfile(files[name], copy)
        os.chmod(copy, 0o644)
        records.append({"name": name, "sha256": pe.sha256File(copy), "bytes": os.path.getsize(copy)})
    return records


def renderSourceConfig(target, variant, directories, major):
    """Text of RUNTIME/<config>: the common head of prepareRuntime.renderConfig with the driver's own policy, then
    where the driver finds the startup objects and archives of the variant directory."""
    spec, directory = SOURCE_VARIANTS[variant], variantDirectory(target, variant)
    compile_ = {"target": SOURCE_TARGETS[target]["clangTarget"], "cpu": SOURCE_TARGETS[target]["cpu"],
                "features": [], "pic": None, "defines": []}
    driver = {"clangTarget": None, "linker": "ld.lld", "driverFlags": DRIVER_FLAGS + spec["driverFlags"]}
    text = pr.renderConfig(directory, driver, compile_, [], directories, ENGINE_RELATIVE, major)
    lines = [pr.configLine(["-resource-dir", "<CFGDIR>/%s/lib/clang/%s" % (ENGINE_RELATIVE, major)]),
             pr.configLine(["--sysroot=<CFGDIR>/" + directory]), pr.configLine(["-B<CFGDIR>/" + directory]),
             pr.configLine(["-Xlinker", "--error-limit=0"])]
    if spec["stack"] is not None:
        lines.append(pr.configLine(["-Xlinker", "--stack=%d" % spec["stack"]]))
    lines.append(pr.configLine(["-Xlinker", "--image-base=0x%x" % spec["imageBase"]]))
    lines.append(pr.configLine(["-Xlinker", "--build-id=none"]))
    return text + "\n".join(lines) + "\n"


def copyHeaders(include, threadHeaders, output):
    """Install the headers once as include/libc/mingw-w64: mingw-w64's, then winpthreads' (pthread.h and friends),
    which must not replace a mingw-w64 file."""
    destination = os.path.join(output, "include", "libc", HEADER_DIRECTORY)
    pr.copyTree(include, destination)
    for name in sorted(os.listdir(threadHeaders)):
        target = os.path.join(destination, pr.checkName(name))
        if os.path.lexists(target):
            raise pe.EngineError("winpthreads header %s is also in mingw-w64-headers" % name)
        shutil.copyfile(os.path.join(threadHeaders, name), target)
        os.chmod(target, 0o644)
    return [HEADER_DIRECTORY]


def copyNotices(output, roots):
    """The license files of NOTICES under output/notices/<name>/; a missing one is an error. Returns the relative names."""
    records = []
    for name, (which, relatives) in sorted(NOTICES.items()):
        for relative in relatives:
            source = os.path.realpath(os.path.join(roots[which], relative))
            if os.path.commonpath([roots[which], source]) != roots[which] or not os.path.isfile(source):
                raise pe.EngineError("notice %s is missing from %s or leaves it" % (relative, roots[which]))
            destination = os.path.join(output, "notices", name, os.path.basename(source))
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copyfile(source, destination)
            records.append("notices/%s/%s" % (name, os.path.basename(source)))
    return records


def produceTarget(roots, engine, major, headers, target, work, output, tools, environment, jobs):
    """Build the target's runtime from source, write its variants and stage its builtins. Returns (the variant
    records, the CRT files left out, the builtins' resource record)."""
    libraries = buildCrt(roots["mingw"], engine, major, headers, target, work, tools, environment, jobs)
    builtins = buildCompilerRt(roots["llvm"], engine, major, headers, target, work, tools, environment, jobs)
    threads = buildWinpthreads(roots["mingw"], engine, major, headers, target, work, tools, environment, jobs)
    provideSspArchives(engine, libraries)
    files, leftOut = collectFiles(libraries, threads)
    checkTargetFiles(files, target)
    resource, records = stageBuiltins(builtins, target, output), []
    for variant, spec in SOURCE_VARIANTS.items():
        directory = variantDirectory(target, variant)
        installed = copyFiles(files, output, directory)
        pe.writeText(os.path.join(output, variantConfig(target, variant)),
                     renderSourceConfig(target, variant, [HEADER_DIRECTORY], major))
        records.append({
            "target": target, "variant": variant, "directory": directory, "config": variantConfig(target, variant),
            "clangTarget": SOURCE_TARGETS[target]["clangTarget"], "cpu": SOURCE_TARGETS[target]["cpu"],
            "startupObject": spec["startup"], "linkMachine": pw.TARGETS[target]["linkMachine"],
            "stack": spec["stack"], "imageBase": "0x%x" % spec["imageBase"], "files": installed})
    return records, leftOut, resource


def canExecute(target):
    """Whether this host runs a PE file of target: Windows, with x86_64 files also on an ARM64 host's emulation."""
    if sys.platform != "win32":
        return False
    machine = platform.machine().upper()
    return machine == "ARM64" or (machine in ("AMD64", "X86_64") and target == pw.TARGET)


def sourceSteps(clang, runtime, work, target):
    """The compile and link commands of the proof as ([(name, command)], {(proof, mode): linked file}, [object files
    that must hold bitcode], [(name, `-###` link command, proof)]): every proof plain and with thin and full LTO, the
    ABI fixture, and for each proof the driver's plan of its plain link, which is printed and never run. A proof that
    names compileFlags gets them on its compile and its flags on its link and its plan, which is where the driver reads
    a stack protector flag to add its libraries."""
    steps, outputs, bitcode, plans = [], {}, [], []
    for name, proof in PROOFS.items():
        config = ["--no-default-config", "--config", os.path.join(runtime, variantConfig(target, proof["variant"]))]
        fixture = os.path.join(pr.FIXTURES, proof["fixture"])
        suffix = ".dll" if proof["variant"] == "dll" else ".exe"
        for mode, flags in LTO_MODES:
            obj = os.path.join(work, name + mode + ".o")
            output = os.path.join(work, name + mode + suffix)
            steps.append(("%s %s compile" % (name, mode), [clang] + config + ["-O2"] + proof["compileFlags"] + flags
                          + ["-c", fixture, "-o", obj]))
            steps.append(("%s %s link" % (name, mode), [clang] + config + flags + proof["flags"] + [obj, "-o", output]))
            outputs[(name, mode)] = output
            if flags:
                bitcode.append(obj)
        plans.append(("%s plan" % name, [clang] + config + proof["flags"] + [
            "-###", os.path.join(work, name + "plain.o"), "-o", os.path.join(work, name + "plan" + suffix)], name))
    steps.append(("ABI headers", [clang, "--no-default-config", "--config", os.path.join(runtime, variantConfig(target, "exe")),
                                  "-fsyntax-only", "-DEXPECT_" + pw.TARGETS[target]["machineName"],
                                  os.path.join(pr.FIXTURES, "windowsSourceAbi.c")]))
    return steps, outputs, bitcode, plans


def selectionProblem(plan, runtime, target, name):
    """Why the linker line of a `-###` plan of proof `name` does not show the driver choosing the startup object,
    crtbegin.o and crtend.o of the variant directory, the whole link tail and the builtins of the resource directory
    and no libgcc or libunwind, or None."""
    proof = PROOFS[name]
    directory = os.path.normpath(os.path.join(runtime, variantDirectory(target, proof["variant"])))
    lines = [re.findall(r'"([^"]*)"', line) for line in plan.splitlines()]
    links = [words for words in lines if words and os.path.basename(words[0]).startswith("ld.lld")]
    if len(links) != 1:
        return "the plan has %d ld.lld lines, not one" % len(links)
    words = links[0]
    startups = [os.path.normpath(w) for w in words if os.path.basename(w) in STARTUP_OBJECTS]
    if startups != [os.path.join(directory, proof["startup"])]:
        return "startup objects %s are not %s" % (startups, os.path.join(directory, proof["startup"]))
    for object_ in ("crtbegin.o", "crtend.o"):
        if os.path.join(directory, object_) not in [os.path.normpath(w) for w in words]:
            return "the plan does not link %s from %s" % (object_, directory)
    absent = ["-l" + stem for stem in ("mingw32", "moldname", "mingwex", "msvcrt") + tuple(SYSTEM_LIBRARIES)
              if "-l" + stem not in words]
    if absent:
        return "the plan lacks %s" % ", ".join(absent)
    protected = STACK_PROTECTOR in proof["flags"]
    for stem in SSP_LIBRARIES:
        if ("-l" + stem in words) != protected:
            return "the plan %s -l%s" % ("lacks" if protected else "links", stem)
    version = re.search(r"clang version (\d+)", plan)
    if version is None:
        return "the plan names no compiler version"
    resource = os.path.normpath(os.path.join(runtime, ENGINE_RELATIVE, "lib", "clang", version.group(1), "lib", "windows",
                                            builtinsName(target)))
    builtins = [os.path.normpath(w) for w in words if os.path.basename(w) == builtinsName(target)]
    if not builtins or set(builtins) != {resource}:
        return "the plan does not link %s from the engine resource directory %s: %s" % (builtinsName(target), resource, builtins)
    unwanted = [w for w in words if w in ("-lgcc", "-lgcc_eh", "-lgcc_s", "-lunwind")]
    if unwanted:
        return "the plan links %s" % ", ".join(unwanted)
    return None


def undefinedProblem(listing, symbol):
    """Why the `llvm-nm --undefined-only` listing of an object does not show symbol undefined, or None."""
    rows = [line.split() for line in listing.splitlines()]
    undefined = [words[1] for words in rows if len(words) == 2 and words[0] == "U"]
    if symbol not in undefined:
        return "%s is not among its undefined symbols %s" % (symbol, undefined)
    return None


def sourcePeProblem(name, info, target):
    """Why a linked file is not the UCRT executable or DLL of the proof for target, or None."""
    proof, expected = PROOFS[name], pw.TARGETS[target]
    variant = proof["variant"]
    imports = {name.lower() for name in info["imports"]}
    if info["machine"] != expected["machine"]:
        return "machine %#x is not %s" % (info["machine"], expected["machineName"])
    if bool(info["characteristics"] & pw.DLL_CHARACTERISTIC) != (variant == "dll"):
        return "characteristics %#x do not match a %s" % (info["characteristics"], variant)
    if variant != "dll" and info["subsystem"] != pw.SUBSYSTEM_CONSOLE:
        return "subsystem %d is not console" % info["subsystem"]
    if variant == "dll" and proof["export"] not in info["exports"]:
        return "exports %s lack %s" % (info["exports"], proof["export"])
    if "msvcrt.dll" in imports or not any(name.startswith("api-ms-win-crt-") for name in imports):
        return "imports %s are not the UCRT's" % sorted(imports)
    return None


def checkSourceConfig(run, clang, runtime, work, target, execute=False):
    """Link every proof through its config plain and with thin and full LTO and check the files and the driver's plan,
    and that the plain object of a stack protector proof leaves the protector's failure handler undefined for the
    link to resolve. Any nonzero exit or stderr is an error. With execute the executables run where canExecute says
    so; execute without a host that can run the target is an error. Returns {(proof, mode): linked file}."""
    steps, outputs, bitcode, plans = sourceSteps(clang, runtime, work, target)
    for name, command in steps:
        done = run(command)
        if done.returncode != 0:
            raise pe.EngineError("%s %s failed: %s" % (target, name, done.stderr.strip()))
        if done.stderr.strip():
            raise pe.EngineError("%s %s warned: %s" % (target, name, done.stderr.strip()))
    for name, proof in PROOFS.items():
        if STACK_PROTECTOR in proof["compileFlags"]:
            nm = os.path.join(os.path.dirname(clang), "llvm-nm")
            done = run([nm, "--undefined-only", os.path.join(work, name + "plain.o")])
            if done.returncode != 0:
                raise pe.EngineError("%s %s symbols failed: %s" % (target, name, done.stderr.strip()))
            problem = undefinedProblem(done.stdout, STACK_FAIL_SYMBOL)
            if problem:
                raise pe.EngineError("%s %s plain object: %s" % (target, name, problem))
    for name, command, proof in plans:
        done = run(command)
        if done.returncode != 0:
            raise pe.EngineError("%s %s failed: %s" % (target, name, done.stderr.strip()))
        problem = selectionProblem(done.stderr, runtime, target, proof)
        if problem:
            raise pe.EngineError("%s %s: %s" % (target, name, problem))
    for path in bitcode:
        with open(path, "rb") as f:
            if f.read(4) not in BITCODE_MAGICS:
                raise pe.EngineError("%s: %s is not LTO bitcode" % (target, os.path.basename(path)))
    for (name, mode), path in sorted(outputs.items()):
        problem = sourcePeProblem(name, pw.readPe(path), target)
        if problem:
            raise pe.EngineError("%s %s %s: %s" % (target, name, mode, problem))
    if execute and not canExecute(target):
        raise pe.EngineError("this host cannot run %s files" % target)
    if execute:
        for (name, mode), path in sorted(outputs.items()):
            expected = PROOFS[name]["runs"]
            if expected:
                runOutput(path, expected, "%s %s %s" % (target, name, mode))
    return outputs


def runOutput(path, expected, name):
    done = subprocess.run([path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                          timeout=RUN_TIMEOUT_SECONDS)
    if done.returncode != 0 or done.stdout != expected or done.stderr:
        raise pe.EngineError("%s ran with exit %d and printed %r, not %r: %s" % (
            name, done.returncode, done.stdout, expected, done.stderr.strip()))


def stageTree(engine, windows, root, major):
    """A copy of the engine at root with the runtime in windows beside it as root/runtime/windows, where the config's
    engineRelative reaches the engine, and the runtime's builtins installed in the copy's own resource directory:
    the engine it was given is read and never written."""
    shutil.copytree(engine, root, symlinks=True)
    if os.path.lexists(os.path.join(root, "runtime")):
        raise pe.EngineError("engine entry collides with the runtime")
    shutil.copytree(windows, os.path.join(root, "runtime", "windows"), symlinks=True)
    installResource(os.path.join(root, "runtime", "windows"), os.path.join(root, "lib", "clang", major))


def verifySourceConfigs(engine, windows, targets, work):
    """pw.checkWindowsConfig and checkSourceConfig of every target on a staged copy of the engine and the runtime;
    nothing it links is run."""
    root = os.path.join(work, "verify")
    stageTree(engine, windows, root, pr.engineMajor(engine)[2])
    runtime = os.path.join(root, "runtime")
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    run = lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, universal_newlines=True)
    clang, windows = os.path.join(root, "bin", "clang"), os.path.join(runtime, "windows")
    for target in targets:
        scratch = {name: os.path.join(work, "verify-%s-%s" % (name, target)) for name in ("config", "source")}
        for path in scratch.values():
            os.makedirs(path)
        pw.checkWindowsConfig(run, clang, windows, scratch["config"], [], target)
        checkSourceConfig(run, clang, windows, scratch["source"], target)


def writeProvenance(windows, host, engineVersion, targets, directories, records, resourceFiles, notices, leftOut,
                    sources, tools):
    receipt = {
        "kind": RECEIPT_KIND,
        "statement": "Built from pinned mingw-w64 and LLVM source checkouts with the prepared engine. Not an "
                     "upstream-distributed binary and not bit-reproducible by this tool.",
        "redistributionCertified": False,
        "producerHost": host, "engineVersion": engineVersion, "targets": targets, "engineRelative": ENGINE_RELATIVE,
        "includeDirectories": directories, "sources": sources, "tools": tools,
        "recipe": {"defaultWin32Winnt": WINNT, "defaultMsvcrt": "ucrt", "crtFlags": {
                       t: SOURCE_TARGETS[t]["crtFlags"] for t in targets}, "cflags": "-O2",
                   "winpthreads": "upstream configure --disable-shared --enable-static; make; make install",
                   "driverFlags": DRIVER_FLAGS},
        "variants": records, "resourceFiles": resourceFiles, "crtFilesLeftOut": leftOut, "notices": notices, "limits": LIMITS,
        "linkerFlavor": "clang GNU driver, ld.lld in MinGW mode; no lld-link and no wrapper",
    }
    os.makedirs(os.path.join(windows, "notices"), exist_ok=True)
    pe.writeText(os.path.join(windows, "notices", PROVENANCE), json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def prepareWindowsSourceRuntime(engine, windows, mingw, mingwRev, llvm, llvmRev, tools, targets=None, jobs=None):
    """Write the Windows runtime of `targets` (every target of pw.TARGETS when none) built from source to the new
    directory `windows`, whose engine is two levels up in a bundle, and link its proofs without running them.
    Returns (windows, records)."""
    engine, windows = os.path.abspath(engine), os.path.abspath(windows)
    targets = pw.selectWindowsTargets(targets)
    if os.path.lexists(windows):
        raise pe.EngineError("output %s exists; it is never replaced" % windows)
    host, version, major = pr.engineMajor(engine)
    for name in ("clang", "clang++", "ld.lld", "llvm-ar", "llvm-ranlib", "llvm-dlltool", "llvm-rc"):
        engineTool(engine, name)
    mingwRev, llvmRev = pinnedRevisions(version, mingwRev, llvmRev)
    roots = {"mingw": checkSourceRoot(mingw, mingwRev, "mingw-w64", MINGW_MARKERS),
             "llvm": checkSourceRoot(llvm, llvmRev, "llvm-project", LLVM_MARKERS)}
    checkLlvmVersion(roots["llvm"], version)
    jobs = jobs or os.cpu_count() or 1
    os.makedirs(os.path.dirname(windows), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(windows) + ".partial-", dir=os.path.dirname(windows))
    work = tempfile.mkdtemp(prefix="prepareWindowsSourceRuntime-")
    try:
        checkPlainPath(work, "work directory")
        checkPlainPath(engine, "engine")
        environment = buildEnvironment(work, tools)
        headers = buildHeaders(roots["mingw"], work, tools, environment)
        records, resourceFiles, leftOut = [], [], {}
        for target in targets:
            produced, leftOut[target], resource = produceTarget(roots, engine, major, headers, target, work, partial,
                                                                tools, environment, jobs)
            records += produced
            resourceFiles.append(resource)
        directories = copyHeaders(headers, os.path.join(roots["mingw"], "mingw-w64-libraries", "winpthreads",
                                                         "include"), partial)
        notices = copyNotices(partial, roots)
        writeProvenance(partial, host, version, targets, directories, records, resourceFiles, notices, leftOut,
                        {"mingw-w64": {"rev": mingwRev}, "llvm-project": {"rev": llvmRev, "version": version, "major": major,
                                                                           "subdirectory": "compiler-rt/lib/builtins"}},
                        dict(toolVersions(tools), clang=version))
        verifySourceConfigs(engine, partial, targets, work)
        for root, rev, what, markers in ((mingw, mingwRev, "mingw-w64", MINGW_MARKERS),
                                         (llvm, llvmRev, "llvm-project", LLVM_MARKERS)):
            checkSourceRoot(root, rev, what, markers)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, windows)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return windows, records


def prepareRuntimeDirectory(engine, output, *arguments, **options):
    """The standalone form: a new RUNTIME directory holding only `windows/`."""
    output = os.path.abspath(output)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        records = prepareWindowsSourceRuntime(engine, os.path.join(partial, "windows"), *arguments, **options)[1]
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return output, records


def receiptProblem(receipt, windows):
    """Why a receipt does not describe the runtime in windows, or None: its kind, targets, engine path, the shape of
    every variant and resource record, the hash of every file of every variant directory and of every resource file,
    with no resource file unlisted and no link on the way to any of them. A path a record names is checked before it
    is opened."""
    if receipt.get("kind") != RECEIPT_KIND:
        return "receipt kind %r is not %r" % (receipt.get("kind"), RECEIPT_KIND)
    targets = receipt.get("targets")
    if not targets or any(t not in SOURCE_TARGETS for t in targets):
        return "receipt targets %r are not in %s" % (targets, sorted(SOURCE_TARGETS))
    if receipt.get("engineRelative") != ENGINE_RELATIVE:
        return "receipt engineRelative %r is not %r" % (receipt.get("engineRelative"), ENGINE_RELATIVE)
    for variant in receipt.get("variants") or []:
        if not isinstance(variant, dict) or variant.get("target") not in targets \
                or variant.get("variant") not in SOURCE_VARIANTS:
            return "receipt variant %r is not a variant of a receipt target" % (variant,)
        directory = variantDirectory(variant["target"], variant["variant"])
        if variant.get("directory") != directory:
            return "receipt variant directory %r is not %r" % (variant.get("directory"), directory)
        for record in variant.get("files") or []:
            try:
                relative = directory + "/" + pr.checkName(record["name"])
            except (pe.EngineError, KeyError, TypeError) as error:
                return "receipt file record %r: %s" % (record, error)
            linked = linkedComponent(windows, relative)
            if linked:
                return "%s is a link" % linked
            path = os.path.join(windows, directory, record["name"])
            if not os.path.isfile(path) or pe.sha256File(path) != record.get("sha256"):
                return "%s does not match the receipt" % relative
    problem = resourceRecordsProblem(receipt)
    if problem:
        return problem
    resource = os.path.join(windows, RESOURCE_DIRECTORY)
    listed = {record["path"] for record in receipt["resourceFiles"]}
    for record in receipt["resourceFiles"]:
        linked = linkedComponent(windows, RESOURCE_DIRECTORY + "/" + record["path"])
        if linked:
            return "%s is a link" % linked
        path = os.path.join(resource, *record["path"].split("/"))
        if not os.path.isfile(path) or pe.sha256File(path) != record["sha256"]:
            return "%s/%s does not match the receipt" % (RESOURCE_DIRECTORY, record["path"])
    present = set()
    for directory, directories, names in os.walk(resource):
        for name in directories + names:
            if pe.isLinkLike(os.path.join(directory, name)):
                return "%s is a link" % os.path.join(directory, name)
        present.update(os.path.relpath(os.path.join(directory, name), resource).replace(os.sep, "/") for name in names)
    if present != listed:
        return "resource files %s are not the receipt's %s" % (sorted(present), sorted(listed))
    return None


def prove(engine, runtime, denied, execute=False):
    """Relocate the engine and RUNTIME (which holds `windows/`) to a path with a space, where the receipt's
    engineRelative puts them, check the receipt against the files, and run the checks of verifySourceConfigs. On macOS
    the checks run in a sandbox that cannot read the originals or any --deny path; elsewhere the relocation and the
    scan of the linked files for those paths are what is proven."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    pe.verifyEngine(engine)
    with open(os.path.join(runtime, "windows", "notices", PROVENANCE), encoding="utf-8") as f:
        receipt = json.load(f)
    if execute and not any(canExecute(t) for t in receipt.get("targets", [])):
        raise pe.EngineError("--execute: this host cannot run any target of the receipt")
    problem = receiptProblem(receipt, os.path.join(runtime, "windows"))
    if problem:
        raise pe.EngineError(problem)
    major = pr.engineMajor(engine)[2]
    if receipt["sources"]["llvm-project"]["major"] != major:
        raise pe.EngineError("receipt builtins are LLVM %s, the engine is LLVM %s" % (
            receipt["sources"]["llvm-project"]["major"], major))
    work = os.path.realpath(tempfile.mkdtemp(prefix="windows-source-proof-"))
    root = os.path.join(work, "relocated tree")
    try:
        stageTree(engine, os.path.join(runtime, "windows"), root, major)
        secrets = [engine, runtime] + [os.path.realpath(p) for p in denied]
        if sys.platform == "darwin":
            profile = os.path.join(work, "deny.sb")
            pe.writeText(profile, "(version 1)(allow default)" + "".join(
                '(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (p, p) for p in secrets) + "\n")
            if pr.sandboxed(profile, work, [os.path.join(engine, "bin", "clang"), "--version"]).returncode == 0:
                raise pe.EngineError("sandbox does not deny the original engine")
            run = lambda command: pr.sandboxed(profile, work, command)
        else:
            environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
            run = lambda command: subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                                                 stderr=subprocess.PIPE, universal_newlines=True)
        clang, windows = os.path.join(root, "bin", "clang"), os.path.join(root, "runtime", "windows")
        for target in receipt["targets"]:
            scratch = {name: os.path.join(work, "%s-%s" % (name, target)) for name in ("config", "source")}
            for path in scratch.values():
                os.makedirs(path)
            pw.checkWindowsConfig(run, clang, windows, scratch["config"], [], target)
            outputs = checkSourceConfig(run, clang, windows, scratch["source"], target,
                                        execute and canExecute(target))
            for (name, mode), path in sorted(outputs.items()):
                with open(path, "rb") as f:
                    data = f.read()
                leaked = [p for p in secrets if p.encode("utf-8") in data]
                if leaked:
                    raise pe.EngineError("%s output %s %s holds source paths %s" % (target, name, mode, leaked))
            print("%s: %d linked files checked (plain, thin and full LTO); %s" % (
                target, len(outputs), "executables run" if execute and canExecute(target) else "not run"))
        print("relocated=%s sandbox=%s" % (root, "macos" if sys.platform == "darwin" else "none"))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--output")
    parser.add_argument("--runtime")
    parser.add_argument("--mingw-w64")
    parser.add_argument("--mingw-w64-rev")
    parser.add_argument("--llvm-project")
    parser.add_argument("--llvm-project-rev")
    parser.add_argument("--sh")
    parser.add_argument("--make")
    parser.add_argument("--cmake")
    parser.add_argument("--ninja")
    parser.add_argument("--jobs", type=int)
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--target", action="append", default=[], help="a Windows target; every target when none")
    parser.add_argument("--execute", action="store_true", help="with --prove only: run the executables the host can run")
    parser.add_argument("--prove", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.prove:
            if not args.runtime:
                parser.error("--prove needs --runtime")
            prove(args.engine, args.runtime, args.deny, args.execute)
        else:
            required = ("output", "mingw_w64", "llvm_project")
            missing = [n for n in required if not getattr(args, n)]
            if missing:
                parser.error("%s required" % ", ".join("--" + n.replace("_", "-") for n in missing))
            if args.execute:
                parser.error("--execute only goes with --prove: the build links the proofs and runs nothing")
            tools = resolveTools(args.sh, args.make, args.cmake, args.ninja)
            output, records = prepareRuntimeDirectory(
                args.engine, args.output, args.mingw_w64, args.mingw_w64_rev, args.llvm_project,
                args.llvm_project_rev, tools, targets=args.target, jobs=args.jobs)
            for record in records:
                print("%s %s: %d files" % (record["target"], record["variant"], len(record["files"])))
            print("runtime written to %s" % output)
    except pe.EngineError as error:
        print("prepareWindowsSourceRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
