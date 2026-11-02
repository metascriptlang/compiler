#!/usr/bin/env python3
"""Add explicit sanitizer profiles to a prepared runtime from supplied compiler-rt artifacts, then prove them with clang and lld alone.

    prepareSanitizerRuntime.py --engine ENGINE_DIR --runtime RUNTIME_DIR --payload PAYLOAD_DIR --output NEW_DIR [--target T ...]
    prepareSanitizerRuntime.py --prove --engine ENGINE_DIR --runtime RUNTIME_DIR [--target T ...] [--require-run]

RUNTIME_DIR is a bundle's `runtime/` whose C configs exist (prepareRuntime.py, prepareWindowsRuntime.py); it is only
read. ENGINE_DIR is the engine, alone or as the bundle that holds RUNTIME_DIR. PAYLOAD_DIR holds the compiler-rt
artifacts of an upstream build and `payload.json`, which names every file by role:

    {"schema": 1,
     "source": {"release": "llvmorg-23.1.0", "commit": "<40 hex>", "build": "how the artifacts were built"},
     "targets": {"x86_64-windows-gnu": {"ubsan": {"archive": "w/libclang_rt.ubsan_standalone-x86_64.a"},
                                        "asan": {"importLibrary": "...", "thunk": "...", "dll": "..."}},
                 "x86_64-linux-gnu.2.31": {"ubsan": {"archive": "...", "dynamicList": "...a.syms"}}}}

No file is found by name: a role without a path, a path outside PAYLOAD_DIR, a symlink, an unknown key or a release whose
major is not the engine's is refused. Each file is then checked by content, never by its name: archive members, PE
machine and exports, defined symbols. NEW_DIR receives an overlay of new paths, each relative to RUNTIME_DIR, which a
bundle merges:

    <target>.ubsan.cfg  <target>.ubsan/                 Linux (under windows/ for a Windows target)
    windows/<target>.asan.cfg  windows/<target>.asan/   the import library, the runtime thunk and the DLL to deploy
    notices/sanitizer-provenance.json

A profile is the partner of the base config and is named first, so its arguments precede the base config's:

    clang --no-default-config --config=<target>.ubsan.cfg --config=<target>.cfg x.c -o x

The base configs pass -nostdlib. On MinGW that suppresses the ASan libraries of the driver's link line, and UBSan has no
link-time plan there at all (only a compile-time `/defaultlib` directive). On Linux the driver still plans the runtime archives
under -nostdlib and drops only the system libraries they need. The profile therefore carries what the driver would add, in its
order. UBSan carries `-fsanitize=undefined -fno-sanitize-recover=undefined`, so the first
report prints the diagnostic with its source location and the program exits nonzero. On Linux the driver's own runtime plan is
turned off (`-fno-sanitize-link-runtime`) and replaced by the explicit whole archive and the system libraries it needs. That
archive also calls `_Unwind_Backtrace` and `_Unwind_GetIP` (sanitizer_common's slow unwinder), which only the C++ overlay's
`libunwind.a` provides, so a Linux UBSan link and its proof take the target's `<target>.cxx.cfg` first, as the compiler does for
a prepared Linux sanitizer executable. On
Windows the compile-time `/defaultlib` directive is turned off (`-fno-rtlib-defaultlib`) and the archive is a linker input. ASan
(Windows x86_64) names the import library of the DLL before the base config's startup object (the one its receipt records for the
executable variant, `crt2.obj` or `crt2.o`), then again with the runtime
thunk, `--require-defined __asan_seh_interceptor` and the thunk as a whole archive after the caller's objects; the DLL is not linked
and must be copied beside every executable (`deploy` in the receipt).
The ASan profile needs the engine's own `bin/llvm-symbolizer[.exe]` and is refused without it; the proof names it through
`ASAN_SYMBOLIZER_PATH` and requires the report to carry the source line of the overflow.

The payload is recorded by identity, not built here; the receipt says so and never certifies redistribution.
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw

FIXTURES = pr.FIXTURES
MANIFEST = "payload.json"
SCHEMA = 1
PROVENANCE = "notices/sanitizer-provenance.json"
RECEIPT_KIND = "sanitizer-runtime-payload"
RELEASE = re.compile(r"^llvmorg-(\d+)\.\d+\.\d+(-rc\d+)?$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
STEP_SECONDS = 600
RUN_SECONDS = 60
CLEAN_OUTPUT = "ok\n"
LINUX_DRIVER_LIBRARIES = ("pthread", "rt", "m", "dl", "resolv")
UBSAN_SYMBOLS = ("__ubsan_handle_add_overflow", "__ubsan_handle_add_overflow_abort")
ASAN_INIT = "__asan_init"
ASAN_THUNK_SYMBOL = "__asan_seh_interceptor"
UNWIND_SYMBOLS = ("_Unwind_Backtrace", "_Unwind_GetIP")
HOST_ENVIRONMENT = ("ASAN_OPTIONS", "UBSAN_OPTIONS", "LSAN_OPTIONS", "SANITIZER_OPTIONS", "COMPILER_PATH",
                    "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH", "SDKROOT")
LIMITS = ["the artifacts are supplied prebuilt and recorded by release, commit and sha256: this tool does not build "
          "compiler-rt and cannot attest the build recipe the manifest names",
          "C only: no vptr or C++ runtime (ubsan_standalone_cxx) and no DLL variant of any profile",
          "ASan is the Windows x86_64 dynamic runtime only, as upstream builds no other Windows ASan",
          "a Linux UBSan link takes the whole C++ overlay config only to reach its libunwind.a; no unwinder-only input exists, and "
          "aarch64-linux-gnu has no C++ overlay, so its profile is refused until it has an unwinder",
          "an executable is run only when the host can execute its target; a host that cannot reports not run and "
          "--require-run refuses it",
          "llvm-symbolizer is the engine's (bin/llvm-symbolizer[.exe]), not a file of a profile: the ASan profile is "
          "refused when the engine lacks it and the proof names it through ASAN_SYMBOLIZER_PATH, never through PATH",
          "the first UBSan report halts the program (-fno-sanitize-recover=undefined); a program that must go on after "
          "a report is not served by these profiles",
          "the proof relocates the tree to a path with a space but runs no sandbox that denies the originals"]
SYMBOLIZER = {"program": "bin/llvm-symbolizer[.exe]", "deliveredBy": "engine", "shippedByProfile": False,
              "environment": "ASAN_SYMBOLIZER_PATH", "requiredFor": "source lines in ASan frames"}
SYMBOLIZER_NAMES = ("llvm-symbolizer", "llvm-symbolizer.exe")

LINUX_X64, LINUX_ARM64 = "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"
WINDOWS_X64, WINDOWS_ARM64 = pw.TARGET, pw.ARM64_TARGET
TARGETS = {
    LINUX_X64: {"format": "elf", "machine": pr.ELF_TARGETS[LINUX_X64]["machine"], "prefix": "",
                "profiles": ("ubsan",), "base": LINUX_X64 + ".cfg"},
    LINUX_ARM64: {"format": "elf", "machine": pr.ELF_TARGETS[LINUX_ARM64]["machine"], "prefix": "",
                  "profiles": ("ubsan",), "base": LINUX_ARM64 + ".cfg"},
    WINDOWS_X64: {"format": "coff", "machine": pw.TARGETS[WINDOWS_X64]["machine"], "prefix": "windows/",
                  "profiles": ("ubsan", "asan"), "base": "windows/%s.cfg" % WINDOWS_X64},
    WINDOWS_ARM64: {"format": "coff", "machine": pw.TARGETS[WINDOWS_ARM64]["machine"], "prefix": "windows/",
                    "profiles": ("ubsan",), "base": "windows/%s.cfg" % WINDOWS_ARM64},
}
ROLES_REQUIRED_OPTIONAL = {"ubsan": (("archive",), ("dynamicList",)), "asan": (("importLibrary", "thunk", "dll"), ())}
BASE_RECEIPT_AND_ENGINE_RELATIVE = {"elf": ("notices/runtime-provenance.json", ".."),
                                    "coff": ("windows/notices/" + pw.PROVENANCE, pw.ENGINE_RELATIVE)}
CASES = {
    "ubsan": [{"fixture": "sanitizerClean.c"},
              {"fixture": "sanitizerSignedOverflow.c", "report": "runtime error: signed integer overflow",
               "locate": "big + argc"}],
    "asan": [{"fixture": "sanitizerClean.c"},
             {"fixture": "sanitizerHeapOverflow.c", "report": "ERROR: AddressSanitizer: heap-buffer-overflow",
              "locate": "p[argc + 3]"}],
}


def profileDirectory(target, profile):
    return "%s%s.%s" % (TARGETS[target]["prefix"], target, profile)


def profileConfig(target, profile):
    return profileDirectory(target, profile) + ".cfg"


def checkTargets(runtime, names):
    """The targets to prepare: those named, or every target whose base config exists. Each must be a sanitizer target
    with its base config in runtime."""
    chosen = list(names) if names else [t for t in TARGETS if os.path.isfile(os.path.join(runtime, TARGETS[t]["base"]))]
    for name in chosen:
        if name not in TARGETS:
            raise pe.EngineError("target %s has no sanitizer profile; allowed: %s" % (name, ", ".join(TARGETS)))
    if not chosen or len(set(chosen)) != len(chosen):
        raise pe.EngineError("no sanitizer target, or a duplicate, in %s" % chosen)
    for target in chosen:
        if not os.path.isfile(os.path.join(runtime, TARGETS[target]["base"])):
            raise pe.EngineError("%s has no base config %s to pair with" % (target, TARGETS[target]["base"]))
    return chosen


def exactKeys(value, required, optional, where):
    if not isinstance(value, dict):
        raise pe.EngineError("%s is not an object" % where)
    missing = [k for k in required if k not in value]
    unknown = [k for k in value if k not in required and k not in optional]
    if missing or unknown:
        raise pe.EngineError("%s: missing %s, unknown %s" % (where, missing, unknown))


def checkRelative(path, where):
    """The names of a payload path made of plain names only, so it cannot leave PAYLOAD_DIR."""
    if not isinstance(path, str) or not path:
        raise pe.EngineError("%s is not a path" % where)
    parts = path.split("/")
    if not all(pr.SAFE_NAME.match(p) and p not in (".", "..") for p in parts):
        raise pe.EngineError("%s: %r is not a relative path of plain names" % (where, path))
    return parts


def readManifest(payload, major):
    """The validated manifest of PAYLOAD_DIR and its sha256. The release must be the engine's major, because the data
    the instrumented code hands the runtime changes between majors."""
    path = os.path.join(payload, MANIFEST)
    if not os.path.isfile(path) or pe.isLinkLike(path):
        raise pe.EngineError("payload %s has no regular %s" % (payload, MANIFEST))
    with open(path, encoding="utf-8") as f:
        try:
            manifest = json.load(f)
        except ValueError as error:
            raise pe.EngineError("%s is not JSON: %s" % (path, error))
    exactKeys(manifest, ("schema", "source", "targets"), (), MANIFEST)
    if manifest["schema"] != SCHEMA:
        raise pe.EngineError("%s schema %r is not %d" % (MANIFEST, manifest["schema"], SCHEMA))
    source = manifest["source"]
    exactKeys(source, ("release", "commit", "build"), (), MANIFEST + " source")
    found = RELEASE.match(source["release"]) if isinstance(source["release"], str) else None
    if not found:
        raise pe.EngineError("source release %r is not llvmorg-MAJOR.MINOR.PATCH" % (source["release"],))
    if found.group(1) != major:
        raise pe.EngineError("compiler-rt release %s has major %s, the engine's clang is %s" % (
            source["release"], found.group(1), major))
    if not isinstance(source["commit"], str) or not COMMIT.match(source["commit"]):
        raise pe.EngineError("source commit %r is not 40 lowercase hex digits" % (source["commit"],))
    if not isinstance(source["build"], str) or not source["build"].strip():
        raise pe.EngineError("source build is empty; say how the artifacts were built")
    if not isinstance(manifest["targets"], dict) or not manifest["targets"]:
        raise pe.EngineError("%s names no target" % MANIFEST)
    for target, profiles in manifest["targets"].items():
        if target not in TARGETS:
            raise pe.EngineError("manifest target %s has no sanitizer profile; allowed: %s" % (target, ", ".join(TARGETS)))
        if not isinstance(profiles, dict) or not profiles:
            raise pe.EngineError("manifest target %s names no profile" % target)
        for profile, files in profiles.items():
            if profile not in TARGETS[target]["profiles"]:
                raise pe.EngineError("%s has no %s profile; its profiles are %s" % (
                    target, profile, ", ".join(TARGETS[target]["profiles"])))
            required, optional = ROLES_REQUIRED_OPTIONAL[profile]
            exactKeys(files, required, optional if TARGETS[target]["format"] == "elf" else (), "%s %s" % (target, profile))
            for role, relative in files.items():
                checkRelative(relative, "%s %s %s" % (target, profile, role))
    return manifest, pe.sha256File(path)


def payloadFile(payload, relative, where):
    """The regular file at relative under payload, which is never a symlink or reached through one."""
    path = payload
    for part in checkRelative(relative, where):
        path = os.path.join(path, part)
        if not os.path.lexists(path):
            raise pe.EngineError("%s: payload file %s is missing" % (where, relative))
        if pe.isLinkLike(path):
            raise pe.EngineError("%s: %s is or passes through a symlink or reparse point" % (where, relative))
    if not os.path.isfile(path):
        raise pe.EngineError("%s: payload file %s is missing" % (where, relative))
    return path


def memberMachine(name, body):
    """(format, machine) of an archive member: an ELF64 object, a COFF object, a big object or a short import member."""
    if body[:4] == b"\x7fELF":
        if len(body) < 20 or body[4] != 2 or body[5] != 1:
            raise pe.EngineError("member %s is not a little-endian ELF64 object" % name)
        return "elf", int.from_bytes(body[18:20], "little")
    if len(body) >= 8 and body[:4] == b"\0\0\xff\xff":
        return "coff", int.from_bytes(body[6:8], "little")
    if len(body) >= 20 and int.from_bytes(body[:2], "little") in (pw.MACHINE_AMD64, pw.MACHINE_ARM64):
        return "coff", int.from_bytes(body[:2], "little")
    raise pe.EngineError("member %s is neither an ELF64 object nor a COFF object of a known machine" % name)


def archiveProblem(path, target):
    """Why an archive is not made of objects of target, or None."""
    expected = (TARGETS[target]["format"], TARGETS[target]["machine"])
    with open(path, "rb") as f:
        members = pr.parseArchive(f.read())
    if not members:
        return "has no member"
    for name, body in members:
        found = memberMachine(name, body)
        if found != expected:
            return "member %s is %s machine %#x, not %s machine %#x" % (name, found[0], found[1], expected[0], expected[1])
    return None


def symbolProblem(engine, path, symbols):
    defined = {name for _, name in pc.archiveSymbols(engine, path)}
    missing = [s for s in symbols if s not in defined]
    return "defines no %s" % ", ".join(missing) if missing else None


def dllProblem(path, target):
    """Why path is not a DLL of target that exports the ASan runtime's entry, or None."""
    info = pw.readPe(path)
    if info["machine"] != pw.TARGETS[target]["machine"]:
        return "machine %#x is not %s" % (info["machine"], pw.TARGETS[target]["machineName"])
    if not info["characteristics"] & pw.DLL_CHARACTERISTIC:
        return "is not a DLL"
    if ASAN_INIT not in info["exports"]:
        return "does not export %s" % ASAN_INIT
    return None


def importLibraryProblem(path, dllName):
    with open(path, "rb") as f:
        if dllName.encode("ascii") not in f.read():
            return "names no import of %s" % dllName
    return None


def symbolizerPath(root):
    """The engine's llvm-symbolizer under root/bin. It is never looked up on PATH."""
    found = [os.path.join(root, "bin", n) for n in SYMBOLIZER_NAMES if os.path.isfile(os.path.join(root, "bin", n))]
    if len(found) != 1:
        raise pe.EngineError("engine %s has %d of %s in bin/; the ASan profile needs exactly one" % (
            root, len(found), " and ".join(SYMBOLIZER_NAMES)))
    return found[0]


def checkFiles(engine, target, profile, paths):
    """Check the files of a profile by content. paths is {role: file path}."""
    problems = {}
    if profile == "ubsan":
        problems["archive"] = archiveProblem(paths["archive"], target) or symbolProblem(engine, paths["archive"], UBSAN_SYMBOLS)
        if "dynamicList" in paths:
            with open(paths["dynamicList"], "rb") as f:
                text = f.read().decode("utf-8", "replace")
            problems["dynamicList"] = None if "__ubsan_handle" in text else "lists no __ubsan_handle symbol"
    else:
        dll = os.path.basename(paths["dll"])
        problems["dll"] = (None if dll.endswith(".dll") else "is not named *.dll") or dllProblem(paths["dll"], target)
        problems["importLibrary"] = (archiveProblem(paths["importLibrary"], target)
                                     or importLibraryProblem(paths["importLibrary"], dll)
                                     or symbolProblem(engine, paths["importLibrary"], (ASAN_INIT,)))
        problems["thunk"] = (archiveProblem(paths["thunk"], target)
                             or symbolProblem(engine, paths["thunk"], (ASAN_THUNK_SYMBOL,)))
    for role, problem in problems.items():
        if problem:
            raise pe.EngineError("%s %s %s (%s): %s" % (target, profile, role, os.path.basename(paths[role]), problem))


def tail(tokens):
    """A config line of tokens that go to the end of a link command: the driver reads the `$` of each token alone."""
    return " ".join("$" + t for t in pr.configLine(tokens).split(" "))


def linkerLine(*arguments):
    return pr.configLine([t for a in arguments for t in ("-Xlinker", a)])


def profileInput(target, profile, name):
    """How a profile config names a file of its own directory."""
    return "<CFGDIR>/%s.%s/%s" % (target, profile, pr.checkName(name))


def renderProfile(target, profile, names):
    """Text of RUNTIME/<profile config>. names maps each role to the file name in the profile's directory."""
    here = lambda role: profileInput(target, profile, names[role])
    lines = ["-fsanitize=" + ("undefined" if profile == "ubsan" else "address")]
    if profile == "ubsan":
        lines.append("-fno-sanitize-recover=undefined")
    if profile == "ubsan" and TARGETS[target]["format"] == "elf":
        lines += ["-fno-sanitize-link-runtime",
                  linkerLine("--whole-archive", here("archive"), "--no-whole-archive"),
                  linkerLine("--dynamic-list=" + here("dynamicList")) if "dynamicList" in names
                  else linkerLine("--export-dynamic")]
        lines += [tail(["-l" + n]) for n in LINUX_DRIVER_LIBRARIES]
    elif profile == "ubsan":
        lines += ["-fno-rtlib-defaultlib", linkerLine(here("archive"))]
    else:
        lines += [linkerLine(here("importLibrary")),
                  tail(["-Xlinker", here("importLibrary")]),
                  tail(["-Xlinker", here("thunk")]),
                  tail(["-Xlinker", "--require-defined", "-Xlinker", ASAN_THUNK_SYMBOL]),
                  tail(["-Xlinker", "--whole-archive", "-Xlinker", here("thunk"), "-Xlinker", "--no-whole-archive"])]
    return "\n".join(lines) + "\n"


def linkerOrder(configs):
    """What clang hands the linker for the configs named in order, as (head, tail): the `-Xlinker` values before the
    caller's inputs, and the `$` tokens after them with their `-Xlinker` words left out."""
    head, last = [], []
    for text in configs:
        for line in text.splitlines():
            tokens = line.split(" ")
            if tokens[0].startswith("$"):
                last += [t[1:] for t in tokens if t != "$-Xlinker"]
            else:
                head += [tokens[i + 1] for i in range(len(tokens) - 1) if tokens[i] == "-Xlinker"]
    return head, last


def crossCheck(target, profile, text, base, startup=None, names=None):
    """The profile agrees with the base config it pairs with: the base gives the driver no libraries of its own, and an
    ASan import library is named before the base's startup object and again in the tail with the thunk. startup is the
    startup object file name the base runtime's receipt records for the executable, names the profile's role -> file name;
    both are the explicit inputs of the ASan check, so no file is recognized by its name or extension."""
    if "-nostdlib" not in base.splitlines():
        raise pe.EngineError("%s: base config lacks -nostdlib, which the %s profile's library list assumes" % (target, profile))
    if profile != "asan":
        return
    head, _ = linkerOrder([text, base])
    library = profileInput(target, profile, names["importLibrary"])
    thunk = profileInput(target, profile, names["thunk"])
    starts = [i for i, v in enumerate(head) if os.path.basename(v) == startup]
    libraries = [i for i, v in enumerate(head) if v == library]
    if len(starts) != 1 or len(libraries) != 1 or libraries[0] > starts[0]:
        raise pe.EngineError("%s: the ASan import library must precede the base config's startup object %s: %s" % (
            target, startup, head))
    _, last = linkerOrder([text])
    if (last[:2] != [library, thunk] or last[2:5] != ["--require-defined", ASAN_THUNK_SYMBOL, "--whole-archive"]
            or last[5:] != [thunk, "--no-whole-archive"]):
        raise pe.EngineError("%s: the ASan link tail is not import library, thunk, required symbol, whole-archive thunk: %s" % (
            target, last))


def readBaseReceipt(runtime, target):
    """(the target's record in the base runtime's receipt, or None for a receipt that lists names; the startup object
    file name the receipt records for the target's executable variant, or None when it records none; sha256 of the
    receipt file). The base must be a bundle runtime prepared for target."""
    relative, engineRelative = BASE_RECEIPT_AND_ENGINE_RELATIVE[TARGETS[target]["format"]]
    path = os.path.join(runtime, relative)
    if not os.path.isfile(path):
        raise pe.EngineError("runtime %s has no %s" % (runtime, relative))
    with open(path, encoding="utf-8") as f:
        receipt = json.load(f)
    if receipt.get("engineRelative") != engineRelative:
        raise pe.EngineError("%s records engineRelative %r, not %r: the profiles need a bundle runtime" % (
            relative, receipt.get("engineRelative"), engineRelative))
    names = [r["target"] if isinstance(r, dict) else r for r in receipt.get("targets", [])]
    if target not in names:
        raise pe.EngineError("%s was not prepared for %s" % (relative, target))
    record = next((r for r in receipt["targets"] if isinstance(r, dict) and r["target"] == target), None)
    startups = {pr.checkName(v["startupObject"]) for v in receipt.get("variants", [])
                if v.get("target") == target and v.get("variant") == "exe" and "startupObject" in v}
    if len(startups) > 1:
        raise pe.EngineError("%s records %d startup objects for the %s executable: %s" % (
            relative, len(startups), target, sorted(startups)))
    return record, next(iter(startups), None), pe.sha256File(path)


def checkLibraries(target, record):
    """A Linux base runtime holds the stub of every library a sanitizer link needs, since -nostdlib drops the driver's."""
    present = {a["alias"] for a in record["libraryAliases"]}
    missing = ["lib%s.so" % n for n in LINUX_DRIVER_LIBRARIES if "lib%s.so" % n not in present]
    if missing:
        raise pe.EngineError("%s: the base runtime has no %s for the sanitizer link; prepare it again with them" % (
            target, ", ".join(missing)))


def unwinderConfig(runtime, target):
    """The C++ overlay config that supplies the unwinder a Linux UBSan archive calls, or an error naming what is missing.
    The only unwinder of a prepared Linux runtime is that overlay's libunwind.a, which has no config of its own."""
    config = target + ".cxx.cfg"
    if not os.path.isfile(os.path.join(runtime, config)):
        raise pe.EngineError("%s: the UBSan archive calls %s, which only the C++ overlay's libunwind.a provides, and the "
                             "runtime has no %s" % (target, " and ".join(UNWIND_SYMBOLS), config))
    return config


def produceProfile(engine, runtime, payload, target, profile, files, output, startup=None):
    """Copy and check one profile's files, write its config. startup is the base receipt's startup object of the
    executable, which the ASan profile needs. Returns the receipt record of the profile."""
    directory = profileDirectory(target, profile)
    paths = {role: payloadFile(payload, relative, "%s %s %s" % (target, profile, role)) for role, relative in files.items()}
    names = {role: pr.checkName(os.path.basename(path)) for role, path in paths.items()}
    if len(set(names.values())) != len(names):
        raise pe.EngineError("%s %s: two roles share a file name: %s" % (target, profile, names))
    checkFiles(engine, target, profile, paths)
    if profile == "asan":
        symbolizerPath(engine)
        if startup is None:
            raise pe.EngineError("%s: the base runtime's receipt records no startupObject for the executable variant" % target)
    unwinder = None
    if profile == "ubsan" and TARGETS[target]["format"] == "elf":
        unwinder = {"config": unwinderConfig(runtime, target), "symbols": list(UNWIND_SYMBOLS),
                    "provider": "libunwind.a of the C++ overlay"}
    destination = os.path.join(output, directory)
    os.makedirs(destination)
    records = []
    for role in sorted(paths):
        copy = os.path.join(destination, names[role])
        shutil.copyfile(paths[role], copy)
        os.chmod(copy, 0o644)
        records.append({"role": role, "name": names[role], "payloadPath": files[role],
                        "sha256": pe.sha256File(copy), "bytes": os.path.getsize(copy)})
        if records[-1]["sha256"] != pe.sha256File(paths[role]):
            raise pe.EngineError("%s: the copy of %s differs from the payload file" % (target, names[role]))
    text = renderProfile(target, profile, names)
    with open(os.path.join(runtime, TARGETS[target]["base"]), encoding="utf-8") as f:
        crossCheck(target, profile, text, f.read(), startup, names)
    pe.writeText(os.path.join(output, profileConfig(target, profile)), text)
    deploy = [{"name": names["dll"], "path": "%s/%s" % (directory, names["dll"]), "destination": "beside every executable",
               "sha256": next(r["sha256"] for r in records if r["role"] == "dll")}] if profile == "asan" else []
    return {"target": target, "profile": profile, "config": profileConfig(target, profile),
            "base": TARGETS[target]["base"], "directory": directory,
            "flags": [l for l in text.splitlines() if l.startswith("-f")],
            "files": records, "deploy": deploy, "unwinder": unwinder,
            "symbolizer": SYMBOLIZER if profile == "asan" else None}


def writeProvenance(output, host, engineVersion, manifest, manifestSha256, baseSha256, records):
    receipt = {
        "kind": RECEIPT_KIND,
        "statement": "Compiler-rt artifacts supplied explicitly and recorded by identity, added to a prepared runtime. "
                     "Not built by this tool and not an upstream-controlled build.",
        "redistributionCertified": False,
        "producerHost": host, "engineVersion": engineVersion, "source": manifest["source"],
        "payloadManifestSha256": manifestSha256, "baseRuntimeProvenanceSha256": baseSha256,
        "profiles": records, "files": pc.overlayFiles(output), "limits": LIMITS,
    }
    pe.writeText(os.path.join(output, PROVENANCE), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def hostCanRun(target):
    machine = platform.machine().lower()
    x64, arm64 = machine in ("x86_64", "amd64"), machine in ("aarch64", "arm64")
    onX64 = target in (LINUX_X64, WINDOWS_X64)
    system = sys.platform.startswith("linux") if TARGETS[target]["format"] == "elf" else sys.platform == "win32"
    return system and (x64 if onX64 else arm64)


def environment(extra=None):
    return dict({k: v for k, v in os.environ.items() if k not in HOST_ENVIRONMENT}, **(extra or {}))


def lineOf(path, text):
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            if text in line:
                return number
    raise pe.EngineError("%s has no line with %r" % (path, text))


def runStep(name, command, work):
    done = subprocess.run(command, cwd=work, env=environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=STEP_SECONDS)
    if done.returncode != 0 or done.stderr.strip():
        raise pe.EngineError("%s failed (%d) or warned: %s" % (name, done.returncode, done.stderr.strip()))
    return done


def runProgram(command, work, extra=None):
    return subprocess.run(command, cwd=work, env=environment(extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=RUN_SECONDS)


def checkRun(record, case, done):
    """A clean program exits 0 printing ok; a faulty one prints the sanitizer's report and exits nonzero. A trap,
    which prints nothing, is neither."""
    where = "%s %s %s" % (record["target"], record["profile"], case["fixture"])
    if "report" not in case:
        if done.returncode != 0 or done.stdout != CLEAN_OUTPUT or done.stderr:
            raise pe.EngineError("%s: exited %d with %r %r, expected a clean run" % (where, done.returncode, done.stdout, done.stderr))
        return
    if done.returncode == 0:
        raise pe.EngineError("%s: exited 0 after a fault; the sanitizer did not stop the program" % where)
    if case["report"] not in done.stderr:
        raise pe.EngineError("%s: exited %d without %r in stderr: %r" % (where, done.returncode, case["report"], done.stderr))
    if "locate" in case:
        located = "%s:%d:" % (case["fixture"], lineOf(os.path.join(FIXTURES, case["fixture"]), case["locate"]))
        if located not in done.stderr:
            raise pe.EngineError("%s: the report names no source location %s: %r" % (where, located, done.stderr))


def checkProfile(clang, runtime, work, record, execute):
    """Compile, link and, when execute, run every case of the profile through its config pair."""
    unwinder = ["--config=" + os.path.join(runtime, record["unwinder"]["config"])] if record.get("unwinder") else []
    configs = ["--no-default-config"] + unwinder + ["--config=" + os.path.join(runtime, record["config"]),
                                                  "--config=" + os.path.join(runtime, record["base"])]
    coff = TARGETS[record["target"]]["format"] == "coff"
    scratch = os.path.join(work, "%s-%s" % (record["target"], record["profile"]))
    os.makedirs(scratch)
    for item in record["deploy"]:
        shutil.copyfile(os.path.join(runtime, item["path"]), os.path.join(scratch, item["name"]))
    for case in CASES[record["profile"]]:
        stem = os.path.splitext(case["fixture"])[0]
        obj, binary = os.path.join(scratch, stem + ".o"), os.path.join(scratch, stem + (".exe" if coff else ".out"))
        fixture = os.path.join(FIXTURES, case["fixture"])
        runStep("compile %s" % case["fixture"], [clang] + configs + ["-O1"] + (["-g"] if record["profile"] == "asan" else []) + ["-c", fixture, "-o", obj], scratch)
        runStep("link %s" % case["fixture"], [clang] + configs + [obj, "-o", binary], scratch)
        if coff:
            imports = {n.lower() for n in pw.readPe(binary)["imports"]}
            for item in record["deploy"]:
                if item["name"].lower() not in imports:
                    raise pe.EngineError("%s %s imports %s, not %s" % (
                        record["target"], case["fixture"], sorted(imports), item["name"]))
        if execute:
            extra = None
            if record["profile"] == "asan":
                extra = {"ASAN_SYMBOLIZER_PATH": symbolizerPath(os.path.dirname(os.path.dirname(clang)))}
            checkRun(record, case, runProgram([binary], scratch, extra))


def engineView(engine, runtime, work):
    """engine, or when runtime is its `runtime` child a directory of links to every other entry, since the verify tree
    brings its own runtime."""
    if os.path.realpath(runtime) != os.path.join(os.path.realpath(engine), "runtime"):
        return engine
    view = os.path.join(work, "engine view")
    os.makedirs(view)
    for name in os.listdir(engine):
        if name != "runtime":
            os.symlink(os.path.join(engine, name), os.path.join(view, name))
    return view


def verifyTree(engine, runtime, overlay, work):
    """A tree shaped like a bundle, in a path with a space: the engine entries beside a copy of runtime with the overlay
    merged. Returns (root, merged runtime)."""
    root = os.path.join(work, "verify tree")
    merged = os.path.join(root, "runtime")
    os.makedirs(root)
    shutil.copytree(runtime, merged, symlinks=True)
    pr.linkEngineBeside(engineView(engine, runtime, work), root, merged)
    pc.mergeOverlay(overlay, merged)
    return root, merged


def checkProfiles(root, merged, records, work, requireRun):
    """checkProfile for every record; a profile the host cannot run is reported, and refused under requireRun."""
    clang = os.path.join(root, "bin", "clang")
    for record in records:
        execute = hostCanRun(record["target"])
        if requireRun and not execute:
            raise pe.EngineError("%s cannot be run on this host (%s %s) and --require-run is set" % (
                record["target"], sys.platform, platform.machine()))
        checkProfile(clang, merged, work, record, execute)
        print("%s %s: compiled and linked%s" % (record["target"], record["profile"],
                                                 "; clean run, report and nonzero exit checked" if execute
                                                 else "; NOT RUN on this host"))


def prepareSanitizerRuntime(engine, runtime, payload, output, targets=None, requireRun=False):
    """Write the sanitizer overlay of `targets` (every target of the manifest when none) to the new directory `output`,
    proven on a copy of `runtime` with the engine beside it. Returns (output, receipt)."""
    engine, runtime, payload, output = (os.path.abspath(p) for p in (engine, runtime, payload, output))
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    host, version, major = pr.engineMajor(engine)
    manifest, manifestSha256 = readManifest(payload, major)
    targets = checkTargets(runtime, targets or list(manifest["targets"]))
    unlisted = [t for t in targets if t not in manifest["targets"]]
    if unlisted:
        raise pe.EngineError("payload manifest names no files for %s" % ", ".join(unlisted))
    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    work = os.path.realpath(tempfile.mkdtemp(prefix="prepareSanitizerRuntime-"))
    try:
        baseSha256, records = {}, []
        for target in targets:
            record, startup, sha256 = readBaseReceipt(runtime, target)
            baseSha256[BASE_RECEIPT_AND_ENGINE_RELATIVE[TARGETS[target]["format"]][0]] = sha256
            if TARGETS[target]["format"] == "elf":
                checkLibraries(target, record)
            for profile, files in manifest["targets"][target].items():
                records.append(produceProfile(engine, runtime, payload, target, profile, files, partial, startup))
        receipt = writeProvenance(partial, host, version, manifest, manifestSha256, baseSha256, records)
        root, merged = verifyTree(engine, runtime, partial, work)
        checkProfiles(root, merged, records, work, requireRun)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return output, receipt


def verifyReceiptFiles(runtime, receipt):
    """Every file the receipt names is in runtime, byte for byte."""
    for record in receipt["profiles"]:
        for item in record["files"]:
            path = os.path.join(runtime, record["directory"], item["name"])
            if (not os.path.isfile(path) or pe.isLinkLike(path) or pe.sha256File(path) != item["sha256"]
                    or os.path.getsize(path) != item["bytes"]):
                raise pe.EngineError("%s/%s differs from the receipt" % (record["directory"], item["name"]))
        if not os.path.isfile(os.path.join(runtime, record["config"])):
            raise pe.EngineError("config %s is missing" % record["config"])


def prove(engine, runtime, targets=None, requireRun=False):
    """Relocate the engine and its `runtime` child, which holds the overlay, to a path with a space and run every profile
    its receipt names."""
    engine, runtime = os.path.realpath(engine), os.path.realpath(runtime)
    pe.verifyEngine(engine)
    if runtime != os.path.join(engine, "runtime"):
        raise pe.EngineError("runtime %s is not the `runtime` child of engine %s" % (runtime, engine))
    with open(os.path.join(runtime, PROVENANCE), encoding="utf-8") as f:
        receipt = json.load(f)
    if receipt.get("kind") != RECEIPT_KIND or receipt.get("redistributionCertified") is not False:
        raise pe.EngineError("%s is not a %s receipt of a local proof" % (PROVENANCE, RECEIPT_KIND))
    verifyReceiptFiles(runtime, receipt)
    records = [r for r in receipt["profiles"] if not targets or r["target"] in targets]
    if not records:
        raise pe.EngineError("the receipt has no profile for %s" % (targets,))
    work = os.path.realpath(tempfile.mkdtemp(prefix="sanitizer-proof-"))
    try:
        root = os.path.join(work, "relocated tree")
        shutil.copytree(engine, root, symlinks=True)
        checkProfiles(root, os.path.join(root, "runtime"), records, work, requireRun)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--payload")
    parser.add_argument("--output")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--prove", action="store_true")
    parser.add_argument("--require-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.prove:
            prove(args.engine, args.runtime, args.target, args.require_run)
        else:
            if not (args.payload and args.output):
                parser.error("--payload and --output are required")
            output, receipt = prepareSanitizerRuntime(args.engine, args.runtime, args.payload, args.output, args.target,
                                                      args.require_run)
            print("%d profiles, %d files" % (len(receipt["profiles"]), len(receipt["files"]) + 1))
            print("overlay written to %s" % output)
    except pe.EngineError as error:
        print("prepareSanitizerRuntime: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
