#!/usr/bin/env python3
"""Prove msc builds prepared Windows executables and DLLs without Zig or a system compiler."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile

from prepareWindowsRuntime import readPe, peProblem, MACHINE_AMD64, DLL_CHARACTERISTIC, SUBSYSTEM_CONSOLE
from proveDefault import COMPILER_ROOT, FIXTURES, SUPPORT_TREES, build, run, sandboxProfile


def prove(compiler, control, bundle):
    with tempfile.TemporaryDirectory(prefix="msc-windows-proof-") as temporary:
        work = Path(temporary).resolve()
        root = work / "compilerRoot"
        root.mkdir()
        for tree in SUPPORT_TREES:
            (root / tree).symlink_to(COMPILER_ROOT / tree, target_is_directory=True)
        new, old = root / "msc", root / "msc-control"
        shutil.copy2(compiler, new)
        shutil.copy2(control, old)
        for name in ("consumer.ms", "runtimeWindowsDll.c"):
            shutil.copyfile(FIXTURES / name, work / name)
        library = work / "library.ms"
        library.write_text('@compile("./runtimeWindowsDll.c");\n' + (FIXTURES / "consumer.ms").read_text())
        sandbox = sandboxProfile(work / "deny.sb", ["/opt/homebrew", str(Path.home() / ".metascript")])
        environment = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "TMPDIR": str(work),
                       "MSC_NATIVE_TOOLCHAIN": str(bundle), "MSC_NO_GLOBAL_CACHE": "1",
                       "MSC_CACHE_DIR": str(work / "cache")}
        run(sandbox + ["/usr/bin/clang", "--version"], environment, expected=1)
        flags = ("--os=windows", "--cpu=x86_64")
        failure = run(sandbox + build(old, work / "consumer.ms", work / "old.exe", *flags),
                      environment, expected=1)
        if not any(message in failure for message in (
                "prepared runtime for windows/x86_64 is not installed",
                "call to undeclared function 'GetCurrentThreadStackLimits'")):
            raise RuntimeError("control failed for an unrelated reason:\n" + failure)
        print("control: Windows selection or platform-baseline regression reproduced")

        executable = work / "consumer.exe"
        run(sandbox + build(new, work / "consumer.ms", executable, *flags), environment)
        pe = readPe(executable)
        if (pe["machine"] != MACHINE_AMD64 or pe["characteristics"] & DLL_CHARACTERISTIC
                or pe["subsystem"] != SUBSYSTEM_CONSOLE):
            raise RuntimeError("msc did not produce an AMD64 console executable: %r" % pe)
        print("msc executable: AMD64 console PE linked with Zig and system compiler denied; not run")

        dll, imports = work / "consumer.dll", work / "consumer.lib"
        run(sandbox + build(new, library, dll, *flags, "--app=lib", "--passL=-Wl,--out-implib," + str(imports)),
            environment)
        problem = peProblem("dll", readPe(dll))
        if problem:
            raise RuntimeError(problem)
        if imports.read_bytes()[:8] != b"!<arch>\n":
            raise RuntimeError("msc did not produce an import archive")
        print("msc DLL: AMD64 PE, addNumbers export, Win32/CRT imports and import library verified; not run")
        for flag, reason in (("--hcr", "HCR"), ("--app=staticlib", "staticlib")):
            run(sandbox + build(new, work / "consumer.ms", work / "unsupported", *flags, flag),
                environment, expected=1, contains="does not supply " + reason + " startup")
        print("unsupported prepared Windows HCR/static startup refused explicitly")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    prove(args.compiler.resolve(), args.control.resolve(), args.bundle.resolve())
