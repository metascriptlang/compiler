#!/usr/bin/env python3
"""Prove a plain msc build selects the msc-toolchain bundle beside the compiler, with Zig and the system compiler denied."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

FIXTURES = Path(__file__).resolve().parent / "fixtures"
COMPILER_ROOT = Path(__file__).resolve().parents[2]
SUPPORT_TREES = ("std", "runtime", "vendor")


def run(command, environment, expected=0, contains=""):
    result = subprocess.run(command, env=environment, capture_output=True, text=True,
                            stdin=subprocess.DEVNULL)
    output = result.stdout + result.stderr
    if (result.returncode == 0) != (expected == 0) or contains not in output:
        raise RuntimeError("%r: expected exit %s containing %r; got %s\n%s" %
                           (command, expected, contains, result.returncode, output))
    return output


def sandboxProfile(profile, denied):
    system_compilers = ["/usr/bin/" + name for name in ("clang", "clang++", "cc", "c++", "gcc", "g++", "ld")]
    for tool in ("clang", "clang++", "ld"):
        located = subprocess.run(["/usr/bin/xcrun", "--find", tool], check=True,
                                 capture_output=True, text=True).stdout.strip()
        system_compilers.append(located)
    profile.write_text("(version 1)(allow default)" + "".join(
        '(deny file-read* (subpath "%s"))' % path for path in denied) + "".join(
        '(deny process-exec (literal "%s"))' % path for path in system_compilers) + "\n")
    return ["/usr/bin/sandbox-exec", "-f", str(profile)]


def build(compiler, source, output, *flags):
    return [str(compiler), "build", str(source), "--lto=off", "--colors=off",
            "--output=" + str(output)] + list(flags)


def prove(compiler, control, bundle):
    with tempfile.TemporaryDirectory(prefix="default-toolchain-proof-") as temporary:
        work = Path(temporary).resolve()
        root = work / "compilerRoot"
        root.mkdir()
        for tree in SUPPORT_TREES:
            (root / tree).symlink_to(COMPILER_ROOT / tree, target_is_directory=True)
        new = root / "msc"
        old = root / "msc-control"
        shutil.copy2(compiler, new)
        shutil.copy2(control, old)
        shutil.copytree(bundle, root / "msc-toolchain", symlinks=True)
        for name in ("consumer.ms", "companion.h", "companion.cpp", "companionConsumer.ms"):
            shutil.copyfile(FIXTURES / name, work / name)

        def environment(label):
            return {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "TMPDIR": str(work),
                    "MSC_NO_GLOBAL_CACHE": "1", "MSC_CACHE_DIR": str(work / ("cache-" + label))}

        sandbox = sandboxProfile(work / "deny.sb", [str(Path(bundle).resolve()), "/opt/homebrew",
                                                    str(Path.home() / ".metascript")])
        denied = subprocess.run(sandbox + ["/usr/bin/clang", "--version"], capture_output=True)
        if denied.returncode == 0:
            raise RuntimeError("sandbox did not deny the system compiler")
        consumer = work / "consumer.ms"

        run(sandbox + build(old, consumer, work / "oldConsumer"), environment("old"),
            expected=1, contains="no C compiler available")
        print("control msc without adjacent discovery has no compiler: refused")

        run(sandbox + build(new, consumer, work / "consumerC"), environment("c"))
        run([str(work / "consumerC")], environment("c"), contains="native-consumer-ok 42")
        companion = work / "companionConsumer.ms"
        run(sandbox + build(new, companion, work / "consumerCpp"), environment("cpp"))
        run([str(work / "consumerCpp")], environment("cpp"), contains="42")
        print("plain C and C++20 builds select the adjacent bundle and run")

        run(sandbox + build(new, consumer, work / "consumer.wasm", "--os=wasm"), environment("wasm"))
        run(["/opt/homebrew/bin/wasmtime", str(work / "consumer.wasm")], environment("wasm"),
            contains="native-consumer-ok 42")
        run(sandbox + build(new, consumer, work / "consumerLinux", "--os=linux"), environment("linux"))
        if (work / "consumerLinux").read_bytes()[:4] != b"\x7fELF":
            raise RuntimeError("--os=linux did not produce an ELF executable")
        print("plain WASI build ran under wasmtime; plain Linux build linked an ELF executable")

        run(build(new, consumer, work / "consumerCc", "--cc=clang"), environment("cc"))
        run([str(work / "consumerCc")], environment("cc"), contains="native-consumer-ok 42")
        print("explicit --cc=clang bypasses the adjacent bundle")

        present = root / "msc-toolchain"
        parked = work / "parked"
        present.rename(parked)
        present.mkdir()
        run(sandbox + build(new, consumer, work / "emptyBundle"), environment("empty"),
            expected=1, contains="native toolchain")
        present.rmdir()
        present.symlink_to(work / "missing")
        run(sandbox + build(new, consumer, work / "brokenBundle"), environment("broken"),
            expected=1, contains="native toolchain")
        present.unlink()
        parked.rename(present)
        print("empty and broken adjacent bundles refused without falling back")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    prove(args.compiler.resolve(), args.control.resolve(), args.bundle.resolve())
