#!/usr/bin/env python3
"""Prove prepared msc GNU/Linux builds without Zig or a system compiler; inspect, never execute."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile

from prepareRuntime import elfProblem, elfInterpreterProblem, elfSharedProblem, glibcSymbolProblem
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
        sandbox = sandboxProfile(work / "deny.sb", ["/opt/homebrew", "/usr/bin/ar", str(Path.home() / ".metascript")])
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
            archive = work / (cpu + ".a")
            run(sandbox + build(new, source, archive, *flags, "--app=staticlib"), environment)
            if archive.read_bytes()[:8] != b"!<arch>\n":
                raise RuntimeError("msc did not produce a static archive for " + cpu)
            profile = bundle / "runtime" / (target + ".so.cfg")
            if not profile.is_file():
                raise RuntimeError("missing shared runtime profile: " + str(profile))
            for mode, flag in (("shared", "--app=lib"), ("hcr", "--hcr")):
                image = work / (cpu + "-" + mode + ".so")
                run(sandbox + build(new, source, image, *flags, flag), environment)
                images = (image, image.with_suffix(".core.so")) if mode == "hcr" else (image,)
                for artifact in images:
                    problem = elfSharedProblem(str(artifact), target)
                    if problem:
                        raise RuntimeError(str(artifact) + ": " + problem)
            print("%s: static archive, shared object and HCR entry/core ELF64 shared images verified; not run" % cpu)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    prove(args.compiler.resolve(), args.control.resolve(), args.bundle.resolve())
