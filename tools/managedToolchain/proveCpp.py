#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import shutil

import prepareCppRuntime as cpp
import prepareEngine as pe
from prepareRuntime import elfProblem, elfInterpreterProblem, glibcSymbolProblem
from proveDefault import COMPILER_ROOT, FIXTURES, SUPPORT_TREES, build, run, sandboxProfile


def inspect(path, target, bundle, dll=False):
    if target == "native":
        return
    if target == "windows":
        problem = cpp.peCppProblem(str(path), "dll" if dll else "exe")
    else:
        problem = (elfProblem(str(path), cpp.LINUX) or elfInterpreterProblem(str(path), cpp.LINUX)
                   or glibcSymbolProblem(str(bundle / "bin/llvm-nm"), str(path), requiredSymbol="__libc_start_main"))
        if not problem:
            needed, unwind = cpp.readElf(str(path))
            if "libc.so.6" not in needed or not set(needed) <= cpp.ELF_NEEDED or not unwind:
                problem = "foreign runtime dependency or missing unwind header: %s" % needed
    if problem:
        raise RuntimeError(str(path) + ": " + problem)


def prove(compiler, control, bundle, work):
    pe.verifyEngine(str(bundle))
    work.mkdir()
    root = work / "compilerRoot"
    root.mkdir()
    for tree in SUPPORT_TREES:
        (root / tree).symlink_to(COMPILER_ROOT / tree, target_is_directory=True)
    new, old = root / "msc", root / "msc-control"
    shutil.copy2(compiler, new)
    shutil.copy2(control, old)
    moved = work / "bundle with spaces"
    shutil.copytree(bundle, moved, symlinks=True)
    for name in ("consumer.ms", "companion.cpp", "companion.h", "companionConsumer.ms", "runtimeCppDll.cpp"):
        shutil.copyfile(FIXTURES / name, work / name)
    environment = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "TMPDIR": str(work),
                   "MSC_NATIVE_TOOLCHAIN": str(moved), "MSC_NO_GLOBAL_CACHE": "1"}
    sandbox = sandboxProfile(work / "deny.sb", [str(bundle), "/opt/homebrew", str(Path.home() / ".metascript")])

    def check(label, command, expected=0, overrides=None):
        output = run(command, dict(environment, **(overrides or {})), expected=expected)
        (work / (label + ".log")).write_text(output)
        return output

    def command(label, source, output, *flags, oldCompiler=False, overrides=None, expected=0):
        return check(label, sandbox + build(old if oldCompiler else new, source, output, "--verbose", *flags),
                     expected, dict({"MSC_CACHE_DIR": str(work / ("cache-" + label.split("-")[0]))}, **(overrides or {})))

    check("deny-system", sandbox + ["/usr/bin/clang", "--version"], expected=1)
    check("deny-original", sandbox + [str(bundle / "bin/clang"), "--version"], expected=1)
    records = {}
    sourceText = (FIXTURES / "companionConsumer.ms").read_text()
    sdk = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], environment).strip()
    targets = (("native", (), None), ("linux", ("--os=linux", "--cpu=x86_64"), cpp.LINUX + ".cfg"),
               ("windows", ("--os=windows", "--cpu=x86_64"), "windows/" + cpp.WINDOWS + ".cfg"))
    for target, flags, config in targets:
        source = work / (target + "Source.ms")
        source.write_text(sourceText)
        executable = work / (target + "Source.out")
        if config:
            failed = command(target + "-old-source", source, work / (target + "Old.out"), *flags,
                             oldCompiler=True, expected=1)
            if "file not found" not in failed:
                raise RuntimeError("old CPP source failed for another reason: " + failed)
        command(target + "-source", source, executable, *flags)
        inspect(executable, target, moved)
        if target == "native":
            if check("native-execute", sandbox + [str(executable)]).strip() != "42":
                raise RuntimeError("native C++ companion did not return 42")
        source.write_text(sourceText + 'console.log("cached-companion");\n')
        warm = command(target + "-warm", source, executable, *flags)
        if not any("companion.cpp" in line and ("(cached)" in line or "(stored)" in line) for line in warm.splitlines()):
            raise RuntimeError(target + " CPP cache hit was not observed: " + warm)
        inspect(executable, target, moved)
        if target == "native" and check("native-execute-warm", sandbox + [str(executable)]).strip() != "42\ncached-companion":
            raise RuntimeError("native cached CPP companion changed its result")

        pair = ["--no-default-config"]
        if config:
            pair += ["--config=" + str(moved / "runtime" / config.replace(".cfg", ".cxx.cfg")),
                     "--config=" + str(moved / "runtime" / config)]
        else:
            pair += ["-isysroot", sdk]
        obj, archive = work / (target + ".o"), work / (target + ".a")
        check(target + "-archive-object", sandbox + [str(moved / "bin/clang++")] + pair +
              ["-std=c++20", "-c", str(work / "companion.cpp"), "-o", str(obj)])
        check(target + "-archive-create", sandbox + [str(moved / "bin/llvm-ar"), "--format=gnu", "rcs", str(archive), str(obj)])
        archiveSource = work / (target + "Archive.ms")
        archiveSource.write_text('@link("./' + archive.name + '");\n@passL("-lc++");\n' +
                                 "\n".join(line for line in sourceText.splitlines() if not line.startswith("@compile")) + "\n")
        archived = work / (target + "Archive.out")
        if config:
            failed = command(target + "-old-archive", archiveSource, work / (target + "OldArchive.out"), *flags,
                             oldCompiler=True, expected=1)
            if "unable to find library -lc++" not in failed:
                raise RuntimeError("old CPP archive failed for another reason: " + failed)
        command(target + "-archive", archiveSource, archived, *flags)
        inspect(archived, target, moved)
        if target == "native" and check("native-execute-archive", sandbox + [str(archived)]).strip() != "42":
            raise RuntimeError("native archive-only CPP consumer did not return 42")
        records[target] = {"source": pe.sha256File(str(executable)), "archive": pe.sha256File(str(archived)),
                           "verification": "executed" if target == "native" else "linked and inspected, not run"}
        print(target + ": source, CPP cache hit, archive-only -lc++ passed; " + records[target]["verification"], flush=True)

    dllSource = work / "dll.ms"
    dllSource.write_text('@compile("./runtimeCppDll.cpp", "-std=c++20");\n')
    dll, imports = work / "cpp.dll", work / "cpp.lib"
    command("windows-dll", dllSource, dll, "--os=windows", "--cpu=x86_64", "--app=lib",
            "--passL=-Wl,--out-implib," + str(imports))
    inspect(dll, "windows", moved, dll=True)
    if imports.read_bytes()[:8] != b"!<arch>\n":
        raise RuntimeError("CPP DLL import library was not produced")
    print("windows: CPP DLL/cppSum/import library linked and inspected, not run", flush=True)

    explicit = '"%s" --no-default-config "--config=%s" "--config=%s"' % (
        moved / "bin/clang", moved / "runtime" / (cpp.LINUX + ".cxx.cfg"), moved / "runtime" / (cpp.LINUX + ".cfg"))
    command("linux-override", work / "linuxSource.ms", work / "override.out", "--os=linux", "--cpu=x86_64",
            "--cc=" + explicit, overrides={"MSC_NATIVE_TOOLCHAIN": str(work / "missing")})
    inspect(work / "override.out", "linux", moved)

    identity = (moved / "IDENTITY").read_text()
    provenance = moved / "runtime" / cpp.PROVENANCE
    provenance.write_text(provenance.read_text() + "\n")
    host, version = (moved / "HOST").read_text().strip(), (moved / "VERSION").read_text().strip()
    pe.writeContract(str(moved), host, version)
    if (moved / "IDENTITY").read_text() == identity:
        raise RuntimeError("CPP payload change did not change identity")
    rebuilt = command("linux-identity", work / "linuxSource.ms", work / "identity.out", "--os=linux", "--cpu=x86_64")
    if not any("companion.cpp" in line and "(cached)" not in line and "(stored)" not in line for line in rebuilt.splitlines()):
        raise RuntimeError("CPP identity change did not rebuild companion: " + rebuilt)
    inspect(work / "identity.out", "linux", moved)
    print("explicit --cc bypass and CPP payload-identity invalidation passed", flush=True)
    (work / "results.json").write_text(json.dumps({"compiler": pe.sha256File(str(compiler)),
        "control": pe.sha256File(str(control)), "inputIdentity": identity.strip(), "targets": records,
        "limit": "Linux/Windows linked and inspected only; no Clang selfhost or provisioning certification"}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prove real managed C++ source/cache/archive builds with Zig denied.")
    for name in ("compiler", "control", "bundle", "work"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    prove(args.compiler.resolve(), args.control.resolve(), args.bundle.resolve(), args.work.resolve())
