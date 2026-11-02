import contextlib
import io
import json
import os
import shutil
import struct
import tempfile
import unittest
from unittest import mock

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSanitizerRuntime as san
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws

REV = pws.LLVM_PINS["23.1.0"]
X64, ARM64 = pw.TARGET, pw.ARM64_TARGET
TARGETS = [X64, ARM64]
MACHINES = {X64: pw.TARGETS[X64]["machine"], ARM64: pw.TARGETS[ARM64]["machine"]}
DLL = san.ASAN_DLL_NAME % "x86_64"
SOURCES = {"llvm-project": {"rev": REV, "version": "23.1.0", "major": "23"}}
BASE_RECEIPT = {"kind": pws.RECEIPT_KIND, "targets": TARGETS, "sources": SOURCES}
CPP_RECEIPT = {"kind": pwc.RECEIPT_KIND, "targets": TARGETS, "sources": SOURCES}
DLL_INFO = {"machine": MACHINES[X64], "subsystem": 3, "characteristics": 0x2022, "exports": san.DLL_MARKERS + ["__asan_init"],
            "imports": {"KERNEL32.dll": [], "api-ms-win-crt-runtime-l1-1-0.dll": [], "api-ms-win-core-synch-l1-2-0.dll": []}}


def write(path, data=b"x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def coff(machine, extra=b""):
    return struct.pack("<H", machine) + bytes(18) + extra


def bigobj(machine):
    return struct.pack("<HHHH", 0, 0xFFFF, 2, machine) + bytes(4) + san.BIGOBJ_CLASS_ID + bytes(28)


def shortImport(machine, symbol, dll, export=""):
    strings = (symbol + "\0" + dll + "\0" + (export + "\0" if export else "")).encode("ascii")
    return struct.pack("<HHHHIIHH", 0, 0xFFFF, 0, machine, 0, len(strings), 0, 0) + strings


def header(name, body):
    return ("%-16s%-12s%-6s%-6s%-8s%-10d`\n" % (name, "0", "0", "0", "644", len(body))).encode("ascii") \
        + body + (b"\n" if len(body) % 2 else b"")


def archive(members):
    """A GNU archive; a name of 16 characters or more goes through the long name table."""
    longNames, entries = b"", []
    for name, body in members:
        if len(name) < 16:
            entries.append((name + "/", body))
        else:
            entries.append(("/%d" % len(longNames), body))
            longNames += name.encode("ascii") + b"/\n"
    out = b"!<arch>\n" + (header("//", longNames) if longNames else b"")
    return out + b"".join(header(ident, body) for ident, body in entries)


def importLibrary(machine, dll=DLL, markers=san.DLL_MARKERS, descriptor=True, thunk=True):
    stem = dll[:-len(".dll")]
    members = []
    if descriptor:
        members.append((dll, coff(machine, san.DESCRIPTOR_PREFIX + stem.encode())))
    if thunk:
        members.append((dll, coff(machine, b"\x7f" + stem.encode() + b"_NULL_THUNK_DATA")))
    members += [(dll, shortImport(machine, marker, dll)) for marker in markers]
    return archive(members)


def assetBytes(spec, target):
    machine = MACHINES[target]
    if spec["role"] == "asan-import":
        return importLibrary(machine)
    if spec["role"] == "asan-dll":
        return b"MZ fake dll\n"
    return archive([("a.o", coff(machine)), ("b.o", bigobj(machine))])


def symbolsOf(engine, path):
    name = os.path.basename(path)
    if "thunk" in name:
        return san.THUNK_MARKERS
    if name.endswith(".dll.a"):
        stem = DLL[:-len(".dll")]
        return ["__IMPORT_DESCRIPTOR_" + stem, "__NULL_IMPORT_DESCRIPTOR", "\x7f" + stem + "_NULL_THUNK_DATA"]
    return san.UBSAN_CXX_MARKERS if "_cxx" in name else san.UBSAN_MARKERS


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareWindowsSanitizerRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)
        patches = [mock.patch.object(san, "archiveNames", side_effect=lambda e, p: set(symbolsOf(e, p))),
                   mock.patch.object(san, "readDll", return_value=DLL_INFO)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def makeInstall(self, target, name=None, extra=(), leave=(), replace=None):
        """A fake prefix of target holding its allowlisted files, with `extra` files added, `leave` left out and
        `replace` {file name: bytes} overriding the contents."""
        prefix = tempfile.mkdtemp(prefix=(name or target + "-san") + "-", dir=self.dir)
        for spec in san.assetSpecs(target):
            if spec["name"] not in leave:
                data = (replace or {}).get(spec["name"], assetBytes(spec, target))
                write(os.path.join(prefix, "lib", "windows", spec["name"]), data)
        for relative in extra:
            write(os.path.join(prefix, *relative.split("/")), b"extra " + relative.encode() + b"\n")
        return prefix

    def symlink(self, target, link):
        try:
            os.symlink(target, link)
        except (OSError, NotImplementedError):
            self.skipTest("this host cannot create a symlink")


class RecipeTest(TempCase):
    def setUp(self):
        super().setUp()
        self.stage = self.path("stage")
        for name in ("clang", "clang++", "llvm-ar", "llvm-ranlib"):
            write(os.path.join(self.stage, "bin", name))
        self.llvm = self.path("llvm")

    def command(self, target=X64, tools=None):
        return san.sanitizerCommand(self.llvm, self.stage, target, self.path("build"), self.path("prefix"),
                                    tools or {"cmake": "/t/cmake", "ninja": "/t/ninja"}, "/t/python3")

    def definitions(self, command):
        return dict(word[2:].split("=", 1) for word in command if word.startswith("-D"))

    def test_the_source_is_the_monorepos_compiler_rt_directory_with_no_cache_and_no_builtins_subdirectory(self):
        command = self.command()
        self.assertEqual(command[command.index("-S") + 1], os.path.join(self.llvm, "compiler-rt"))
        self.assertNotIn("-C", command)
        self.assertEqual(self.definitions(command)["COMPILER_RT_BUILD_BUILTINS"], "OFF")

    def test_only_the_asan_component_and_the_sanitizer_directory_are_built_and_no_other_runtime(self):
        found = self.definitions(self.command())
        self.assertEqual(found["COMPILER_RT_BUILD_SANITIZERS"], "ON")
        self.assertEqual(found["COMPILER_RT_SANITIZERS_TO_BUILD"], "asan")
        for name in ("XRAY", "LIBFUZZER", "PROFILE", "CTX_PROFILE", "MEMPROF", "ORC", "GWP_ASAN"):
            self.assertEqual(found["COMPILER_RT_BUILD_" + name], "OFF", name)
        self.assertEqual(found["COMPILER_RT_INCLUDE_TESTS"], "OFF")

    def test_the_toolchain_uses_the_builtins_library_the_one_target_and_libcxx_as_the_cxx_abi(self):
        found = self.definitions(self.command())
        self.assertEqual((found["COMPILER_RT_USE_BUILTINS_LIBRARY"], found["COMPILER_RT_DEFAULT_TARGET_ONLY"],
                          found["SANITIZER_CXX_ABI"]), ("ON", "ON", "libc++"))
        for target, triple in ((X64, "x86_64-w64-windows-gnu"), (ARM64, "aarch64-w64-windows-gnu")):
            found = self.definitions(self.command(target))
            for language in ("C", "CXX", "ASM"):
                self.assertEqual(found["CMAKE_%s_COMPILER_TARGET" % language], triple)
                self.assertEqual(found["CMAKE_%s_COMPILER_WORKS" % language], "TRUE")
            self.assertEqual((found["CMAKE_SYSTEM_NAME"], found["CMAKE_INSTALL_PREFIX"], found["Python3_EXECUTABLE"]),
                             ("Windows", self.path("prefix"), "/t/python3"))

    def test_no_llvm_package_can_be_found_so_the_checkouts_own_fallback_is_the_only_path(self):
        found = self.definitions(self.command())
        self.assertEqual(found["CMAKE_DISABLE_FIND_PACKAGE_LLVM"], "TRUE")
        self.assertEqual(found["LLVM_CONFIG_PATH"], "")
        self.assertFalse([n for n in found if n in ("LLVM_DIR", "LLVM_CMAKE_DIR", "CMAKE_PREFIX_PATH", "LLVM_MAIN_SRC_DIR")])
        for name in ("llvm/cmake/modules/AddLLVM.cmake", "compiler-rt/cmake/Modules/CompilerRTMockLLVMCMakeConfig.cmake",
                     "compiler-rt/CMakeLists.txt", "cmake/Modules/LLVMVersion.cmake"):
            self.assertIn(name, san.LLVM_MARKERS)

    def test_c_flags_carry_the_c_config_and_the_payload_directory_and_cxx_flags_the_cxx_config_first(self):
        for target in TARGETS:
            found = self.definitions(self.command(target))
            windows = os.path.join(self.stage, "runtime", "windows")
            base = os.path.join(windows, target + ".cfg")
            cFlags = "--no-default-config --config=%s -Xlinker -L -Xlinker %s" % (base, os.path.join(windows, target + ".cxx"))
            self.assertEqual(found["CMAKE_C_FLAGS_INIT"], cFlags)
            self.assertEqual(found["CMAKE_ASM_FLAGS_INIT"], cFlags)
            self.assertEqual(found["CMAKE_CXX_FLAGS_INIT"], "--no-default-config --config=%s --config=%s" % (
                os.path.join(windows, target + ".cxx.cfg"), base))
            self.assertNotIn(".cxx.cfg", found["CMAKE_C_FLAGS_INIT"])
            self.assertEqual(found["CMAKE_C_COMPILER"], os.path.join(self.stage, "bin", "clang"))

    def test_ninja_is_used_when_found_and_makefiles_when_not(self):
        self.assertEqual(self.command()[self.command().index("-G") + 1], "Ninja")
        without = self.command(tools={"cmake": "/t/cmake"})
        self.assertEqual(without[without.index("-G") + 1], "Unix Makefiles")
        self.assertFalse([w for w in without if w.startswith("-DCMAKE_MAKE_PROGRAM")])


class ConfigureTest(unittest.TestCase):
    LOG = 'x\n-- %s\n-- LLVM_MAIN_SRC_DIR: "%s"\n' % (san.MOCK_MESSAGE, os.path.join("/llvm", "llvm"))
    CACHE = "COMPILER_RT_HAS_LIBCXX:INTERNAL=1\n"

    def test_the_fallback_with_a_passing_libcxx_probe_is_accepted(self):
        self.assertIsNone(san.configureProblem(self.CACHE, self.LOG, "/llvm"))

    def test_a_configure_that_found_an_llvm_package_or_skipped_the_fallback_is_refused(self):
        self.assertIn("own LLVM fallback", san.configureProblem(self.CACHE, "x\n", "/llvm"))
        self.assertIn("did not name", san.configureProblem(self.CACHE, self.LOG, "/other"))
        self.assertIn("found an LLVM package at /usr/lib/llvm/cmake", san.configureProblem(
            self.CACHE + "LLVM_DIR:PATH=/usr/lib/llvm/cmake\n", self.LOG, "/llvm"))
        self.assertIsNone(san.configureProblem(self.CACHE + "LLVM_DIR:PATH=LLVM_DIR-NOTFOUND\n", self.LOG, "/llvm"))

    def test_a_failed_or_missing_libcxx_probe_is_refused(self):
        for cache in ("COMPILER_RT_HAS_LIBCXX:INTERNAL=\n", "x:INTERNAL=1\n", "COMPILER_RT_HAS_LIBCXX:INTERNAL=0\n"):
            self.assertIn("libc++ probe", san.configureProblem(cache, self.LOG, "/llvm"), cache)


class AssetSpecTest(unittest.TestCase):
    def test_x64_carries_two_ubsan_archives_the_asan_import_library_the_thunk_and_the_dll(self):
        self.assertEqual([(s["name"], s["role"]) for s in san.assetSpecs(X64)], [
            ("libclang_rt.ubsan_standalone-x86_64.a", "ubsan"), ("libclang_rt.ubsan_standalone_cxx-x86_64.a", "ubsan-cxx"),
            ("libclang_rt.asan_dynamic-x86_64.dll.a", "asan-import"),
            ("libclang_rt.asan_dynamic_runtime_thunk-x86_64.a", "asan-thunk"),
            ("libclang_rt.asan_dynamic-x86_64.dll", "asan-dll")])

    def test_arm64_carries_exactly_the_two_ubsan_archives(self):
        self.assertEqual([s["name"] for s in san.assetSpecs(ARM64)], [
            "libclang_rt.ubsan_standalone-aarch64.a", "libclang_rt.ubsan_standalone_cxx-aarch64.a"])

    def test_archives_go_to_the_resource_tree_and_only_the_dll_to_the_target_bin_directory(self):
        paths = {s["name"]: san.overlayPath(X64, s) for s in san.assetSpecs(X64)}
        self.assertEqual(paths[DLL], "windows/x86_64-windows-gnu/bin/" + DLL)
        for name, path in paths.items():
            if name != DLL:
                self.assertEqual(path, "windows-sanitizers/resource/lib/windows/" + name)
        self.assertEqual(san.ownedRoots([ARM64]), ["windows-sanitizers/resource", "notices/windows-sanitizer"])
        self.assertIn("windows/x86_64-windows-gnu/bin", san.ownedRoots(TARGETS))


class InstallListingTest(TempCase):
    def classify(self, target, **options):
        return san.classifyInstall(san.installFiles(self.makeInstall(target, **options)), target)

    def test_the_exact_allowlist_is_accepted_for_both_targets_with_nothing_not_carried(self):
        self.assertEqual(self.classify(X64), [])
        self.assertEqual(self.classify(ARM64, name="arm"), [])

    def test_the_known_installed_extras_are_recorded_as_not_carried(self):
        extra = ["lib/windows/libclang_rt.stats-x86_64.a", "lib/windows/libclang_rt.stats_client-x86_64.a",
                 "lib/windows/libclang_rt.ubsan_loop_detect-x86_64.a", "include/sanitizer/asan_interface.h",
                 "share/asan_ignorelist.txt"]
        self.assertEqual(self.classify(X64, extra=extra), sorted(extra))

    def test_the_sanitizer_headers_are_not_asan_files_of_an_arm64_install(self):
        self.assertEqual(self.classify(ARM64, extra=["include/sanitizer/asan_interface.h"]),
                         ["include/sanitizer/asan_interface.h"])

    def test_an_unexpected_file_is_refused_by_name(self):
        for extra in ("lib/windows/libclang_rt.ubsan_standalone-x86_64.dll", "lib/windows/libclang_rt.stats-aarch64.a",
                      "include/xray/xray_interface.h", "lib/windows/libclang_rt.profile-x86_64.a", "bin/tool"):
            with self.assertRaisesRegex(pe.EngineError, "outside the allowlist"):
                self.classify(X64, extra=[extra])

    def test_any_asan_library_of_arm64_is_refused(self):
        for extra in ("lib/windows/libclang_rt.asan_dynamic-aarch64.dll", "lib/windows/libclang_rt.asan-aarch64.a"):
            with self.assertRaisesRegex(pe.EngineError, "Windows ASan is x86_64 only"):
                self.classify(ARM64, extra=[extra])

    def test_a_missing_required_file_is_refused_by_name(self):
        for leave in san.assetSpecs(X64):
            with self.assertRaisesRegex(pe.EngineError, "lacks .*" + leave["name"].replace(".", r"\.")):
                self.classify(X64, leave=[leave["name"]])

    def test_a_link_a_reparse_point_or_a_missing_prefix_is_refused_before_anything_is_opened(self):
        prefix = self.makeInstall(X64)
        self.symlink(os.path.join(prefix, "lib"), os.path.join(prefix, "alias"))
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            san.installFiles(prefix)
        with self.assertRaisesRegex(pe.EngineError, "is not a directory"):
            san.installFiles(self.path("nowhere"))
        other = self.makeInstall(X64, name="other")
        os.remove(os.path.join(other, "lib", "windows", san.assetSpecs(X64)[0]["name"]))
        self.symlink(os.path.join(prefix, "lib", "windows", san.assetSpecs(X64)[0]["name"]),
                     os.path.join(other, "lib", "windows", san.assetSpecs(X64)[0]["name"]))
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            san.installFiles(other)

    def test_an_unsafe_name_is_refused(self):
        prefix = self.makeInstall(X64, extra=["lib/windows/bad name.a"])
        with self.assertRaisesRegex(pe.EngineError, "unsupported name"):
            san.installFiles(prefix)


class MemberTest(unittest.TestCase):
    def test_object_bigobj_and_short_import_members_are_told_apart_by_their_bytes(self):
        m = MACHINES[X64]
        self.assertEqual(san.memberFacts("a", coff(m)), {"kind": "object", "machine": m, "bigobj": False})
        self.assertEqual(san.memberFacts("a", bigobj(m)), {"kind": "object", "machine": m, "bigobj": True})
        self.assertEqual(san.memberFacts("a", shortImport(m, "f", DLL)), {
            "kind": "import", "machine": m, "symbol": "f", "dll": DLL, "export": ""})
        self.assertEqual(san.memberFacts("a", shortImport(m, "f", DLL, "g"))["export"], "g")

    def test_a_bigobj_member_is_not_mistaken_for_an_import_member_and_the_reverse(self):
        m = MACHINES[ARM64]
        self.assertEqual(san.memberFacts("a", bigobj(m))["machine"], m)
        self.assertEqual(san.memberFacts("a", shortImport(m, "f", DLL))["machine"], m)

    def test_malformed_members_are_refused(self):
        m = MACHINES[X64]
        broken = shortImport(m, "f", DLL)
        for body in (b"", b"MZ", struct.pack("<HHHH", 0, 0xFFFF, 1, m) + bytes(40),
                     struct.pack("<HHHH", 0, 0xFFFF, 2, m) + bytes(60), broken + b"x", broken[:-1],
                     broken[:20] + b"\xff" + broken[21:]):
            with self.assertRaises(pe.EngineError, msg=body):
                san.memberFacts("m", body)


class ArchiveRoleTest(TempCase):
    def put(self, name, data):
        path = self.path(name)
        write(path, data)
        return path

    def test_a_static_archive_of_objects_of_the_machine_is_accepted_bigobj_included(self):
        path = self.put("a.a", archive([("a.o", coff(MACHINES[X64])), ("b.o", bigobj(MACHINES[X64]))]))
        self.assertIsNone(san.staticProblem(path, MACHINES[X64]))

    def test_an_empty_an_import_only_and_a_wrong_machine_archive_are_refused(self):
        m = MACHINES[X64]
        self.assertIn("holds no member", san.staticProblem(self.put("e.a", b"!<arch>\n"), m))
        self.assertIn("is an import member", san.staticProblem(self.put("i.a", importLibrary(m)), m))
        mixed = self.put("m.a", archive([("a.o", coff(m)), ("b.o", coff(MACHINES[ARM64]))]))
        self.assertIn("member b.o has machine 0xaa64", san.staticProblem(mixed, m))
        self.assertIn("not an ar archive", san.staticProblem(self.put("n.a", b"not an archive"), m))

    def test_the_import_library_of_the_dll_is_accepted(self):
        m = MACHINES[X64]
        self.assertIsNone(san.importProblem(self.put("i.a", importLibrary(m)), m, DLL, san.DLL_MARKERS))

    def test_a_member_named_for_another_dll_or_importing_from_one_is_refused(self):
        m = MACHINES[X64]
        self.assertIn("is not named " + DLL, san.importProblem(
            self.put("a.a", importLibrary(m, dll="libother.dll")), m, DLL, san.DLL_MARKERS))
        wrong = archive([(DLL, coff(m, san.DESCRIPTOR_PREFIX + DLL[:-4].encode())),
                         (DLL, coff(m, b"\x7f" + DLL[:-4].encode() + b"_NULL_THUNK_DATA")),
                         (DLL, shortImport(m, san.DLL_MARKERS[0], "libother.dll"))])
        self.assertIn("imports from libother.dll", san.importProblem(self.put("b.a", wrong), m, DLL, []))

    def test_an_import_library_without_a_descriptor_a_null_thunk_an_import_member_or_a_marker_is_refused(self):
        m = MACHINES[X64]
        self.assertIn("no import descriptor", san.importProblem(
            self.put("a.a", importLibrary(m, descriptor=False)), m, DLL, san.DLL_MARKERS))
        self.assertIn("no null thunk", san.importProblem(
            self.put("b.a", importLibrary(m, thunk=False)), m, DLL, san.DLL_MARKERS))
        self.assertIn("holds no import member", san.importProblem(
            self.put("c.a", importLibrary(m, markers=())), m, DLL, san.DLL_MARKERS))
        self.assertIn("does not import __asan_report_load1", san.importProblem(
            self.put("d.a", importLibrary(m, markers=san.DLL_MARKERS[:2])), m, DLL, san.DLL_MARKERS))

    def test_a_mixed_machine_import_library_is_refused(self):
        m = MACHINES[X64]
        members = [(DLL, coff(MACHINES[ARM64], san.DESCRIPTOR_PREFIX + DLL[:-4].encode())),
                   (DLL, shortImport(m, san.DLL_MARKERS[0], DLL))]
        self.assertIn("has machine 0xaa64", san.importProblem(self.put("a.a", archive(members)), m, DLL, []))

    def test_the_export_name_of_an_import_member_is_the_name_the_dll_must_export(self):
        m = MACHINES[X64]
        self.assertEqual(san.importNames([(n, san.memberFacts(n, b), b) for n, b in
                                          [("x", shortImport(m, "sym", DLL, "exported")), ("y", shortImport(m, "s2", DLL))]]),
                         ["exported", "s2"])

    def test_the_symbols_of_each_role_are_required_and_the_thunk_may_not_define_the_dll_exports(self):
        specs = {s["role"]: s for s in san.assetSpecs(X64)}
        with mock.patch.object(san, "archiveNames", return_value={"__ubsan_handle_add_overflow"}):
            self.assertIn("does not define __ubsan_handle_type_mismatch_v1", san.symbolsProblem("/e", "/x/u.a", specs["ubsan"]))
        with mock.patch.object(san, "archiveNames", return_value=set(san.UBSAN_MARKERS)):
            self.assertIsNone(san.symbolsProblem("/e", "/x/u.a", specs["ubsan"]))
            self.assertIn("does not define __ubsan_handle_dynamic_type_cache_miss",
                          san.symbolsProblem("/e", "/x/c.a", specs["ubsan-cxx"]))
        with mock.patch.object(san, "archiveNames", return_value=set()):
            self.assertIn("__asan_seh_interceptor", san.symbolsProblem("/e", "/x/t.a", specs["asan-thunk"]))
        with mock.patch.object(san, "archiveNames", return_value={"__asan_seh_interceptor", DLL_INFO["exports"][0]}):
            self.assertIn("which only the DLL exports", san.symbolsProblem("/e", "/x/t.a", specs["asan-thunk"]))
        with mock.patch.object(san, "archiveNames", return_value={"__asan_seh_interceptor"}):
            self.assertIsNone(san.symbolsProblem("/e", "/x/t.a", specs["asan-thunk"]))


class DllTest(unittest.TestCase):
    SPEC = san.assetSpecs(X64)[-1]
    M = MACHINES[X64]

    def check(self, **changes):
        return san.dllProblem(dict(DLL_INFO, **changes), self.SPEC, self.M, san.DLL_MARKERS[:1])

    def test_an_x64_dll_with_the_markers_and_system_imports_is_accepted(self):
        self.assertIsNone(self.check())

    def test_the_machine_the_dll_flag_and_the_markers_are_checked(self):
        self.assertIn("machine 0xaa64", self.check(machine=MACHINES[ARM64]))
        self.assertIn("is not a DLL", self.check(characteristics=0x22))
        self.assertIn("does not export __asan_report_load1", self.check(exports=san.DLL_MARKERS[:2]))

    def test_a_name_the_import_library_imports_and_the_dll_does_not_export_is_refused(self):
        self.assertIn("imports __asan_x, which", san.dllProblem(DLL_INFO, self.SPEC, self.M, ["__asan_x"]))

    def test_a_libcxx_libunwind_winpthread_or_msvcrt_import_is_refused_and_the_ucrt_is_required(self):
        for dll in ("libc++.dll", "libunwind.dll", "libwinpthread-1.dll", "msvcrt.dll"):
            imports = dict(DLL_INFO["imports"], **{dll: []})
            self.assertIn("imports " + dll, self.check(imports=imports))
        self.assertIn("no UCRT api set", self.check(imports={"KERNEL32.dll": []}))
        self.assertIsNone(self.check(imports=dict(DLL_INFO["imports"], **{"ntdll.dll": [], "ADVAPI32.dll": []})))


class InspectTargetTest(TempCase):
    def inspect(self, target, prefix, engine=None):
        return san.inspectTarget(prefix, target, engine or self.path("engine"), "23")

    def test_both_targets_validate_and_hold_a_record_for_every_asset_with_the_roles_and_hashes(self):
        for target in TARGETS:
            found = self.inspect(target, self.makeInstall(target))
            self.assertEqual([r["name"] for _, r in found["assets"]], [s["name"] for s in san.assetSpecs(target)])
            for source, record in found["assets"]:
                self.assertEqual(record["sha256"], pe.sha256File(source))
                self.assertEqual(record["machine"], "0x%x" % MACHINES[target])
        records = {r["role"]: r for _, r in self.inspect(X64, self.makeInstall(X64, name="again"))["assets"]}
        self.assertEqual(records["asan-import"]["dll"], DLL)
        self.assertEqual(records["asan-dll"]["imports"], sorted(n.lower() for n in DLL_INFO["imports"]))
        self.assertNotIn("members", records["asan-dll"])

    def test_the_dll_must_export_everything_the_import_library_imports(self):
        extra = importLibrary(MACHINES[X64], markers=san.DLL_MARKERS + ["__asan_only_in_the_import_library"])
        prefix = self.makeInstall(X64, replace={"libclang_rt.asan_dynamic-x86_64.dll.a": extra})
        with self.assertRaisesRegex(pe.EngineError, "__asan_only_in_the_import_library, which"):
            self.inspect(X64, prefix)

    def test_each_asset_is_validated_by_its_role_and_a_refusal_names_the_target(self):
        cases = {"libclang_rt.ubsan_standalone-x86_64.a": (b"!<arch>\n", "holds no member"),
                 "libclang_rt.ubsan_standalone_cxx-x86_64.a": (importLibrary(MACHINES[X64]), "is an import member"),
                 "libclang_rt.asan_dynamic-x86_64.dll.a": (importLibrary(MACHINES[X64], dll="libx.dll"), "is not named"),
                 "libclang_rt.asan_dynamic_runtime_thunk-x86_64.a": (archive([("a.o", coff(MACHINES[ARM64]))]), "machine 0xaa64")}
        for name, (data, why) in cases.items():
            with self.assertRaisesRegex(pe.EngineError, "^x86_64-windows-gnu: .*" + why):
                self.inspect(X64, self.makeInstall(X64, name="case-" + name, replace={name: data}))

    def test_a_symbol_the_role_needs_missing_from_an_archive_is_refused(self):
        with mock.patch.object(san, "archiveNames", return_value=set()):
            with self.assertRaisesRegex(pe.EngineError, "does not define"):
                self.inspect(X64, self.makeInstall(X64))

    def test_descriptor_text_cannot_replace_real_defined_import_symbols(self):
        spec = next(s for s in san.assetSpecs(X64) if s["role"] == "asan-import")
        path = os.path.join(self.makeInstall(X64), "lib", "windows", spec["name"])
        required = set(symbolsOf("/e", path))
        for missing in sorted(required):
            with mock.patch.object(san, "archiveNames", return_value=required - {missing}):
                self.assertIn("does not define " + missing, san.symbolsProblem("/e", path, spec))

    def test_a_bad_dll_is_refused_after_its_import_library_is_read(self):
        with mock.patch.object(san, "readDll", return_value=dict(DLL_INFO, imports={"libc++.dll": []})):
            with self.assertRaisesRegex(pe.EngineError, "imports libc\\+\\+.dll"):
                self.inspect(X64, self.makeInstall(X64))

    def test_not_carried_files_are_recorded_with_hashes_and_the_headers_audited_against_the_engine(self):
        engine = self.path("engine")
        write(os.path.join(engine, "lib", "clang", "23", "include", "sanitizer", "common_interface_defs.h"),
              b"extra include/sanitizer/common_interface_defs.h\n")
        extra = ["include/sanitizer/common_interface_defs.h", "include/sanitizer/asan_interface.h",
                 "lib/windows/libclang_rt.stats-x86_64.a"]
        found = self.inspect(X64, self.makeInstall(X64, extra=extra), engine)
        self.assertEqual([r["path"] for r in found["notCarried"]], sorted(extra))
        self.assertEqual(found["headers"], {"matches": ["include/sanitizer/common_interface_defs.h"],
                                            "missing": ["include/sanitizer/asan_interface.h"], "differs": []})

    def test_a_header_that_differs_from_the_engines_is_refused(self):
        engine = self.path("engine")
        write(os.path.join(engine, "lib", "clang", "23", "include", "sanitizer", "asan_interface.h"), b"another\n")
        with self.assertRaisesRegex(pe.EngineError, "differ from the engine"):
            self.inspect(X64, self.makeInstall(X64, extra=["include/sanitizer/asan_interface.h"]), engine)


class RuntimeCase(TempCase):
    """A runtime with the two input receipts, an engine, and the whole fake pipeline up to the overlay."""

    def setUp(self):
        super().setUp()
        self.runtime = self.path("runtime")
        self.engine = self.path("engine")
        self.llvm = self.path("llvm")
        write(os.path.join(self.runtime, *san.BASE_PROVENANCE.split("/")), json.dumps(BASE_RECEIPT))
        write(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/")), json.dumps(CPP_RECEIPT))
        write(os.path.join(self.llvm, "compiler-rt", "LICENSE.TXT"), b"compiler-rt license\n")
        write(os.path.join(self.engine, "bin", "clang"))
        self.base = (BASE_RECEIPT, pe.sha256File(os.path.join(self.runtime, *san.BASE_PROVENANCE.split("/"))))
        self.cpp = (CPP_RECEIPT, pe.sha256File(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/"))))

    def overlay(self, output, targets=TARGETS):
        inspected = {t: san.inspectTarget(self.makeInstall(t, name=os.path.basename(output) + "-" + t), t, self.engine, "23")
                     for t in targets}
        records = san.stageAssets(inspected, output)
        notices = san.copyNotice(output, self.llvm)
        with mock.patch.object(pws, "toolVersions", return_value={"cmake": "cmake 3.31"}):
            return san.writeProvenance(output, "linux", "23.1.0", "23", targets, inspected, records, notices, self.base,
                                       self.cpp, REV, {"cmake": "/t/cmake"}, ("/py", "Python 3.11"))

    def merged(self, targets=TARGETS):
        output = self.path("overlay")
        receipt = self.overlay(output, targets)
        pc.mergeOverlay(output, self.runtime)
        return output, receipt


class StageAndReceiptTest(RuntimeCase):
    def test_the_overlay_has_the_resource_archives_the_dll_beside_the_target_the_notice_and_the_receipt(self):
        output, receipt = self.merged()
        self.assertEqual(pc.overlayFiles(output), sorted(p.replace("/", os.sep) for p in [
            "notices/windows-sanitizer-provenance.json", san.NOTICE] + [
            san.overlayPath(t, s) for t in TARGETS for s in san.assetSpecs(t)]))
        self.assertEqual(read(os.path.join(output, "windows", X64, "bin", DLL)), b"MZ fake dll\n")
        self.assertFalse(os.path.lexists(os.path.join(output, "windows-sanitizers", "resource", "lib", "windows", DLL)))
        self.assertEqual(read(os.path.join(output, *san.NOTICE.split("/"))), b"compiler-rt license\n")
        self.assertEqual(sorted(receipt["files"][0]), ["path", "sha256"])

    def test_the_receipt_says_source_assets_with_no_proof_and_records_both_input_provenance_hashes(self):
        _, receipt = self.merged()
        self.assertEqual(receipt["kind"], san.RECEIPT_KIND)
        self.assertFalse(receipt["redistributionCertified"])
        self.assertTrue(receipt["proofs"].startswith("none"))
        self.assertEqual(receipt["inputs"]["base"], {"path": san.BASE_PROVENANCE, "kind": pws.RECEIPT_KIND,
                                                     "sha256": self.base[1]})
        self.assertEqual(receipt["inputs"]["cpp"]["sha256"], self.cpp[1])
        self.assertEqual(sorted(receipt["notCarried"]), sorted(TARGETS))
        self.assertEqual(receipt["recipe"]["definitions"], san.FIXED_DEFINITIONS)

    def test_the_receipt_describes_the_merged_runtime_and_the_overlay_alone(self):
        output, receipt = self.merged()
        self.assertIsNone(san.receiptProblem(receipt, self.runtime, self.runtime))
        self.assertIsNone(san.receiptProblem(receipt, output, self.runtime))

    def test_a_changed_listed_file_an_unlisted_owned_file_and_a_link_are_refused(self):
        output, receipt = self.merged()
        dll = os.path.join(self.runtime, "windows", X64, "bin", DLL)
        write(dll, b"changed\n")
        self.assertIn("does not match the receipt", san.receiptProblem(receipt, self.runtime))
        write(dll, b"MZ fake dll\n")
        write(os.path.join(self.runtime, "windows-sanitizers", "resource", "lib", "windows", "stray.a"))
        self.assertIn("present or listed but not both", san.receiptProblem(receipt, self.runtime))
        os.remove(os.path.join(self.runtime, "windows-sanitizers", "resource", "lib", "windows", "stray.a"))
        os.remove(dll)
        self.symlink(os.path.join(self.runtime, "notices", "windows-sanitizer", "compiler-rt", "LICENSE.TXT"), dll)
        self.assertIn("is a link", san.receiptProblem(receipt, self.runtime))

    def test_a_changed_input_receipt_is_refused(self):
        output, receipt = self.merged()
        write(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/")), json.dumps(dict(CPP_RECEIPT, extra=1)))
        self.assertIn("the cpp runtime's receipt is not the one", san.receiptProblem(receipt, self.runtime, self.runtime))
        self.assertIsNone(san.receiptProblem(receipt, self.runtime))

    def test_a_receipt_of_another_kind_targets_proof_state_or_assets_is_refused(self):
        _, receipt = self.merged()
        for change, why in ((dict(kind="x"), "receipt kind"), (dict(targets=["x86_64-linux-gnu"]), "not distinct Windows"),
                            (dict(proofs="bare flags proven"), "proofs state"), (dict(inputs={}), "receipt inputs"),
                            (dict(assets={X64: receipt["assets"][X64]}), "not exactly those of")):
            self.assertIn(why, san.receiptProblem(dict(receipt, **change), self.runtime, self.runtime), change)
        reordered = dict(receipt["assets"], **{X64: receipt["assets"][X64][::-1]})
        self.assertIn("not exactly", san.receiptProblem(dict(receipt, assets=reordered), self.runtime))

    def test_an_arm64_only_overlay_has_no_dll_directory_and_no_asan_file(self):
        output, receipt = self.merged([ARM64])
        self.assertEqual([s["name"] for s in san.assetSpecs(ARM64)], [r["name"] for r in receipt["assets"][ARM64]])
        self.assertFalse([p for p in pc.overlayFiles(output) if "asan" in p or os.sep + "bin" + os.sep in p])
        self.assertIsNone(san.receiptProblem(receipt, self.runtime, self.runtime))

    def test_a_path_the_runtime_already_has_is_a_collision_and_nothing_is_replaced(self):
        self.assertIsNone(san.collisionProblem(self.runtime, TARGETS))
        for relative in ("windows-sanitizers/resource", "notices/windows-sanitizer", "windows/x86_64-windows-gnu/bin"):
            held = os.path.join(self.runtime, *relative.split("/"))
            write(os.path.join(held, "f"))
            self.assertIn("carries one sanitizer asset set", san.collisionProblem(self.runtime, TARGETS), relative)
            shutil.rmtree(held)
        write(os.path.join(self.runtime, *san.PROVENANCE.split("/")))
        self.assertIn(san.PROVENANCE, san.collisionProblem(self.runtime, [ARM64]))

    def test_the_overlay_cannot_merge_over_an_existing_dll_path(self):
        output = self.path("overlay")
        self.overlay(output)
        write(os.path.join(self.runtime, "windows", X64, "bin", DLL), b"other\n")
        with self.assertRaisesRegex(pe.EngineError, "already has"):
            pc.mergeOverlay(output, self.runtime)
        self.assertEqual(read(os.path.join(self.runtime, "windows", X64, "bin", DLL)), b"other\n")


class InstallResourceTest(RuntimeCase):
    def setUp(self):
        super().setUp()
        self.merged()
        self.resource = self.path("engine", "lib", "clang", "23")
        self.names = {t: [s["name"] for s in san.assetSpecs(t) if s["role"] != "asan-dll"] for t in TARGETS}

    def test_the_archives_are_installed_at_lib_windows_and_the_dll_is_not(self):
        before = pc.treeDigest(self.runtime)
        installed = san.installResource(self.runtime, self.resource)
        self.assertEqual(sorted(installed), sorted("lib/windows/" + n for t in TARGETS for n in self.names[t]))
        self.assertEqual(sorted(os.listdir(os.path.join(self.resource, "lib", "windows"))),
                         sorted(n for t in TARGETS for n in self.names[t]))
        self.assertEqual(pc.treeDigest(self.runtime), before)
        for target in TARGETS:
            for name in self.names[target]:
                self.assertEqual(read(os.path.join(self.resource, "lib", "windows", name)), read(os.path.join(
                    self.runtime, "windows-sanitizers", "resource", "lib", "windows", name)))

    def test_a_second_install_is_the_same_and_an_existing_file_with_other_bytes_is_refused_changing_nothing(self):
        san.installResource(self.runtime, self.resource)
        self.assertEqual(len(san.installResource(self.runtime, self.resource)), sum(len(v) for v in self.names.values()))
        other = self.path("other", "lib", "clang", "23")
        name = self.names[X64][1]
        write(os.path.join(other, "lib", "windows", name), b"another build\n")
        with self.assertRaisesRegex(pe.EngineError, "already exists with other contents"):
            san.installResource(self.runtime, other)
        self.assertEqual(os.listdir(os.path.join(other, "lib", "windows")), [name])

    def test_an_archive_at_the_target_triple_is_refused_before_any_copy(self):
        write(os.path.join(self.resource, "lib", "aarch64-w64-windows-gnu", "libclang_rt.ubsan_standalone_cxx.a"))
        with self.assertRaisesRegex(pe.EngineError, "would be read instead of lib/windows/libclang_rt.ubsan_standalone_cxx-aarch64.a"):
            san.installResource(self.runtime, self.resource)
        self.assertFalse(os.path.lexists(os.path.join(self.resource, "lib", "windows")))

    def test_every_installed_component_has_a_triple_shadow_that_is_refused(self):
        for target, triple in ((X64, "x86_64-w64-windows-gnu"), (ARM64, "aarch64-w64-windows-gnu")):
            for spec in san.assetSpecs(target):
                if spec["shadow"]:
                    path = os.path.join(self.resource, "lib", triple, spec["shadow"])
                    write(path)
                    with self.assertRaisesRegex(pe.EngineError, "would be read instead"):
                        san.installResource(self.runtime, self.resource)
                    os.remove(path)

    def test_a_changed_resource_file_a_wrong_role_and_a_link_are_refused_before_any_copy(self):
        archivePath = os.path.join(self.runtime, "windows-sanitizers", "resource", "lib", "windows", self.names[X64][0])
        original = read(archivePath)
        write(archivePath, b"changed\n")
        with self.assertRaisesRegex(pe.EngineError, "does not match the receipt"):
            san.installResource(self.runtime, self.resource)
        write(archivePath, original)
        self.assertFalse(os.path.lexists(os.path.join(self.resource, "lib")))
        resource = self.path("linked", "lib", "clang", "23")
        os.makedirs(os.path.join(resource, "lib"))
        self.symlink(self.path("elsewhere"), os.path.join(resource, "lib", "windows"))
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            san.installResource(self.runtime, resource)

    def test_an_asset_that_is_no_longer_the_role_its_receipt_names_is_refused_by_its_bytes(self):
        runtime = self.path("runtime2")
        shutil.copytree(self.runtime, runtime)
        name = "libclang_rt.ubsan_standalone-x86_64.a"
        path = os.path.join(runtime, "windows-sanitizers", "resource", "lib", "windows", name)
        data = archive([("a.o", coff(MACHINES[ARM64]))])
        write(path, data)
        receiptPath = os.path.join(runtime, *san.PROVENANCE.split("/"))
        found = json.loads(read(receiptPath))
        digest = pe.sha256File(path)
        for record in found["files"] + found["assets"][X64]:
            if record["path"].endswith(name):
                record["sha256"] = digest
        write(receiptPath, json.dumps(found))
        with self.assertRaisesRegex(pe.EngineError, "machine 0xaa64"):
            san.installResource(runtime, self.path("res2", "lib", "clang", "23"))


class InputReceiptsTest(RuntimeCase):
    def run_(self, **changes):
        base = dict(BASE_RECEIPT, **changes.get("base", {}))
        with mock.patch.object(pwc, "baseReceipt", return_value=(base, "bd")), \
                mock.patch.object(pwc, "receiptProblem", return_value=changes.get("problem")):
            return san.inputReceipts(self.runtime, changes.get("targets", TARGETS), "23.1.0", "23", REV)

    def test_the_c_and_cxx_receipts_of_one_commit_version_and_major_are_accepted(self):
        base, cpp = self.run_()
        self.assertEqual(cpp[0]["kind"], pwc.RECEIPT_KIND)

    def test_a_cxx_receipt_that_does_not_describe_the_files_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "does not match"):
            self.run_(problem="x does not match the receipt")

    def test_a_target_missing_from_the_cxx_runtime_is_refused(self):
        write(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/")), json.dumps(dict(CPP_RECEIPT, targets=[X64])))
        with self.assertRaisesRegex(pe.EngineError, "the C\\+\\+ runtime has no aarch64-windows-gnu"):
            self.run_()

    def test_a_runtime_built_from_another_commit_version_or_major_is_refused_for_each_receipt(self):
        for field, value in (("rev", "1" * 40), ("version", "23.1.1"), ("major", "24")):
            other = {"llvm-project": dict(SOURCES["llvm-project"], **{field: value})}
            with self.assertRaisesRegex(pe.EngineError, "the C runtime was built from"):
                self.run_(base={"sources": other})
            write(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/")), json.dumps(dict(CPP_RECEIPT, sources=other)))
            with self.assertRaisesRegex(pe.EngineError, "the C\\+\\+ runtime was built from"):
                self.run_()
            write(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/")), json.dumps(CPP_RECEIPT))

    def test_a_missing_cxx_receipt_is_refused(self):
        os.remove(os.path.join(self.runtime, *san.CPP_PROVENANCE.split("/")))
        with self.assertRaisesRegex(pe.EngineError, "is missing"):
            self.run_()


class SynchronizationTest(TempCase):
    def runtime(self, targets=TARGETS, leave=()):
        root = tempfile.mkdtemp(prefix="runtime-", dir=self.dir)
        for target in targets:
            for variant in pws.SOURCE_VARIANTS:
                directory = pws.variantDirectory(target, variant)
                if (target, variant) not in leave:
                    write(os.path.join(root, "windows", directory, san.SYNCHRONIZATION),
                          importLibrary(MACHINES[target], dll="api-ms-win-core-synch-l1-2-0.dll", markers=["WaitOnAddress"]))
        return root

    def test_each_variant_of_each_target_must_carry_a_synchronization_archive_of_its_machine(self):
        self.assertIsNone(san.synchronizationProblem(self.runtime(), TARGETS))
        self.assertIn("aarch64-windows-gnu.dll lacks libsynchronization.a",
                      san.synchronizationProblem(self.runtime(leave=[(ARM64, "dll")]), TARGETS))
        self.assertIn("x86_64-windows-gnu lacks", san.synchronizationProblem(self.runtime(leave=[(X64, "exe")]), TARGETS))

    def test_a_wrong_machine_an_empty_archive_and_a_link_are_refused_and_no_alias_is_made(self):
        root = self.runtime([X64])
        write(os.path.join(root, "windows", X64, san.SYNCHRONIZATION), importLibrary(MACHINES[ARM64], dll="a.dll"))
        self.assertIn("has machine 0xaa64", san.synchronizationProblem(root, [X64]))
        write(os.path.join(root, "windows", X64, san.SYNCHRONIZATION), b"!<arch>\n")
        self.assertIn("holds no member", san.synchronizationProblem(root, [X64]))
        os.remove(os.path.join(root, "windows", X64, san.SYNCHRONIZATION))
        self.symlink(os.path.join(root, "windows", X64 + ".dll", san.SYNCHRONIZATION),
                     os.path.join(root, "windows", X64, san.SYNCHRONIZATION))
        self.assertIn("is a link", san.synchronizationProblem(root, [X64]))
        self.assertEqual(sorted(os.listdir(os.path.join(root, "windows", X64 + ".dll"))), [san.SYNCHRONIZATION])


class PrepareTest(RuntimeCase):
    def setUp(self):
        super().setUp()
        self.output = self.path("out", "overlay")
        self.stageRoots = []
        self.llvmChecks = []

        self.stageCalls = []

        def stageTree(engine, windows, root, major):
            self.stageRoots.append(root)
            self.stageCalls.append((engine, windows, major))
            os.makedirs(os.path.join(root, "runtime"))

        def checkSourceRoot(*arguments):
            self.llvmChecks.append(arguments)
            return self.llvm

        for relative in ("windows/%s/%s" % (pws.variantDirectory(t, v), san.SYNCHRONIZATION)
                         for t in TARGETS for v in pws.SOURCE_VARIANTS):
            write(os.path.join(self.runtime, *relative.split("/")),
                  importLibrary(MACHINES[X64 if X64 in relative else ARM64], dll="a.dll", markers=["WaitOnAddress"]))
        self.receiptCalls = []
        patches = [mock.patch.object(pr, "engineMajor", return_value=("linux", "23.1.0", "23")),
                   mock.patch.object(pws, "engineTool", side_effect=lambda e, n: "/e/bin/" + n),
                   mock.patch.object(pws, "checkSourceRoot", side_effect=checkSourceRoot),
                   mock.patch.object(pws, "checkLlvmVersion"),
                   mock.patch.object(pws, "checkPlainPath", side_effect=lambda path, what: path),
                   mock.patch.object(pws, "toolVersions", return_value={}),
                   mock.patch.object(san, "inputReceipts", return_value=(self.base, self.cpp)),
                   mock.patch.object(pws, "stageTree", side_effect=stageTree),
                   mock.patch.object(san, "buildSanitizers", side_effect=self.build)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def build(self, llvm, stage, target, work, tools, python, environment, jobs):
        return self.makeInstall(target, name="built-" + target)

    def run_(self, **options):
        return san.prepareWindowsSanitizerRuntime(self.engine, self.runtime, self.output, self.llvm, REV,
                                                  {"cmake": "/t/cmake"}, ("/py", "Python 3.11"), **options)

    def leftovers(self):
        parent = os.path.dirname(self.output)
        return os.listdir(parent) if os.path.isdir(parent) else []

    def test_a_finished_run_publishes_the_proven_overlay_in_one_rename_and_leaves_the_inputs_byte_identical(self):
        before = {"runtime": pc.treeDigest(self.runtime), "engine": pc.treeDigest(self.engine)}
        output, receipt = self.run_()
        self.assertEqual(output, self.output)
        self.assertEqual(self.leftovers(), ["overlay"])
        self.assertEqual({"runtime": pc.treeDigest(self.runtime), "engine": pc.treeDigest(self.engine)}, before)
        pc.mergeOverlay(self.output, self.runtime)
        self.assertIsNone(san.receiptProblem(receipt, self.runtime, self.runtime))
        self.assertEqual(len(self.llvmChecks), 2)
        self.assertEqual(self.llvmChecks[0], self.llvmChecks[1])

    def test_path_guard_refusals_stop_before_staging_and_clean_the_partial(self):
        for position, label in ((1, "work directory"), (2, "engine")):
            calls = []

            def guard(path, what):
                calls.append((path, what))
                if len(calls) == position:
                    raise pe.EngineError(what + " needs quoting")
                return path

            with mock.patch.object(pws, "checkPlainPath", side_effect=guard):
                with self.assertRaisesRegex(pe.EngineError, label + " needs quoting"):
                    self.run_()
            self.assertEqual(calls[-1][1], label)
            self.assertEqual((self.stageRoots, self.leftovers()), ([], []))

    def test_one_target_can_be_built_alone(self):
        _, receipt = self.run_(targets=[ARM64])
        self.assertEqual(receipt["targets"], [ARM64])
        self.assertEqual(sorted(receipt["assets"]), [ARM64])

    def test_an_existing_output_a_non_positive_jobs_and_an_output_inside_an_input_are_refused_before_any_work(self):
        write(self.output + "/keep")
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            self.run_()
        shutil.rmtree(self.output)
        for jobs in (0, -1):
            with self.assertRaisesRegex(pe.EngineError, "is not positive"):
                self.run_(jobs=jobs)
        for inside in (self.path("runtime", "overlay"), self.path("engine", "overlay"), self.path("llvm", "x", "overlay")):
            self.output = inside
            with self.assertRaisesRegex(pe.EngineError, "is inside the"):
                self.run_()
        self.assertEqual((self.stageRoots, self.leftovers()), ([], []))

    def test_a_runtime_that_already_has_an_asset_set_path_is_refused_before_any_work(self):
        write(os.path.join(self.runtime, "windows-sanitizers", "resource", "x"))
        with self.assertRaisesRegex(pe.EngineError, "carries one sanitizer asset set"):
            self.run_()
        self.assertEqual(self.stageRoots, [])

    def test_a_target_without_a_synchronization_archive_is_refused_before_any_work(self):
        os.remove(os.path.join(self.runtime, "windows", ARM64 + ".dll", san.SYNCHRONIZATION))
        with self.assertRaisesRegex(pe.EngineError, "lacks libsynchronization.a"):
            self.run_()
        self.assertEqual(self.stageRoots, [])

    def test_the_commit_and_version_come_from_the_engine_and_a_runtime_of_another_cohort_is_refused(self):
        with mock.patch.object(san, "inputReceipts", side_effect=pe.EngineError("the C runtime was built from llvm-project x")):
            with self.assertRaisesRegex(pe.EngineError, "was built from"):
                self.run_()
        self.assertEqual(self.stageRoots, [])
        with mock.patch.object(pws, "pinnedRevisions", wraps=pws.pinnedRevisions) as pinned:
            self.run_(targets=[X64])
        pinned.assert_called_once_with("23.1.0", None, REV)

    def test_an_input_that_changed_during_the_build_is_refused_and_nothing_is_published(self):
        for label, root in (("runtime", self.runtime), ("engine", self.engine)):
            def build(llvm, stage, target, work, tools, python, environment, jobs, root=root):
                write(os.path.join(root, "stray"))
                return self.makeInstall(target, name="mutating-" + target)

            with mock.patch.object(san, "buildSanitizers", side_effect=build):
                with self.assertRaisesRegex(pe.EngineError, "the input %s .* changed during the build" % label):
                    self.run_()
            os.remove(os.path.join(root, "stray"))
            self.assertFalse(os.path.lexists(self.output))
            self.assertEqual(self.leftovers(), [])

    def test_a_checkout_that_changed_during_the_build_is_refused_and_nothing_is_published(self):
        calls = []

        def checkSourceRoot(*arguments):
            calls.append(arguments)
            if len(calls) == 2:
                raise pe.EngineError("llvm-project has uncommitted or untracked files")
            return self.llvm

        with mock.patch.object(pws, "checkSourceRoot", side_effect=checkSourceRoot):
            with self.assertRaisesRegex(pe.EngineError, "uncommitted"):
                self.run_()
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(self.leftovers(), [])

    def test_a_failed_build_a_refused_asset_and_a_refused_receipt_leave_no_output_partial_or_work_directory(self):
        with mock.patch.object(san, "buildSanitizers", side_effect=pe.EngineError("boom")):
            with self.assertRaisesRegex(pe.EngineError, "boom"):
                self.run_()
        with mock.patch.object(san, "inspectTarget", side_effect=pe.EngineError("bad asset")):
            with self.assertRaisesRegex(pe.EngineError, "bad asset"):
                self.run_()
        with mock.patch.object(san, "receiptProblem", return_value="the receipt is wrong"):
            with self.assertRaisesRegex(pe.EngineError, "the receipt is wrong"):
                self.run_()
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(self.leftovers(), [])
        self.assertTrue(all(not os.path.lexists(os.path.dirname(r)) for r in self.stageRoots))

    def test_the_temporary_sdk_is_the_stage_of_the_engine_and_the_runtimes_windows_directory(self):
        self.run_(targets=[X64])
        self.assertEqual(self.stageCalls, [(self.engine, os.path.join(self.runtime, "windows"), "23")])

    def test_every_target_is_inspected_before_any_asset_is_copied(self):
        real = san.inspectTarget
        results = [None, pe.EngineError("the second target is refused")]

        def inspect(prefix, target, engine, major):
            result = results.pop(0)
            if result is None:
                return real(prefix, target, engine, major)
            raise result

        with mock.patch.object(san, "inspectTarget", side_effect=inspect), \
                mock.patch.object(san, "stageAssets") as staged:
            with self.assertRaisesRegex(pe.EngineError, "the second target is refused"):
                self.run_()
        staged.assert_not_called()
        self.assertEqual(self.leftovers(), [])


class CommandLineTest(unittest.TestCase):
    def main(self, *argv, base=("--engine", "/e", "--runtime", "/r", "--output", "/o", "--llvm-project", "/l")):
        error = io.StringIO()
        with contextlib.redirect_stderr(error), contextlib.redirect_stdout(io.StringIO()):
            try:
                code = san.main(list(base) + list(argv))
            except SystemExit as exit_:
                code = exit_.code
        return code, error.getvalue()

    def test_every_required_option_is_required(self):
        for option in ("--engine", "--runtime", "--output", "--llvm-project"):
            argv = ["--engine", "/e", "--runtime", "/r", "--output", "/o", "--llvm-project", "/l"]
            del argv[argv.index(option):argv.index(option) + 2]
            code, text = self.main(base=argv)
            self.assertEqual(code, 2, option)
            self.assertIn(option, text)

    def test_the_proof_and_execute_options_do_not_exist_here(self):
        for option in ("--prove", "--execute", "--deny"):
            self.assertEqual(self.main(option)[0], 2, option)

    def test_jobs_must_be_positive(self):
        for jobs in ("0", "-3"):
            code, text = self.main("--jobs", jobs)
            self.assertEqual(code, 2)
            self.assertIn("is not positive", text)

    def test_the_options_reach_the_producer_and_an_engine_error_is_exit_one(self):
        with mock.patch.object(pws, "resolveTools", return_value={"cmake": "/t/cmake"}), \
                mock.patch.object(pwc, "resolvePython", return_value=("/py", "Python 3.11")), \
                mock.patch.object(san, "prepareWindowsSanitizerRuntime",
                                  return_value=("/o", {"files": [], "assets": {X64: [1, 2]}, "targets": [X64]})) as prepare:
            self.assertEqual(self.main("--target", X64, "--jobs", "2", "--llvm-project-rev", REV, "--python3", "/p")[0], 0)
        prepare.assert_called_once_with("/e", "/r", "/o", "/l", REV, {"cmake": "/t/cmake"}, ("/py", "Python 3.11"),
                                        targets=[X64], jobs=2)
        with mock.patch.object(pws, "resolveTools", side_effect=pe.EngineError("the host has no cmake")):
            code, text = self.main()
        self.assertEqual(code, 1)
        self.assertIn("prepareWindowsSanitizerRuntime: error: the host has no cmake", text)

    def test_an_unknown_or_duplicated_target_is_an_error_not_a_default(self):
        with self.assertRaisesRegex(pe.EngineError, "unknown or duplicated"):
            pw.selectWindowsTargets(["x86_64-linux-gnu"])
        with self.assertRaisesRegex(pe.EngineError, "unknown or duplicated"):
            pw.selectWindowsTargets([X64, X64])


@unittest.skipUnless(all(os.environ.get(n) for n in ("MSC_WINDOWS_SANITIZER_ENGINE", "MSC_WINDOWS_SANITIZER_RUNTIME",
                                                      "MSC_WINDOWS_SANITIZER_LLVM")),
                     "set MSC_WINDOWS_SANITIZER_ENGINE, _RUNTIME (C runtime with its C++ overlay merged) and _LLVM")
class RealBuildTest(TempCase):
    def test_both_targets_build_validate_and_publish_source_assets_on_the_staged_engine(self):
        output = self.path("overlay")
        runtime = os.environ["MSC_WINDOWS_SANITIZER_RUNTIME"]
        self.assertEqual(san.main(["--engine", os.environ["MSC_WINDOWS_SANITIZER_ENGINE"], "--runtime", runtime,
                                   "--output", output, "--llvm-project", os.environ["MSC_WINDOWS_SANITIZER_LLVM"]]), 0)
        with open(os.path.join(output, *san.PROVENANCE.split("/")), encoding="utf-8") as f:
            receipt = json.load(f)
        self.assertEqual(sorted(receipt["targets"]), sorted(TARGETS))
        merged = self.path("merged")
        shutil.copytree(runtime, merged, symlinks=True)
        pc.mergeOverlay(output, merged)
        self.assertIsNone(san.receiptProblem(receipt, merged, merged))


if __name__ == "__main__":
    unittest.main()
