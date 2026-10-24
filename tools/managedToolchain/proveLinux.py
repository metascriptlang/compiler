#!/usr/bin/env python3
"""Prove prepared msc GNU/Linux builds without Zig or a system compiler; inspect, never execute."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile

from prepareRuntime import elfProblem, elfInterpreterProblem, glibcSymbolProblem
from proveDefault import COMPILER_ROOT, FIXTURES, SUPPORT_TREES, build, run, sandboxProfile


def prove(compiler, control, bundle):
    with tempfile.TemporaryDirectory(prefix="msc-linux-proof-") as temporary:
        work = Path(temporary).resolve()
        root = work / "compilerRoot"
        root.mkdir()
        for tree in SUPPORT_TREES:
            (root / tree).symlink_to(COMPILER_ROOT / tree, target_is_directory=True)
        new, old = root / "msc", root / "msc-control"
        shutil.copy2(compiler, new)
        shutil.copy2(control, old)
        source = work / "consumer.ms"
        shutil.copyfile(FIXTURES / "consumer.ms", source)
        sandbox = sandboxProfile(work / "deny.sb", ["/opt/homebrew", str(Path.home() / ".metascript")])
        environment = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "TMPDIR": str(work),
                       "MSC_NATIVE_TOOLCHAIN": str(bundle), "MSC_NO_GLOBAL_CACHE": "1",
                       "MSC_CACHE_DIR": str(work / "cache")}
        run(sandbox + ["/usr/bin/clang", "--version"], environment, expected=1)
        run(sandbox + build(old, source, work / "old", "--os=linux", "--cpu=arm64"), environment,
            expected=1, contains="prepared runtime for linux/arm64 is not installed")
        print("control: missing ARM64 GNU/Linux selection reproduced")
        for cpu, target in (("x86_64", "x86_64-linux-gnu.2.31"), ("arm64", "aarch64-linux-gnu.2.31")):
            flags = ("--os=linux", "--cpu=" + cpu)
            binary = work / cpu
            run(sandbox + build(new, source, binary, *flags), environment)
            problem = (elfProblem(str(binary), target) or elfInterpreterProblem(str(binary), target)
                       or glibcSymbolProblem(str(bundle / "bin/llvm-nm"), str(binary),
                                             requiredSymbol="__libc_start_main"))
            if problem:
                raise RuntimeError(problem)
            print("%s: ELF64 architecture/interpreter and GLIBC<=2.31 verified; linked, not run" % cpu)
            for flag, reason in (("--hcr", "HCR"), ("--app=lib", "lib"), ("--app=staticlib", "staticlib")):
                run(sandbox + build(new, source, work / "unsupported", *flags, flag), environment,
                    expected=1, contains="does not supply " + reason + " startup")
        print("both architectures: unsupported GNU shared/HCR/static startup refused explicitly")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    prove(args.compiler.resolve(), args.control.resolve(), args.bundle.resolve())
