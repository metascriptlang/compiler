#!/usr/bin/env python3
"""Build the sanitizer runtimes of the Linux and Windows targets from the compiler-rt source of the bundle's LLVM.

    prepareSanitizerRuntime.py --engine ENGINE_DIR --runtime RUNTIME_DIR --source LLVM_SOURCE_DIR --source-sha256 HEX
                               --cmake CMAKE --ninja NINJA --output NEW_DIR [--target T ...] [--jobs N]
    prepareSanitizerRuntime.py --prove --bundle BUNDLE_DIR [--target T ...] [--keep DIR]

LLVM_SOURCE_DIR is an extracted `llvm-project-<version>.src` of the engine's own version (its `compiler-rt/`, `cmake/`,
`runtimes/` and `llvm/cmake/` are read; `--source-sha256` is the digest of the release archive it came from and is only
recorded). RUNTIME_DIR is a bundle's `runtime/`, whose C configs compile compiler-rt as the programs it will link into
are compiled: the engine's clang with `--no-default-config --config=<target>.cfg`, so the glibc 2.31 sysroot, the musl
headers or the mingw headers of the bundle are the only libc the runtimes ever saw.

NEW_DIR receives an overlay of bundle-root-relative paths that `prepareBundle.py --bundle-overlay` merges:

    lib/clang/<major>/lib/<triple>/libclang_rt.<name>.a      Linux, where the clang driver looks for them
    runtime/windows/<target>/libclang_rt.ubsan_standalone.a  Windows: lld resolves the dependent library the driver puts
    runtime/windows/<target>/libclang_rt.ubsan_standalone_cxx.a   in each object by the plain file name in the `-L` the
                                                             config gives, never in the resource directory; the
                                                             `<target>.cfg` of executables and the `<target>.dll.cfg` of
                                                             DLLs give different `-L`, so the same archives are in
                                                             `runtime/windows/<target>.dll/` too
    runtime/windows/<target>[.dll]/libsynchronization.a      import library of the three calls the runtime makes
    notices/sanitizer-provenance.json, notices/compiler-rt/LICENSE.TXT

glibc Linux gets ASan, TSan, UBSan (standalone and minimal) and their C++ halves, musl Linux UBSan alone (standalone,
its C++ half and minimal; the standalone one calls `_Unwind_Backtrace`, which the musl C++ config's libunwind provides, so
a standalone link takes the `<target>.cxx.cfg` pair) and Windows the standalone UBSan (Zig offers neither ASan nor TSan
on either). Windows has no minimal runtime: compiler-rt does not
build it for mingw and the MinGW driver names the standalone one for `-fsanitize-minimal-runtime` too.

`--prove` links and, where the host is Linux of the target's machine or Windows, runs a clean, a faulting and a racing
fixture through each target's config pair in a bundle that has the overlay merged, and requires the faulting ones to be
reported. `--keep DIR` leaves the linked programs there so another host can run them.
"""
import argparse
import hashlib
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

PROVENANCE = "notices/sanitizer-provenance.json"
LICENSE = "notices/compiler-rt/LICENSE.TXT"
GLIBC_RUNTIMES = ["asan", "asan_static", "asan_cxx", "tsan", "tsan_cxx", "ubsan_standalone", "ubsan_standalone_cxx",
                  "ubsan_minimal"]
MUSL_RUNTIMES = ["ubsan_standalone", "ubsan_standalone_cxx", "ubsan_minimal"]
WINDOWS_RUNTIMES = ["ubsan_standalone", "ubsan_standalone_cxx"]
SYNCHRONIZATION_DEFINITION = ("LIBRARY api-ms-win-core-synch-l1-2-0.dll\nEXPORTS\nWaitOnAddress\nWakeByAddressAll\n"
                              "WakeByAddressSingle\n")
LIMITS = ["the archives are a local build of the release source with the bundle's clang, not an upstream binary, and "
          "are not measured for bit-reproducibility",
          "Windows ASan and TSan are not built: compiler-rt has no mingw support for them and Zig offers neither",
          "musl ASan and TSan are not built: Zig offers neither for musl",
          "the standalone UBSan of musl links only with the C++ config of its target, which holds libunwind",
          "the shared runtimes (libclang_rt.*.so, .dll) are not built, only the static archives the driver links"]


def linuxSpec(cpu, abi, runtimes, sanitizers):
    triple = "%s-unknown-linux-%s" % (cpu, abi)
    return {"triple": triple, "system": "Linux", "processor": cpu, "runtimes": runtimes, "sanitizers": sanitizers,
            "directories": ["lib/clang/%s/lib/" + triple], "windows": False}


def windowsSpec(cpu, processor, dlltool):
    return {"triple": "%s-w64-windows-gnu" % cpu, "system": "Windows", "processor": processor,
            "runtimes": WINDOWS_RUNTIMES, "sanitizers": "ubsan_minimal", "directories": ["runtime/windows/%s", "runtime/windows/%s.dll"],
            "windows": True, "dlltool": dlltool}


TARGETS = {
    "x86_64-linux-gnu.2.31": dict(linuxSpec("x86_64", "gnu", GLIBC_RUNTIMES, "asan;tsan;ubsan_minimal"),
                                  config="x86_64-linux-gnu.2.31.cfg"),
    "aarch64-linux-gnu.2.31": dict(linuxSpec("aarch64", "gnu", GLIBC_RUNTIMES, "asan;tsan;ubsan_minimal"),
                                   config="aarch64-linux-gnu.2.31.cfg"),
    "x86_64-linux-musl": dict(linuxSpec("x86_64", "musl", MUSL_RUNTIMES, "ubsan_minimal"),
                              config="x86_64-linux-musl.cfg"),
    "aarch64-linux-musl": dict(linuxSpec("aarch64", "musl", MUSL_RUNTIMES, "ubsan_minimal"),
                               config="aarch64-linux-musl.cfg"),
    "x86_64-windows-gnu": dict(windowsSpec("x86_64", "AMD64", "i386:x86-64"), config="windows/x86_64-windows-gnu.cfg"),
    "aarch64-windows-gnu": dict(windowsSpec("aarch64", "ARM64", "arm64"), config="windows/aarch64-windows-gnu.cfg"),
}
DISABLED_COMPONENTS = ("BUILTINS", "CRT", "LIBFUZZER", "PROFILE", "MEMPROF", "XRAY", "ORC", "GWP_ASAN", "CTX_PROFILE")


def selectTargets(names):
    chosen = list(names) if names else list(TARGETS)
    for name in chosen:
        if name not in TARGETS:
            raise pe.EngineError("target %s has no sanitizer runtime; allowed: %s" % (name, ", ".join(TARGETS)))
    if len(set(chosen)) != len(chosen):
        raise pe.EngineError("duplicate target in %s" % chosen)
    return chosen


def sourceVersion(source):
    """The LLVM version the extracted source tree says it is."""
    path = os.path.join(source, "cmake", "Modules", "LLVMVersion.cmake")
    if not os.path.isfile(path):
        raise pe.EngineError("%s is not an extracted llvm-project tree: no %s" % (source, "cmake/Modules/LLVMVersion.cmake"))
    with open(path, encoding="utf-8") as f:
        text = f.read()
    parts = [re.search(r"set\(LLVM_VERSION_%s (\d+)\)" % name, text) for name in ("MAJOR", "MINOR", "PATCH")]
    if not all(parts):
        raise pe.EngineError("%s names no LLVM version" % path)
    return ".".join(p.group(1) for p in parts)


def cmakeArguments(spec, source, engine, config, build, ninja):
    """The configure command of one target's compiler-rt build; the compiler is the engine's clang through the target's
    config, so no flag of the host reaches it."""
    flags = "--no-default-config --config=" + config
    arguments = [
        "-S", os.path.join(source, "runtimes"), "-B", build, "-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja,
        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_SYSTEM_NAME=" + spec["system"],
        "-DCMAKE_SYSTEM_PROCESSOR=" + spec["processor"],
        "-DCMAKE_C_COMPILER=" + os.path.join(engine, "bin", "clang"),
        "-DCMAKE_CXX_COMPILER=" + os.path.join(engine, "bin", "clang++"),
        "-DCMAKE_ASM_COMPILER=" + os.path.join(engine, "bin", "clang"),
        "-DCMAKE_C_FLAGS=" + flags, "-DCMAKE_CXX_FLAGS=" + flags, "-DCMAKE_ASM_FLAGS=" + flags,
        "-DCMAKE_AR=" + os.path.join(engine, "bin", "llvm-ar"), "-DCMAKE_RANLIB=" + os.path.join(engine, "bin", "llvm-ranlib"),
        "-DCMAKE_NM=" + os.path.join(engine, "bin", "llvm-nm"),
        "-DCMAKE_C_COMPILER_WORKS=ON", "-DCMAKE_CXX_COMPILER_WORKS=ON", "-DCMAKE_ASM_COMPILER_WORKS=ON",
        "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
        "-DLLVM_ENABLE_RUNTIMES=compiler-rt", "-DLLVM_DEFAULT_TARGET_TRIPLE=" + spec["triple"], "-DLLVM_RUNTIME_TARGETS=",
        "-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON", "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON",
        "-DCMAKE_C_COMPILER_TARGET=" + spec["triple"], "-DCMAKE_CXX_COMPILER_TARGET=" + spec["triple"],
        "-DCMAKE_ASM_COMPILER_TARGET=" + spec["triple"],
        "-DCOMPILER_RT_INCLUDE_TESTS=OFF", "-DLLVM_INCLUDE_TESTS=OFF",
        "-DCOMPILER_RT_SANITIZERS_TO_BUILD=" + spec["sanitizers"]]
    return arguments + ["-DCOMPILER_RT_BUILD_%s=OFF" % name for name in DISABLED_COMPONENTS]


def runIn(command, environment):
    done = subprocess.run(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if done.returncode != 0:
        raise pe.EngineError("%s failed (%d): %s" % (" ".join(command[:2]), done.returncode, done.stderr.strip()[-2000:]))
    return done.stdout


def archiveName(name):
    return "libclang_rt.%s.a" % name


def overlayDirectories(spec, target, major):
    return [d % (target if spec["windows"] else major) for d in spec["directories"]]


def buildTarget(cmake, ninja, source, engine, runtime, target, work, jobs):
    """Configure and build one target's archives. Returns {runtime name: path}."""
    spec = TARGETS[target]
    build = os.path.join(work, target)
    environment = {"PATH": "%s:%s:/usr/bin:/bin" % (os.path.dirname(cmake), os.path.dirname(ninja)),
                   "HOME": "/nonexistent", "TMPDIR": work, "PYTHONPATH": os.environ.get("PYTHONPATH", "")}
    runIn([cmake] + cmakeArguments(spec, source, engine, os.path.join(runtime, spec["config"]), build, ninja), environment)
    wanted = {name: os.path.join(build, "compiler-rt", "lib", spec["triple"], archiveName(name)) for name in spec["runtimes"]}
    runIn([ninja, "-C", build, "-j", str(jobs)] + [os.path.relpath(p, build) for p in wanted.values()], environment)
    for name, path in wanted.items():
        if not os.path.isfile(path):
            raise pe.EngineError("%s: the build made no %s" % (target, archiveName(name)))
    return wanted


def importLibrary(engine, spec, work, output):
    """libsynchronization.a: the import library of the calls the Windows runtime makes, from an inline definition."""
    definition = os.path.join(work, "synchronization.def")
    pe.writeText(definition, SYNCHRONIZATION_DEFINITION)
    pe.run([os.path.join(engine, "bin", "llvm-dlltool"), "-m", spec["dlltool"], "-d", definition, "-l", output])


def archiveProblem(engine, path):
    """Why an archive is not a plain static library of defined symbols, or None."""
    done = pe.run([os.path.join(engine, "bin", "llvm-nm"), "--defined-only", "--extern-only", path])
    return None if done.strip() else "defines no external symbol"


def produce(engine, runtime, source, cmake, ninja, targets, output, jobs, work):
    host, version, major = pr.engineMajor(engine)
    if sourceVersion(source) != version:
        raise pe.EngineError("source %s is LLVM %s, the engine is %s" % (source, sourceVersion(source), version))
    records = []
    for target in targets:
        spec = TARGETS[target]
        built = buildTarget(cmake, ninja, source, engine, runtime, target, work, jobs)
        directories = [os.path.join(output, d) for d in overlayDirectories(spec, target, major)]
        files = []
        for name, path in sorted(built.items()):
            problem = archiveProblem(engine, path)
            if problem:
                raise pe.EngineError("%s %s: %s" % (target, archiveName(name), problem))
            files.append((archiveName(name), path))
        if spec["windows"]:
            synchronization = os.path.join(work, target + "-libsynchronization.a")
            importLibrary(engine, spec, work, synchronization)
            files.append(("libsynchronization.a", synchronization))
        for directory in directories:
            os.makedirs(directory)
            for name, path in files:
                copy = os.path.join(directory, name)
                shutil.copyfile(path, copy)
                os.chmod(copy, 0o644)
        records.append({"target": target, "triple": spec["triple"],
                        "directories": [os.path.relpath(d, output) for d in directories], "runtimes": sorted(spec["runtimes"]),
                        "files": [{"name": name, "sha256": pe.sha256File(path), "bytes": os.path.getsize(path)}
                                  for name, path in files]})
    return host, version, records


def writeProvenance(output, source, sourceSha256, host, version, records):
    license_ = os.path.join(source, "compiler-rt", "LICENSE.TXT")
    os.makedirs(os.path.join(output, os.path.dirname(LICENSE)))
    shutil.copyfile(license_, os.path.join(output, LICENSE))
    receipt = {
        "kind": "local-source-sanitizer-runtime",
        "statement": "Built with the engine's clang from the compiler-rt of the named llvm-project release source. "
                     "Not an upstream-published binary.",
        "redistributionCertified": False, "producerHost": host, "engineVersion": version,
        "source": {"archiveSha256": sourceSha256, "compilerRtLicenseSha256": pe.sha256File(license_)},
        "targets": records, "limits": LIMITS,
    }
    pe.writeText(os.path.join(output, PROVENANCE), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def prepareSanitizerRuntime(engine, runtime, source, sourceSha256, cmake, ninja, output, targets=None, jobs=4):
    engine, runtime, source, output = (os.path.abspath(p) for p in (engine, runtime, source, output))
    cmake, ninja = os.path.abspath(cmake), os.path.abspath(ninja)
    if not re.match(r"^[0-9a-f]{64}$", sourceSha256):
        raise pe.EngineError("--source-sha256 is not a sha256 digest")
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    for tool in (cmake, ninja):
        if not os.access(tool, os.X_OK):
            raise pe.EngineError("%s is not executable" % tool)
    targets = selectTargets(targets)
    for target in targets:
        if not os.path.isfile(os.path.join(runtime, TARGETS[target]["config"])):
            raise pe.EngineError("runtime %s has no %s" % (runtime, TARGETS[target]["config"]))
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    work = os.path.realpath(tempfile.mkdtemp(prefix="prepareSanitizerRuntime-"))
    try:
        host, version, records = produce(engine, runtime, source, cmake, ninja, targets, partial, jobs, work)
        receipt = writeProvenance(partial, source, sourceSha256, host, version, records)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return output, receipt


FIXTURES = {"clean": "sanitizerClean.c", "heap": "sanitizerHeapOverflow.c", "signed": "sanitizerSignedOverflow.c",
            "race": "sanitizerRace.c"}
# What a sanitizer must say when it reports the fixture, and the flags that make the report fatal.
CASES = [("address", ["-fsanitize=address"], "heap", "AddressSanitizer: heap-buffer-overflow", "asan", False),
         ("undefined", ["-fsanitize=undefined"], "signed", "runtime error: signed integer overflow", "ubsan_standalone", False),
         ("undefined-abort", ["-fsanitize=undefined", "-fno-sanitize-recover=undefined"], "signed",
          "runtime error: signed integer overflow", "ubsan_standalone", True),
         ("thread", ["-fsanitize=thread"], "race", "ThreadSanitizer: data race", "tsan", False),
         ("undefined-minimal", ["-fsanitize=undefined", "-fsanitize-minimal-runtime", "-fno-sanitize-recover=undefined"],
          "signed", "ubsan: add-overflow", "ubsan_minimal", True)]


def casesOf(target):
    """The CASES the runtimes of target make usable. A case that aborts must exit nonzero after reporting."""
    names = TARGETS[target]["runtimes"]
    return [c for c in CASES if c[4] in names and not (TARGETS[target]["windows"] and c[4] == "ubsan_minimal")]


def configPair(bundle, target):
    """The clang arguments of a C link of target: the C++ config first when there is one, the C config, and the
    `--target=` the compiler adds after them, which is the name of the directory the driver looks in for the runtimes."""
    runtime = os.path.join(bundle, "runtime")
    spec = TARGETS[target]
    base = os.path.join(runtime, spec["config"])
    cxx = base[:-len(".cfg")] + ".cxx.cfg"
    pair = ["--no-default-config"]
    if not spec["windows"] and os.path.isfile(cxx):
        pair.append("--config=" + cxx)
    return pair + ["--config=" + base] + ([] if spec["windows"] else ["--target=" + spec["triple"]])


def hostRuns(target):
    spec = TARGETS[target]
    if spec["windows"]:
        return sys.platform == "win32" and spec["processor"] == "AMD64"
    return sys.platform.startswith("linux") and platform.machine().lower() in (
        ("x86_64", "amd64") if spec["processor"] == "x86_64" else ("aarch64", "arm64"))


def prove(bundle, targets=None, keep=None):
    """Link every sanitizer mode the target offers on the clean, faulting and racing fixture; run where the host can."""
    bundle = os.path.realpath(bundle)
    pe.verifyEngine(bundle)
    targets = selectTargets(targets)
    clang = os.path.join(bundle, "bin", "clang")
    work = os.path.realpath(keep) if keep else os.path.realpath(tempfile.mkdtemp(prefix="sanitizer-proof-"))
    os.makedirs(work, exist_ok=True)
    try:
        for target in targets:
            suffix = ".exe" if TARGETS[target]["windows"] else ""
            for mode, flags, fixture, message, _, aborts in casesOf(target):
                for kind in ("clean", fixture):
                    output = os.path.join(work, "%s-%s-%s%s" % (target, mode, kind, suffix))
                    command = [clang] + configPair(bundle, target) + flags + [
                        "-g", "-O1", os.path.join(pr.FIXTURES, FIXTURES[kind]), "-o", output]
                    if kind == "race" and not TARGETS[target]["windows"]:
                        command.append("-lpthread")
                    pe.run(command)
                    ran = "linked"
                    if hostRuns(target):
                        done = subprocess.run([output], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                              universal_newlines=True, timeout=120)
                        reported = message in done.stdout
                        wrong = (reported or done.returncode != 0) if kind == "clean" else (
                            not reported or (aborts and done.returncode == 0))
                        if wrong:
                            raise pe.EngineError("%s %s %s: rc %d, output %r" % (target, mode, kind, done.returncode, done.stdout))
                        ran = "ran, %s, rc %d" % ("reported" if reported else "clean", done.returncode)
                    print("%s %s %s: %s" % (target, mode, kind, ran))
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for name in ("engine", "runtime", "source", "source-sha256", "cmake", "ninja", "output", "bundle", "keep"):
        parser.add_argument("--" + name)
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--prove", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.prove:
            if not args.bundle:
                parser.error("--prove needs --bundle")
            prove(args.bundle, args.target, args.keep)
        else:
            required = ("engine", "runtime", "source", "source_sha256", "cmake", "ninja", "output")
            if not all(getattr(args, name) for name in required):
                parser.error("--engine, --runtime, --source, --source-sha256, --cmake, --ninja and --output are required")
            output, receipt = prepareSanitizerRuntime(args.engine, args.runtime, args.source, args.source_sha256,
                                                      args.cmake, args.ninja, args.output, args.target, args.jobs)
            print("%d targets, %d files" % (len(receipt["targets"]), sum(len(t["files"]) for t in receipt["targets"])))
            print("overlay written to %s" % output)
    except pe.EngineError as error:
        print("prepareSanitizerRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
