#!/usr/bin/env python3
"""Prove managed bundle selection through an msc compiler, including negative inputs and cache reuse."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import prepareEngine

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def run(command, environment, expected=0, contains=""):
    result = subprocess.run(command, env=environment, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if result.returncode != expected or contains not in output:
        raise RuntimeError("%r: expected exit %s containing %r; got %s\n%s" %
                           (command, expected, contains, result.returncode, output))
    return output


def fakeBundle(root):
    for name in ("clang", "clang++", "llvm-ar", "ld64.lld"):
        path = root / "bin" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\necho 'clang version 22.1.1'\n")
        path.chmod(0o755)
    header = root / "lib/clang/22/include/stddef.h"
    header.parent.mkdir(parents=True)
    header.write_text("")
    prepareEngine.writeContract(str(root), prepareEngine.detectHost()[0], "22.1.1")


def proveNativeLibraries(compiler, bundle, work, sandbox, environment):
    sdk = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], check=True,
                         capture_output=True, text=True).stdout.strip()
    major = (bundle / "VERSION").read_text().strip().split(".")[0]
    client = work / "libraryClient.cpp"
    client.write_text('#include <stdio.h>\n#include "companion.h"\n'
                      'int main(){int v=companionValue();printf("native-library-ok %d\\n",v);return v==42?0:1;}\n')
    for mode, suffix in (("lib", ".dylib"), ("staticlib", ".a")):
        library, executable = work / ("companion" + suffix), work / ("libraryClient-" + mode)
        run(sandbox + [str(compiler), "build", str(work / "companionConsumer.ms"), "--lto=off", "--colors=off",
                       "--app=" + mode, "--output=" + str(library)], environment)
        run(sandbox + [str(bundle / "bin/clang++"), "--no-default-config", "-isysroot", sdk,
                       "-resource-dir", str(bundle / "lib/clang" / major),
                       "--ld-path=" + str(bundle / "bin/ld64.lld"), str(client), str(library),
                       "-o", str(executable)], environment)
        run(sandbox + [str(executable)], environment, contains="native-library-ok 42")
    print("native C++20 shared/static companions ran through bundled-Clang++ clients without Zig")


def prove(compiler, engine):
    host, version, _ = prepareEngine.verifyEngine(str(engine))
    with tempfile.TemporaryDirectory(prefix="native-compiler-proof-") as temporary:
        work = Path(temporary).resolve()
        source = work / "consumer.ms"
        shutil.copyfile(FIXTURES / "consumer.ms", source)
        environment = dict(os.environ, MSC_NATIVE_TOOLCHAIN=str(work / "missing"),
                           MSC_NO_GLOBAL_CACHE="1", MSC_CACHE_DIR=str(work / "cache"))
        command = [str(compiler), "build", str(source), "--lto=off", "--colors=off",
                   "--output=" + str(work / "consumer")]
        run(command, environment, expected=1, contains="native toolchain: missing bundle")
        run(command + ["--cc=clang"], environment)
        print("missing bundle refused; explicit --cc bypass preserved")
        fake = work / "fake"
        fakeBundle(fake)
        environment["MSC_NATIVE_TOOLCHAIN"] = str(fake)
        (fake / "bin/clang.cfg").write_text("-DUNLISTED=1\n")
        run(command, environment, expected=1, contains="unlisted payload bin/clang.cfg")
        (fake / "bin/clang.cfg").unlink()
        (fake / "aliasdir").symlink_to("bin", target_is_directory=True)
        run(command, environment, expected=1, contains="directory symlink aliasdir")
        (fake / "aliasdir").unlink()
        (fake / "IDENTITY").write_text("0" * 64 + "\n")
        run(command, environment, expected=1, contains="identity mismatch")
        prepareEngine.writeContract(str(fake), host, version)
        (fake / "lib/clang/22/include/stddef.h").write_text("changed")
        run(command, environment, expected=1, contains="payload checksum verification failed")
        prepareEngine.writeContract(str(fake), "x86_64-linux", version)
        run(command, environment, expected=1, contains="does not match")
        print("extra config, stale identity, corrupt payload and wrong host refused")
        moved = work / "bundle with spaces"
        shutil.copytree(engine, moved, symlinks=True)
        environment["MSC_NATIVE_TOOLCHAIN"] = str(moved)
        environment["PATH"] = "/usr/bin:/bin"
        profile = work / "deny.sb"
        denied = [str(engine), "/opt/homebrew", str(Path.home() / ".metascript")]
        system_compilers = ["/usr/bin/" + name for name in ("clang", "clang++", "cc", "c++", "gcc", "g++", "ld")]
        for tool in ("clang", "clang++", "ld"):
            located = subprocess.run(["/usr/bin/xcrun", "--find", tool], check=True,
                                     capture_output=True, text=True).stdout.strip()
            system_compilers.append(located)
        profile.write_text("(version 1)(allow default)" + "".join(
            '(deny file-read* (subpath "%s"))' % path for path in denied) + "".join(
            '(deny process-exec (literal "%s"))' % path for path in system_compilers) + "\n")
        sandbox = ["/usr/bin/sandbox-exec", "-f", str(profile)]
        control = subprocess.run(sandbox + ["/usr/bin/clang", "--version"], env=environment,
                                 capture_output=True, text=True)
        if control.returncode == 0:
            raise RuntimeError("sandbox did not deny the system compiler")
        run(sandbox + command, environment)
        run([str(work / "consumer")], environment, contains="native-consumer-ok 42")
        for name in ("companion.h", "companion.cpp", "companionConsumer.ms"):
            shutil.copyfile(FIXTURES / name, work / name)
        cpp = [str(compiler), "build", str(work / "companionConsumer.ms"), "--lto=off",
               "--colors=off", "--verbose", "--output=" + str(work / "cpp")]
        run(sandbox + cpp, environment)
        run([str(work / "cpp")], environment, contains="42")
        with (work / "companionConsumer.ms").open("a") as stream:
            stream.write('console.log("cached-companion");\n')
        warm = run(sandbox + cpp, environment)
        run([str(work / "cpp")], environment, contains="42\ncached-companion")
        if "(cached)" not in warm and "(stored)" not in warm:
            raise RuntimeError("changed MetaScript consumer did not reuse its native companion\n" + warm)
        print("relocated C/C++20 consumers and native companion cache reuse passed without Zig")
        identity = (moved / "IDENTITY").read_text()
        provenance = moved / "notices/provenance.json"
        provenance.write_text(provenance.read_text() + "\n")
        prepareEngine.writeContract(str(moved), host, version)
        if (moved / "IDENTITY").read_text() == identity:
            raise RuntimeError("changed payload did not change bundle identity")
        changed = run(sandbox + cpp, environment)
        rebuilt = [line for line in changed.splitlines() if "companion.cpp" in line
                   and "(cached)" not in line and "(stored)" not in line]
        if not rebuilt:
            raise RuntimeError("payload identity change did not recompile the native companion\n" + changed)
        run([str(work / "cpp")], environment, contains="42\ncached-companion")
        print("payload-only identity change reached native build validation")
        proveNativeLibraries(compiler, moved, work, sandbox, environment)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--engine", required=True, type=Path)
    args = parser.parse_args()
    prove(args.compiler.resolve(), args.engine.resolve())
