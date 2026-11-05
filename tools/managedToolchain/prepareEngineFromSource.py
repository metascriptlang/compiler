#!/usr/bin/env python3
"""Build the clang/lld multicall engine from the official LLVM source tarball.

    prepareEngineFromSource.py --source-tarball T --source-sha256 H --work DIR --output NEW_DIR [--jobs N]

The tarball's sha256 is checked before extraction; llvmEngine.cmake is the whole configuration, so the build is the
recipe. NEW_DIR receives the install tree and PROVENANCE.json naming the tarball, its sha256 and the cache file's sha256.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

import prepareEngine as pe
import prepareLinuxEngine as linux
import prepareNotices as notices
import prepareRuntime as runtime
import prepareSanitizerRuntime as sanitizer

CACHE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "llvmEngine.cmake")
SOURCE_NAME = re.compile(r"^llvm-project-(\d+\.\d+\.\d+)\.src\.tar\.xz$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")


def sourceVersion(tarball):
    match = SOURCE_NAME.match(os.path.basename(tarball))
    if not match:
        raise pe.EngineError("%s: not an llvm-project-X.Y.Z.src.tar.xz source tarball" % tarball)
    return match.group(1)


def configureCommand(source, build, prefix, cache=CACHE_FILE, cc="clang", cxx="clang++", linker="lld"):
    return ["cmake", "-G", "Ninja", "-S", os.path.join(source, "llvm"), "-B", build, "-C", cache,
            "-DCMAKE_C_COMPILER=" + cc, "-DCMAKE_CXX_COMPILER=" + cxx, "-DLLVM_USE_LINKER=" + linker,
            "-DCMAKE_INSTALL_PREFIX=" + prefix]


def buildCommand(build, jobs):
    if jobs < 1:
        raise pe.EngineError("--jobs must be at least 1, got %d" % jobs)
    return ["nice", "-n", "10", "ninja", "-C", build, "-j%d" % jobs, "install-distribution"]


def run(command):
    done = subprocess.run(command)
    if done.returncode != 0:
        raise pe.EngineError("%s failed (rc=%d)" % (" ".join(command), done.returncode))


def verifySource(tarball, sha256):
    if not DIGEST.match(sha256):
        raise pe.EngineError("--source-sha256 must be 64 lowercase hex digits")
    actual = pe.sha256File(tarball)
    if actual != sha256:
        raise pe.EngineError("%s: sha256 %s, expected %s" % (tarball, actual, sha256))


def extract(tarball, destination):
    with tarfile.open(tarball) as archive:
        members = archive.getmembers()
        top = members[0].name.split("/")[0]
        archive.extractall(destination, filter="data")
    return os.path.join(destination, top)


def writeProvenance(output, tarball, sha256, cache):
    record = {"source_tarball": os.path.basename(tarball), "source_sha256": sha256,
              "llvm_version": sourceVersion(tarball), "cache_file": os.path.basename(cache),
              "cache_sha256": pe.sha256File(cache)}
    with open(os.path.join(output, "PROVENANCE.json"), "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")
    return record


def prepareFromSource(tarball, sha256, work, output, jobs, cache=CACHE_FILE):
    sourceVersion(tarball)
    verifySource(tarball, sha256)
    if os.path.exists(output):
        raise pe.EngineError("%s exists; --output names a new directory" % output)
    source = extract(tarball, os.path.join(work, "src"))
    build = os.path.join(work, "build")
    run(configureCommand(source, build, os.path.abspath(output), cache))
    run(buildCommand(build, jobs))
    return writeProvenance(output, tarball, sha256, cache)


def packageLinuxEngine(install, runtimeDir, source, output):
    install, runtimeDir, source, output = [os.path.abspath(p) for p in (install, runtimeDir, source, output)]
    if os.path.lexists(output):
        raise pe.EngineError("%s exists; output is never replaced" % output)
    host = linux.detectHost()
    if pe.containsPath(install, os.path.realpath(os.path.dirname(output))):
        raise pe.EngineError("output must not be inside the install tree")
    pe.listFiles(install)
    with open(os.path.join(install, "PROVENANCE.json"), encoding="utf-8") as f:
        provenance = json.load(f)
    version = sanitizer.sourceVersion(source)
    if (provenance.get("llvm_version") != version or
            pe.toolVersion(os.path.join(install, "bin/clang"), r"clang version (\d+\.\d+\.\d+)") != version or
            pe.toolVersion(os.path.join(install, "bin/ld.lld"), r"LLD (\d+\.\d+\.\d+)") != version):
        raise pe.EngineError("source engine does not match LLVM " + version)
    major = version.split(".")[0]
    archives = {name: os.path.join(runtimeDir, "libclang_rt." + name + ".a")
                for name in ("builtins", "ubsan_minimal")}
    for path in archives.values():
        if not os.path.isfile(path):
            raise pe.EngineError("missing compiler-rt archive " + path)
        with open(path, "rb") as f:
            if f.read(8) != b"!<arch>\n" or os.path.getsize(path) <= 8:
                raise pe.EngineError("not a nonempty static compiler-rt archive: " + path)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        shutil.copytree(install, partial, symlinks=True, dirs_exist_ok=True)
        os.symlink("llvm", os.path.join(partial, "bin/clang-" + major))
        inspector = os.path.join(partial, "bin/llvm-readobj")
        os.unlink(inspector)
        os.link(os.path.join(partial, "bin/llvm"), inspector)
        libraries = os.path.join(partial, "lib/clang", major, "lib/linux")
        os.makedirs(libraries)
        records = {}
        for name, path in archives.items():
            shutil.copyfile(path, os.path.join(libraries, "libclang_rt." + name + "-x86_64.a"))
            records[name] = {"sha256": pe.sha256File(path), "bytes": os.path.getsize(path)}
        licenses = {}
        for name in ("llvm", "compiler-rt"):
            path = os.path.join(partial, "notices", name, "LICENSE.TXT")
            os.makedirs(os.path.dirname(path))
            shutil.copyfile(os.path.join(source, name, "LICENSE.TXT"), path)
            licenses[name] = pe.sha256File(path)
        receipt = {"kind": "local-source-engine-proof", "redistributionCertified": False,
                   "host": host, "clangVersion": version, "lldVersion": version,
                   "source": provenance, "runtimeArchives": records, "licenses": licenses,
                   "noticeGaps": ["Static host C/C++ runtime redistribution audit is not completed; "
                                  "local native dogfood only, not a production archive."]}
        pe.writeText(os.path.join(partial, "notices/provenance.json"), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        pe.writeContract(partial, host, version)
        pe.verifyEngine(partial)
        notices.verifyNotices(partial)
        runtime.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return output


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source-tarball", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--work")
    parser.add_argument("--package-install")
    parser.add_argument("--runtime-dir")
    parser.add_argument("--source-tree")
    parser.add_argument("--output", required=True)
    parser.add_argument("--jobs", type=int, default=16)
    args = parser.parse_args(argv)
    if args.package_install:
        if not args.runtime_dir or not args.source_tree:
            parser.error("--package-install needs --runtime-dir and --source-tree")
    elif not args.work:
        parser.error("building from source needs --work")
    try:
        if args.package_install:
            verifySource(args.source_tarball, args.source_sha256)
            with open(os.path.join(args.package_install, "PROVENANCE.json"), encoding="utf-8") as f:
                provenance = json.load(f)
            if provenance.get("source_sha256") != args.source_sha256:
                raise pe.EngineError("install provenance does not match --source-sha256")
            output = packageLinuxEngine(args.package_install, args.runtime_dir, args.source_tree, args.output)
            print("packaged native Linux source engine into " + output)
            notices.report(output)
            return 0
        record = prepareFromSource(args.source_tarball, args.source_sha256, args.work, args.output, args.jobs)
    except pe.EngineError as error:
        print("prepareEngineFromSource: error: %s" % error, file=sys.stderr)
        return 1
    print("built llvm %s from %s into %s" % (record["llvm_version"], record["source_tarball"], args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
