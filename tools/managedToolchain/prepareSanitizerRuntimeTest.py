import json
import os
import shutil
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareSanitizerRuntime as sr
import prepareWindowsRuntime as pw
from prepareEngineTest import reparse
from prepareWindowsRuntimeTest import syntheticPe

COMMIT = "0123456789abcdef0123456789abcdef01234567"
SYMBOLS_OF = {
    "libclang_rt.ubsan_standalone-x86_64.a": set(sr.UBSAN_SYMBOLS),
    "libclang_rt.ubsan_standalone-aarch64.a": set(sr.UBSAN_SYMBOLS),
    "libclang_rt.asan_dynamic-x86_64.dll.a": {sr.ASAN_INIT},
    "libclang_rt.asan_dynamic_runtime_thunk-x86_64.a": {sr.ASAN_THUNK_SYMBOL},
}
DLL = "libclang_rt.asan_dynamic-x86_64.dll"
UBSAN_X64 = "libclang_rt.ubsan_standalone-x86_64.a"
UBSAN_ARM64 = "libclang_rt.ubsan_standalone-aarch64.a"
IMPORT_LIBRARY = "libclang_rt.asan_dynamic-x86_64.dll.a"
THUNK = "libclang_rt.asan_dynamic_runtime_thunk-x86_64.a"
ELF_X64, ELF_ARM64 = 62, 183


def ar(members):
    out = b"!<arch>\n"
    for name, body in members:
        out += ("%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name + "/", 0, 0, 0, "100644", len(body))).encode()
        out += body + (b"\n" if len(body) % 2 else b"")
    return out


def elfObject(machine, elfClass=2):
    return b"\x7fELF" + bytes([elfClass, 1]) + bytes(12) + machine.to_bytes(2, "little")


def coffObject(machine):
    return machine.to_bytes(2, "little") + bytes(18)


def importMember(machine, dll):
    return b"\0\0\xff\xff" + bytes(2) + machine.to_bytes(2, "little") + bytes(12) + b"__asan_init\0" + dll.encode() + b"\0"


def write(path, content=b"x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(content, bytes) else "w") as f:
        f.write(content)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def archiveSymbolsOf(table):
    def symbols(engine, path):
        return [("T", name) for name in sorted(table[os.path.basename(path)])]
    return symbols


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareSanitizerRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


class ConfigTest(unittest.TestCase):
    def test_a_linux_profile_names_the_whole_archive_the_export_list_and_the_libraries_the_driver_would_add(self):
        names = {"archive": UBSAN_X64, "dynamicList": UBSAN_X64 + ".syms"}
        here = "<CFGDIR>/x86_64-linux-gnu.2.31.ubsan/"
        self.assertEqual(sr.renderProfile(sr.LINUX_X64, "ubsan", names).splitlines(), [
            "-fsanitize=undefined", "-fno-sanitize-recover=undefined", "-fno-sanitize-link-runtime",
            "-Xlinker --whole-archive -Xlinker %s%s -Xlinker --no-whole-archive" % (here, UBSAN_X64),
            "-Xlinker --dynamic-list=%s%s.syms" % (here, UBSAN_X64),
            "$-lpthread", "$-lrt", "$-lm", "$-ldl", "$-lresolv"])

    def test_a_linux_profile_without_an_export_list_exports_everything_as_the_driver_does(self):
        lines = sr.renderProfile(sr.LINUX_ARM64, "ubsan", {"archive": UBSAN_ARM64}).splitlines()
        self.assertIn("-Xlinker --export-dynamic", lines)
        self.assertFalse([l for l in lines if "dynamic-list" in l])
        self.assertIn("-Xlinker --whole-archive -Xlinker <CFGDIR>/aarch64-linux-gnu.2.31.ubsan/%s -Xlinker --no-whole-archive"
                      % UBSAN_ARM64, lines)

    def test_a_windows_ubsan_profile_turns_off_the_defaultlib_directive_and_links_the_archive_itself(self):
        self.assertEqual(sr.renderProfile(sr.WINDOWS_X64, "ubsan", {"archive": UBSAN_X64}).splitlines(), [
            "-fsanitize=undefined", "-fno-sanitize-recover=undefined", "-fno-rtlib-defaultlib",
            "-Xlinker <CFGDIR>/x86_64-windows-gnu.ubsan/" + UBSAN_X64])

    def test_the_asan_profile_names_the_import_library_first_and_the_thunk_after_the_objects(self):
        here = "<CFGDIR>/x86_64-windows-gnu.asan/"
        names = {"importLibrary": IMPORT_LIBRARY, "thunk": THUNK, "dll": DLL}
        self.assertEqual(sr.renderProfile(sr.WINDOWS_X64, "asan", names).splitlines(), [
            "-fsanitize=address",
            "-Xlinker " + here + IMPORT_LIBRARY,
            "$-Xlinker $" + here + IMPORT_LIBRARY,
            "$-Xlinker $" + here + THUNK,
            "$-Xlinker $--require-defined $-Xlinker $__asan_seh_interceptor",
            "$-Xlinker $--whole-archive $-Xlinker $%s%s $-Xlinker $--no-whole-archive" % (here, THUNK)])

    def test_the_asan_profile_does_not_link_the_dll_and_carries_no_unrecoverable_flag_of_ubsan(self):
        text = sr.renderProfile(sr.WINDOWS_X64, "asan", {"importLibrary": IMPORT_LIBRARY, "thunk": THUNK, "dll": DLL})
        self.assertNotIn(DLL + "\n", text)
        self.assertNotIn("undefined", text)

    def test_a_file_name_that_would_need_quoting_is_refused(self):
        with self.assertRaises(pe.EngineError):
            sr.renderProfile(sr.WINDOWS_X64, "ubsan", {"archive": "a b.a"})
        with self.assertRaises(pe.EngineError):
            sr.renderProfile(sr.WINDOWS_X64, "ubsan", {"archive": "a$b.a"})

    def test_profile_paths_follow_the_target_layout(self):
        self.assertEqual(sr.profileConfig(sr.LINUX_X64, "ubsan"), "x86_64-linux-gnu.2.31.ubsan.cfg")
        self.assertEqual(sr.profileConfig(sr.LINUX_ARM64, "ubsan"), "aarch64-linux-gnu.2.31.ubsan.cfg")
        self.assertEqual(sr.profileDirectory(sr.WINDOWS_X64, "asan"), "windows/x86_64-windows-gnu.asan")
        self.assertEqual(sr.profileConfig(sr.WINDOWS_ARM64, "ubsan"), "windows/aarch64-windows-gnu.ubsan.cfg")


WINDOWS_BASE = "\n".join(["-target x86_64-unknown-windows-gnu", "-nostdlib", "-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu",
                          "-Xlinker --image-base=0x140000000", "-Xlinker <CFGDIR>/x86_64-windows-gnu/crt2.obj",
                          "$-lmingw32", "$-lzigc"]) + "\n"
LINUX_BASE = "-target x86_64-unknown-linux-gnu\n-nostdlib\n-Xlinker <CFGDIR>/x86_64-linux-gnu.2.31/crt1.o\n"
ASAN_NAMES = {"importLibrary": IMPORT_LIBRARY, "thunk": THUNK, "dll": DLL}


SOURCE_BASE = WINDOWS_BASE.replace("crt2.obj", "crt2.o")


class OrderTest(unittest.TestCase):
    def asan(self, names=ASAN_NAMES):
        return sr.renderProfile(sr.WINDOWS_X64, "asan", names)

    def check(self, text, base=WINDOWS_BASE, startup="crt2.obj", names=ASAN_NAMES):
        sr.crossCheck(sr.WINDOWS_X64, "asan", text, base, startup, names)

    def test_the_import_library_precedes_the_startup_object_and_the_tail_ends_with_the_whole_archive_thunk(self):
        head, _ = sr.linkerOrder([self.asan(), WINDOWS_BASE])
        names = [os.path.basename(v) for v in head]
        self.assertLess(names.index(IMPORT_LIBRARY), names.index("crt2.obj"))
        _, tail = sr.linkerOrder([self.asan()])
        here = "<CFGDIR>/x86_64-windows-gnu.asan/"
        self.assertEqual(tail, [here + IMPORT_LIBRARY, here + THUNK, "--require-defined", "__asan_seh_interceptor",
                                "--whole-archive", here + THUNK, "--no-whole-archive"])
        self.check(self.asan())

    def test_an_import_library_and_thunk_with_any_file_name_pass_by_role_not_by_extension(self):
        for library in ("asan_rt.lib", "clang_rt.asan_dynamic-x86_64.a", "x.dll.lib", "plain"):
            names = dict(ASAN_NAMES, importLibrary=library, thunk="thunk-" + library)
            self.check(self.asan(names), names=names)

    def test_an_import_library_the_base_check_is_not_given_is_refused_even_when_it_ends_in_dll_a(self):
        names = dict(ASAN_NAMES, importLibrary="other.dll.a")
        with self.assertRaisesRegex(pe.EngineError, "must precede"):
            self.check(self.asan(), names=names)

    def test_the_tail_must_name_the_roles_files_not_any_two_inputs(self):
        swapped = self.asan().replace(THUNK, "stranger.a", 1)
        with self.assertRaisesRegex(pe.EngineError, "link tail"):
            self.check(swapped)

    def test_the_startup_object_is_the_one_the_base_receipt_records_so_crt2_o_and_crt2_obj_both_pass(self):
        self.check(self.asan(), SOURCE_BASE, "crt2.o")
        self.check(self.asan(), WINDOWS_BASE, "crt2.obj")
        for base, startup in ((SOURCE_BASE, "crt2.obj"), (WINDOWS_BASE, "crt2.o"), (WINDOWS_BASE, "dllcrt2.obj"), (WINDOWS_BASE, None)):
            with self.assertRaisesRegex(pe.EngineError, "must precede"):
                self.check(self.asan(), base, startup)

    def test_two_startup_objects_in_the_base_are_refused_rather_than_one_chosen(self):
        doubled = WINDOWS_BASE + "-Xlinker <CFGDIR>/x86_64-windows-gnu/crt2.obj\n"
        with self.assertRaisesRegex(pe.EngineError, "must precede"):
            self.check(self.asan(), doubled)

    def test_the_base_config_first_puts_the_startup_object_before_the_import_library_and_is_refused(self):
        head, _ = sr.linkerOrder([WINDOWS_BASE, self.asan()])
        names = [os.path.basename(v) for v in head]
        self.assertGreater(names.index(IMPORT_LIBRARY), names.index("crt2.obj"))
        broken = self.asan().replace("-Xlinker <CFGDIR>/x86_64-windows-gnu.asan/" + IMPORT_LIBRARY + "\n", "", 1)
        with self.assertRaisesRegex(pe.EngineError, "must precede"):
            self.check(broken)

    def test_a_base_without_a_startup_object_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "must precede"):
            self.check(self.asan(), WINDOWS_BASE.replace("crt2.obj", "other.obj"))

    def test_a_tampered_tail_is_refused(self):
        for old, new in (("$-Xlinker $--require-defined $-Xlinker $__asan_seh_interceptor\n", ""),
                         ("$--require-defined", "$--no-whole-archive"),
                         ("$__asan_seh_interceptor", "$__other")):
            with self.assertRaisesRegex(pe.EngineError, "link tail"):
                self.check(self.asan().replace(old, new))

    def test_a_base_config_that_lets_the_driver_add_libraries_is_refused(self):
        for profile, target, base in (("ubsan", sr.LINUX_X64, LINUX_BASE), ("asan", sr.WINDOWS_X64, WINDOWS_BASE)):
            with self.assertRaisesRegex(pe.EngineError, "-nostdlib"):
                sr.crossCheck(target, profile, "", base.replace("-nostdlib\n", ""), "crt2.obj", ASAN_NAMES)

    def test_the_linux_profile_needs_no_import_library_order(self):
        sr.crossCheck(sr.LINUX_X64, "ubsan", sr.renderProfile(sr.LINUX_X64, "ubsan", {"archive": UBSAN_X64}), LINUX_BASE)


class ManifestTest(TempCase):
    def manifest(self, **changes):
        manifest = {"schema": 1, "source": {"release": "llvmorg-23.1.0", "commit": COMMIT, "build": "cmake, ninja, llvm-mingw"},
                    "targets": {sr.WINDOWS_X64: {"ubsan": {"archive": "w/" + UBSAN_X64},
                                                 "asan": {"importLibrary": "w/" + IMPORT_LIBRARY, "thunk": "w/" + THUNK,
                                                          "dll": "w/" + DLL}},
                                sr.LINUX_X64: {"ubsan": {"archive": "l/" + UBSAN_X64, "dynamicList": "l/" + UBSAN_X64 + ".syms"}}}}
        manifest.update(changes)
        return manifest

    def read(self, manifest, major="23"):
        write(self.path(sr.MANIFEST), json.dumps(manifest))
        return sr.readManifest(self.dir, major)

    def refused(self, manifest, pattern, major="23"):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.read(manifest, major)

    def test_a_complete_manifest_is_read_with_its_digest(self):
        manifest, digest = self.read(self.manifest())
        self.assertEqual(manifest["source"]["commit"], COMMIT)
        self.assertEqual(digest, pe.sha256File(self.path(sr.MANIFEST)))

    def test_a_missing_manifest_or_one_that_is_not_json_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "no regular payload.json"):
            sr.readManifest(self.dir, "23")
        write(self.path(sr.MANIFEST), "{")
        with self.assertRaisesRegex(pe.EngineError, "not JSON"):
            sr.readManifest(self.dir, "23")

    def test_the_release_must_be_the_engines_major(self):
        self.refused(self.manifest(), "major 23, the engine's clang is 22", "22")
        bad = self.manifest()
        bad["source"]["release"] = "main"
        self.refused(bad, "not llvmorg")

    def test_the_source_identity_must_be_complete(self):
        for key, value in (("commit", "abc"), ("commit", COMMIT.upper()), ("build", " "), ("build", 3)):
            bad = self.manifest()
            bad["source"][key] = value
            self.refused(bad, "commit|build")
        bad = self.manifest()
        del bad["source"]["commit"]
        self.refused(bad, "missing")

    def test_unknown_keys_schemas_targets_and_profiles_are_refused(self):
        self.refused(self.manifest(schema=2), "schema")
        self.refused(self.manifest(extra=1), "unknown")
        self.refused(self.manifest(targets={}), "names no target")
        self.refused(self.manifest(targets={"wasm32-wasi": {"ubsan": {"archive": "a"}}}), "no sanitizer profile")
        self.refused(self.manifest(targets={sr.WINDOWS_ARM64: {"asan": {"importLibrary": "a", "thunk": "b", "dll": "c"}}}),
                     "no asan profile")
        self.refused(self.manifest(targets={sr.LINUX_X64: {"asan": {"archive": "a"}}}), "no asan profile")

    def test_a_role_without_a_path_or_with_an_unknown_role_is_refused(self):
        self.refused(self.manifest(targets={sr.WINDOWS_X64: {"asan": {"importLibrary": "a", "thunk": "b"}}}), "missing")
        self.refused(self.manifest(targets={sr.WINDOWS_X64: {"ubsan": {"archive": "a", "extra": "b"}}}), "unknown")

    def test_an_export_list_is_for_an_elf_target_only(self):
        self.refused(self.manifest(targets={sr.WINDOWS_X64: {"ubsan": {"archive": "a", "dynamicList": "b"}}}), "unknown")

    def test_a_path_that_could_leave_the_payload_is_refused(self):
        for relative in ("../a.a", "/abs/a.a", "w\\a.a", "w//a.a", "", "./a.a", "w/a b.a"):
            self.refused(self.manifest(targets={sr.LINUX_X64: {"ubsan": {"archive": relative}}}), "path")

    def test_a_path_through_a_missing_directory_is_missing_not_an_os_error(self):
        with self.assertRaisesRegex(pe.EngineError, "payload file nowhere/a.a is missing"):
            sr.payloadFile(self.dir, "nowhere/a.a", "x")

    def test_a_missing_payload_file_is_refused_by_role(self):
        with self.assertRaisesRegex(pe.EngineError, "ubsan archive: payload file l/missing.a is missing"):
            sr.payloadFile(self.dir, "l/missing.a", "x86_64-linux-gnu.2.31 ubsan archive")

    def test_a_symlinked_payload_file_or_directory_is_refused(self):
        write(self.path("real", "a.a"))
        try:
            os.symlink(self.path("real", "a.a"), self.path("link.a"))
            os.symlink(self.path("real"), self.path("linked"))
        except (OSError, NotImplementedError):
            self.skipTest("symlinks are not available")
        for relative in ("link.a", "linked/a.a"):
            with self.assertRaisesRegex(pe.EngineError, "symlink"):
                sr.payloadFile(self.dir, relative, "x")

    def test_a_junction_directory_or_reparse_file_is_refused_where_islink_says_false(self):
        write(self.path("junction", "a.a"))
        write(self.path("plain.a"))
        for relative, reparsed in (("junction/a.a", self.path("junction")), ("plain.a", self.path("plain.a"))):
            with reparse(reparsed), mock.patch.object(os.path, "islink", return_value=False):
                with self.assertRaisesRegex(pe.EngineError, "symlink or reparse point"):
                    sr.payloadFile(self.dir, relative, "x")
        self.assertEqual(sr.payloadFile(self.dir, "junction/a.a", "x"), self.path("junction", "a.a"))

    def test_a_manifest_that_is_a_reparse_point_is_refused(self):
        write(self.path(sr.MANIFEST), json.dumps(self.manifest()))
        with reparse(self.path(sr.MANIFEST)), mock.patch.object(os.path, "islink", return_value=False):
            with self.assertRaisesRegex(pe.EngineError, "no regular payload.json"):
                sr.readManifest(self.dir, "23")


class ContentTest(TempCase):
    def check(self, target, profile, files):
        paths = {}
        for role, (name, content) in files.items():
            paths[role] = self.path(name)
            write(paths[role], content)
        with mock.patch.object(pc, "archiveSymbols", archiveSymbolsOf(SYMBOLS_OF)):
            sr.checkFiles("/engine", target, profile, paths)

    def refused(self, target, profile, files, pattern):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.check(target, profile, files)

    def good(self):
        syntheticPe(self.path("dll"), dll=True, exports=(sr.ASAN_INIT,))
        return {"importLibrary": (IMPORT_LIBRARY, ar([("d.o", importMember(pw.MACHINE_AMD64, DLL))])),
                "thunk": (THUNK, ar([("t.o", coffObject(pw.MACHINE_AMD64))])),
                "dll": (DLL, open(self.path("dll"), "rb").read())}

    def test_each_target_accepts_its_own_architecture(self):
        self.check(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", elfObject(ELF_X64))]))})
        self.check(sr.LINUX_ARM64, "ubsan", {"archive": (UBSAN_ARM64, ar([("u.o", elfObject(ELF_ARM64))]))})
        self.check(sr.WINDOWS_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", coffObject(pw.MACHINE_AMD64))]))})
        self.check(sr.WINDOWS_ARM64, "ubsan", {"archive": (UBSAN_ARM64, ar([("u.o", coffObject(pw.MACHINE_ARM64))]))})
        self.check(sr.WINDOWS_X64, "asan", self.good())

    def test_an_archive_of_another_machine_or_format_is_refused_by_member(self):
        wrong = (UBSAN_X64, ar([("u.o", elfObject(ELF_X64)), ("v.o", elfObject(ELF_ARM64))]))
        self.refused(sr.LINUX_X64, "ubsan", {"archive": wrong}, r"member v\.o is elf machine 0xb7, not elf machine 0x3e")
        self.refused(sr.LINUX_ARM64, "ubsan", {"archive": (UBSAN_ARM64, ar([("u.o", elfObject(ELF_X64))]))}, "machine 0x3e")
        self.refused(sr.WINDOWS_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", elfObject(ELF_X64))]))}, "is elf")
        self.refused(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", coffObject(pw.MACHINE_AMD64))]))}, "is coff")
        self.refused(sr.WINDOWS_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", coffObject(pw.MACHINE_ARM64))]))},
                     "machine 0xaa64, not coff machine 0x8664")

    def test_an_archive_that_is_not_one_or_is_empty_or_holds_a_32_bit_object_is_refused(self):
        self.refused(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, b"not an archive")}, "not an ar archive")
        self.refused(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, ar([]))}, "has no member")
        self.refused(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", elfObject(ELF_X64, elfClass=1))]))},
                     "ELF64")
        self.refused(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", b"garbage garbage garbage garbage")]))},
                     "neither")

    def test_a_ubsan_archive_without_the_abort_handlers_is_refused(self):
        table = dict(SYMBOLS_OF, **{UBSAN_X64: {"__ubsan_handle_add_overflow"}})
        write(self.path(UBSAN_X64), ar([("u.o", elfObject(ELF_X64))]))
        with mock.patch.object(pc, "archiveSymbols", archiveSymbolsOf(table)):
            with self.assertRaisesRegex(pe.EngineError, "defines no __ubsan_handle_add_overflow_abort"):
                sr.checkFiles("/engine", sr.LINUX_X64, "ubsan", {"archive": self.path(UBSAN_X64)})

    def test_an_export_list_without_ubsan_handlers_is_refused(self):
        self.refused(sr.LINUX_X64, "ubsan", {"archive": (UBSAN_X64, ar([("u.o", elfObject(ELF_X64))])),
                                              "dynamicList": (UBSAN_X64 + ".syms", b"{ other; };")}, "lists no")

    def test_an_asan_dll_must_be_a_dll_of_the_target_that_exports_the_runtime_entry(self):
        files = self.good()
        syntheticPe(self.path("arm"), machine=pw.MACHINE_ARM64, dll=True, exports=(sr.ASAN_INIT,))
        syntheticPe(self.path("exe"), dll=False, exports=(sr.ASAN_INIT,))
        syntheticPe(self.path("bare"), dll=True, exports=("other",))
        for content, pattern in ((self.path("arm"), "machine 0xaa64 is not AMD64"), (self.path("exe"), "is not a DLL"),
                                 (self.path("bare"), "does not export __asan_init")):
            self.refused(sr.WINDOWS_X64, "asan", dict(files, dll=(DLL, open(content, "rb").read())), pattern)
        self.refused(sr.WINDOWS_X64, "asan", dict(files, dll=("runtime.bin", files["dll"][1])), "not named")

    def test_the_import_library_must_import_the_dll_it_is_deployed_with_and_define_the_entry(self):
        files = self.good()
        other = ar([("d.o", importMember(pw.MACHINE_AMD64, "other.dll"))])
        self.refused(sr.WINDOWS_X64, "asan", dict(files, importLibrary=(IMPORT_LIBRARY, other)), "names no import of " + DLL)
        table = dict(SYMBOLS_OF, **{IMPORT_LIBRARY: set()})
        for role in files:
            write(self.path(files[role][0]), files[role][1])
        paths = {role: self.path(name) for role, (name, _) in files.items()}
        with mock.patch.object(pc, "archiveSymbols", archiveSymbolsOf(table)):
            with self.assertRaisesRegex(pe.EngineError, "defines no __asan_init"):
                sr.checkFiles("/engine", sr.WINDOWS_X64, "asan", paths)

    def test_the_thunk_must_define_the_seh_interceptor_and_be_of_the_target_machine(self):
        files = self.good()
        self.refused(sr.WINDOWS_X64, "asan", dict(files, thunk=(THUNK, ar([("t.o", coffObject(pw.MACHINE_ARM64))]))),
                     "thunk .*machine 0xaa64")
        table = dict(SYMBOLS_OF, **{THUNK: set()})
        for role in files:
            write(self.path(files[role][0]), files[role][1])
        paths = {role: self.path(name) for role, (name, _) in files.items()}
        with mock.patch.object(pc, "archiveSymbols", archiveSymbolsOf(table)):
            with self.assertRaisesRegex(pe.EngineError, "defines no __asan_seh_interceptor"):
                sr.checkFiles("/engine", sr.WINDOWS_X64, "asan", paths)


class BundleCase(TempCase):
    """A bundle runtime with the base configs and receipts of the four sanitizer targets, and a payload for them."""

    def setUp(self):
        super().setUp()
        self.engine = self.path("engine")
        write(os.path.join(self.engine, "bin", "llvm-symbolizer"))
        self.runtime = self.path("engine", "runtime")
        self.payload = self.path("payload")
        self.out = self.path("out", "overlay")
        aliases = [{"alias": "lib%s.so" % n, "target": "lib%s.so.1" % n} for n in sr.LINUX_DRIVER_LIBRARIES]
        self.linuxReceipt = {"engineRelative": "..", "targets": [{"target": sr.LINUX_X64, "libraryAliases": aliases},
                                                                  {"target": sr.LINUX_ARM64, "libraryAliases": aliases}]}
        self.startup = "crt2.obj"
        self.windowsReceipt = {"engineRelative": "../..", "targets": [sr.WINDOWS_X64, sr.WINDOWS_ARM64],
                               "variants": self.variants()}
        self.writeBase()
        self.manifest = {"schema": 1, "source": {"release": "llvmorg-23.1.0", "commit": COMMIT, "build": "llvm-mingw"},
                         "targets": {}}
        patches = (mock.patch.object(pr, "engineMajor", return_value=("linux-x64", "23.1.0", "23")),
                   mock.patch.object(pc, "archiveSymbols", archiveSymbolsOf(SYMBOLS_OF)),
                   mock.patch.object(sr, "verifyTree", return_value=("root", "merged")),
                   mock.patch.object(sr, "checkProfiles"))
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def variants(self):
        return [{"target": t, "variant": v, "startupObject": s}
                for t in (sr.WINDOWS_X64, sr.WINDOWS_ARM64) for v, s in (("exe", self.startup), ("dll", "dllcrt2.obj"))]

    def writeBase(self):
        base = WINDOWS_BASE.replace("crt2.obj", self.startup)
        for target, spec in sr.TARGETS.items():
            write(os.path.join(self.runtime, spec["base"]), LINUX_BASE if spec["format"] == "elf" else base)
        write(os.path.join(self.runtime, sr.LINUX_X64 + ".cxx.cfg"), "-isystem <CFGDIR>/include/cxx/libcxx\n")
        write(os.path.join(self.runtime, "notices", "runtime-provenance.json"), json.dumps(self.linuxReceipt))
        write(os.path.join(self.runtime, "windows", "notices", pw.PROVENANCE), json.dumps(self.windowsReceipt))

    def addPayload(self, target, profile, files):
        """files: {role: (relative path, content)}; the manifest names them."""
        for role, (relative, content) in files.items():
            write(os.path.join(self.payload, relative), content)
        self.manifest["targets"].setdefault(target, {})[profile] = {role: relative for role, (relative, _) in files.items()}

    def addAll(self):
        self.addPayload(sr.LINUX_X64, "ubsan", {"archive": ("lx/" + UBSAN_X64, ar([("u.o", elfObject(ELF_X64))])),
                                                "dynamicList": ("lx/" + UBSAN_X64 + ".syms", b"{ __ubsan_handle_add_overflow; };")})
        self.addPayload(sr.WINDOWS_X64, "ubsan", {"archive": ("wx/" + UBSAN_X64, ar([("u.o", coffObject(pw.MACHINE_AMD64))]))})
        syntheticPe(self.path("built.dll"), dll=True, exports=(sr.ASAN_INIT,))
        self.addPayload(sr.WINDOWS_X64, "asan", {
            "importLibrary": ("wa/" + IMPORT_LIBRARY, ar([("d.o", importMember(pw.MACHINE_AMD64, DLL))])),
            "thunk": ("wa/" + THUNK, ar([("t.o", coffObject(pw.MACHINE_AMD64))])),
            "dll": ("wa/" + DLL, open(self.path("built.dll"), "rb").read())})
        self.addPayload(sr.WINDOWS_ARM64, "ubsan", {"archive": ("wr/" + UBSAN_ARM64, ar([("u.o", coffObject(pw.MACHINE_ARM64))]))})
        self.writeManifest()

    def addArm64Linux(self):
        self.addPayload(sr.LINUX_ARM64, "ubsan", {"archive": ("la/" + UBSAN_ARM64, ar([("u.o", elfObject(ELF_ARM64))]))})
        self.writeManifest()

    def writeManifest(self):
        write(os.path.join(self.payload, sr.MANIFEST), json.dumps(self.manifest))

    def prepare(self, targets=None):
        return sr.prepareSanitizerRuntime(self.engine, self.runtime, self.payload, self.out, targets)

    def refused(self, pattern, targets=None):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.prepare(targets)
        self.assertFalse(os.path.lexists(self.out))
        self.assertEqual([n for n in os.listdir(self.path("out")) if "partial" in n] if os.path.isdir(self.path("out")) else [], [])


class OverlayTest(BundleCase):
    def test_the_overlay_holds_exactly_the_configs_the_profile_directories_and_the_receipt(self):
        self.addAll()
        out, receipt = self.prepare()
        files = sorted(os.path.relpath(os.path.join(d, n), out).replace(os.sep, "/") for d, _, names in os.walk(out) for n in names)
        self.assertEqual(files, sorted([
            "x86_64-linux-gnu.2.31.ubsan.cfg", "x86_64-linux-gnu.2.31.ubsan/" + UBSAN_X64,
            "x86_64-linux-gnu.2.31.ubsan/" + UBSAN_X64 + ".syms",
            "windows/x86_64-windows-gnu.ubsan.cfg", "windows/x86_64-windows-gnu.ubsan/" + UBSAN_X64,
            "windows/x86_64-windows-gnu.asan.cfg", "windows/x86_64-windows-gnu.asan/" + IMPORT_LIBRARY,
            "windows/x86_64-windows-gnu.asan/" + THUNK, "windows/x86_64-windows-gnu.asan/" + DLL,
            "windows/aarch64-windows-gnu.ubsan.cfg", "windows/aarch64-windows-gnu.ubsan/" + UBSAN_ARM64,
            sr.PROVENANCE]))
        self.assertEqual(sorted(f.replace(os.sep, "/") for f in receipt["files"]),
                         sorted(f for f in files if f != sr.PROVENANCE))

    def test_every_config_is_the_rendering_of_its_recorded_files(self):
        self.addAll()
        out, receipt = self.prepare()
        for record in receipt["profiles"]:
            names = {f["role"]: f["name"] for f in record["files"]}
            self.assertEqual(read(os.path.join(out, record["config"])), sr.renderProfile(record["target"], record["profile"], names))
            self.assertEqual(record["base"], sr.TARGETS[record["target"]]["base"])

    def test_the_receipt_records_identity_provenance_deployment_and_what_it_does_not_certify(self):
        self.addAll()
        out, receipt = self.prepare([sr.WINDOWS_X64])
        on_disk = json.loads(read(os.path.join(out, sr.PROVENANCE)))
        self.assertEqual(on_disk, receipt)
        self.assertEqual(receipt["kind"], sr.RECEIPT_KIND)
        self.assertIs(receipt["redistributionCertified"], False)
        self.assertEqual(receipt["source"], self.manifest["source"])
        self.assertEqual(receipt["payloadManifestSha256"], pe.sha256File(os.path.join(self.payload, sr.MANIFEST)))
        self.assertEqual(receipt["baseRuntimeProvenanceSha256"], {
            "windows/notices/" + pw.PROVENANCE: pe.sha256File(os.path.join(self.runtime, "windows", "notices", pw.PROVENANCE))})
        self.assertEqual(receipt["engineVersion"], "23.1.0")
        self.assertTrue(receipt["limits"])
        asan = next(p for p in receipt["profiles"] if p["profile"] == "asan")
        dll = next(f for f in asan["files"] if f["role"] == "dll")
        self.assertEqual(asan["deploy"], [{"name": DLL, "path": "windows/x86_64-windows-gnu.asan/" + DLL,
                                           "destination": "beside every executable", "sha256": dll["sha256"]}])
        self.assertEqual((asan["symbolizer"]["deliveredBy"], asan["symbolizer"]["environment"]),
                         ("engine", "ASAN_SYMBOLIZER_PATH"))
        self.assertIs(asan["symbolizer"]["shippedByProfile"], False)
        self.assertEqual(asan["flags"], ["-fsanitize=address"])
        ubsan = next(p for p in receipt["profiles"] if p["profile"] == "ubsan")
        self.assertEqual(ubsan["deploy"], [])
        self.assertEqual(ubsan["flags"], ["-fsanitize=undefined", "-fno-sanitize-recover=undefined", "-fno-rtlib-defaultlib"])

    def test_the_copied_files_are_the_payloads_files_byte_for_byte(self):
        self.addAll()
        out, receipt = self.prepare([sr.LINUX_X64])
        for record in receipt["profiles"]:
            for item in record["files"]:
                self.assertEqual(pe.sha256File(os.path.join(out, record["directory"], item["name"])),
                                 pe.sha256File(os.path.join(self.payload, item["payloadPath"])))

    def test_a_target_not_named_is_not_written_and_the_manifest_may_hold_more_than_is_asked(self):
        self.addAll()
        out, receipt = self.prepare([sr.WINDOWS_ARM64])
        self.assertEqual([p["target"] for p in receipt["profiles"]], [sr.WINDOWS_ARM64])
        self.assertFalse(os.path.exists(os.path.join(out, "x86_64-linux-gnu.2.31.ubsan.cfg")))

    def test_the_proof_runs_on_a_tree_with_the_overlay_merged_and_sees_every_profile(self):
        self.addAll()
        self.prepare()
        sr.verifyTree.assert_called_once()
        records = sr.checkProfiles.call_args[0][2]
        self.assertEqual([(r["target"], r["profile"]) for r in records], [
            (sr.LINUX_X64, "ubsan"), (sr.WINDOWS_X64, "ubsan"), (sr.WINDOWS_X64, "asan"), (sr.WINDOWS_ARM64, "ubsan")])

    def test_a_source_built_windows_base_with_crt2_o_and_an_import_library_of_any_name_is_prepared(self):
        self.startup = "crt2.o"
        self.windowsReceipt["variants"] = self.variants()
        self.writeBase()
        self.addAll()
        arbitrary = "asan_rt.lib"
        self.manifest["targets"][sr.WINDOWS_X64]["asan"]["importLibrary"] = "wa/" + arbitrary
        write(os.path.join(self.payload, "wa", arbitrary), ar([("d.o", importMember(pw.MACHINE_AMD64, DLL))]))
        self.writeManifest()
        table = dict(SYMBOLS_OF, **{arbitrary: {sr.ASAN_INIT}})
        with mock.patch.object(pc, "archiveSymbols", archiveSymbolsOf(table)):
            out, receipt = self.prepare([sr.WINDOWS_X64])
        asan = next(p for p in receipt["profiles"] if p["profile"] == "asan")
        self.assertIn(arbitrary, [f["name"] for f in asan["files"] if f["role"] == "importLibrary"])
        self.assertIn("-Xlinker <CFGDIR>/x86_64-windows-gnu.asan/" + arbitrary, read(os.path.join(out, asan["config"])).splitlines())

    def test_a_linux_ubsan_record_names_the_unwinder_config_and_symbols_the_proof_must_link_with(self):
        self.addAll()
        _, receipt = self.prepare([sr.LINUX_X64, sr.WINDOWS_X64])
        linux, windows = receipt["profiles"][0], receipt["profiles"][1]
        self.assertEqual(linux["unwinder"], {"config": "x86_64-linux-gnu.2.31.cxx.cfg",
                                            "symbols": ["_Unwind_Backtrace", "_Unwind_GetIP"],
                                            "provider": "libunwind.a of the C++ overlay"})
        self.assertIsNone(windows["unwinder"])

    def test_an_output_that_exists_is_never_replaced(self):
        self.addAll()
        os.makedirs(self.out)
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            self.prepare()


class RefusalTest(BundleCase):
    def test_a_missing_payload_file_is_refused_and_leaves_nothing(self):
        self.addAll()
        os.remove(os.path.join(self.payload, "wa", THUNK))
        self.refused("windows-gnu asan thunk: payload file wa/%s is missing" % THUNK)

    def test_a_target_the_manifest_has_no_files_for_is_refused(self):
        self.addPayload(sr.LINUX_X64, "ubsan", {"archive": ("lx/" + UBSAN_X64, ar([("u.o", elfObject(ELF_X64))]))})
        self.writeManifest()
        self.refused("names no files for x86_64-windows-gnu", [sr.LINUX_X64, sr.WINDOWS_X64])

    def test_a_target_without_a_base_config_is_refused(self):
        self.addAll()
        os.remove(os.path.join(self.runtime, "windows", "x86_64-windows-gnu.cfg"))
        self.refused("no base config windows/x86_64-windows-gnu.cfg", [sr.WINDOWS_X64])

    def test_a_target_outside_the_sanitizer_set_is_refused(self):
        self.addAll()
        self.refused("no sanitizer profile", ["wasm32-wasi"])
        self.refused("duplicate", [sr.LINUX_X64, sr.LINUX_X64])

    def test_a_base_runtime_without_its_receipt_or_not_prepared_for_the_target_is_refused(self):
        self.addAll()
        os.remove(os.path.join(self.runtime, "windows", "notices", pw.PROVENANCE))
        self.refused("has no windows/notices", [sr.WINDOWS_X64])
        self.windowsReceipt["targets"] = [sr.WINDOWS_ARM64]
        self.writeBase()
        self.refused("was not prepared for x86_64-windows-gnu", [sr.WINDOWS_X64])

    def test_a_base_runtime_that_is_not_a_bundle_runtime_is_refused(self):
        self.addAll()
        self.linuxReceipt["engineRelative"] = "../engine"
        self.windowsReceipt["engineRelative"] = ".."
        self.writeBase()
        self.refused("need a bundle runtime", [sr.LINUX_X64])
        self.refused("need a bundle runtime", [sr.WINDOWS_X64])

    def test_a_linux_base_runtime_without_a_library_the_sanitizer_link_needs_is_refused(self):
        self.addAll()
        for missing in sr.LINUX_DRIVER_LIBRARIES:
            kept = [{"alias": "lib%s.so" % n, "target": "x"} for n in sr.LINUX_DRIVER_LIBRARIES if n != missing]
            self.linuxReceipt["targets"][0]["libraryAliases"] = kept
            self.writeBase()
            self.refused("no lib%s.so for the sanitizer link" % missing, [sr.LINUX_X64])

    def test_two_roles_with_one_file_name_are_refused(self):
        self.addAll()
        shutil_copy = os.path.join(self.payload, "wa", THUNK)
        write(os.path.join(self.payload, "wb", IMPORT_LIBRARY), open(shutil_copy, "rb").read())
        self.manifest["targets"][sr.WINDOWS_X64]["asan"]["thunk"] = "wb/" + IMPORT_LIBRARY
        self.writeManifest()
        self.refused("share a file name", [sr.WINDOWS_X64])

    def test_a_payload_file_of_another_architecture_stops_the_whole_overlay(self):
        self.addAll()
        self.addArm64Linux()
        write(os.path.join(self.payload, "la", UBSAN_ARM64), ar([("u.o", elfObject(ELF_X64))]))
        self.refused("machine 0x3e, not elf machine 0xb7", [sr.LINUX_ARM64])

    def test_a_linux_ubsan_profile_needs_the_unwinder_only_the_cxx_overlay_provides_and_names_it(self):
        self.addAll()
        self.addArm64Linux()
        self.refused("calls _Unwind_Backtrace and _Unwind_GetIP.*no aarch64-linux-gnu.2.31.cxx.cfg", [sr.LINUX_ARM64])
        os.remove(os.path.join(self.runtime, sr.LINUX_X64 + ".cxx.cfg"))
        self.refused("no x86_64-linux-gnu.2.31.cxx.cfg", [sr.LINUX_X64])
        self.prepare([sr.WINDOWS_X64, sr.WINDOWS_ARM64])

    def test_an_asan_profile_whose_base_receipt_records_no_startup_object_is_refused_but_ubsan_is_not(self):
        self.addAll()
        for variant in self.windowsReceipt["variants"]:
            del variant["startupObject"]
        self.writeBase()
        self.refused("records no startupObject for the executable variant", [sr.WINDOWS_X64])
        self.prepare([sr.WINDOWS_ARM64])

    def test_a_base_receipt_with_two_executable_startup_objects_is_refused(self):
        self.addAll()
        self.windowsReceipt["variants"].append({"target": sr.WINDOWS_X64, "variant": "exe", "startupObject": "crt2.o"})
        self.writeBase()
        self.refused("records 2 startup objects", [sr.WINDOWS_X64])

    def test_a_startup_object_name_that_would_need_quoting_is_refused(self):
        self.addAll()
        self.windowsReceipt["variants"][0]["startupObject"] = "cr t2.o"
        self.writeBase()
        self.refused("unsupported file name", [sr.WINDOWS_X64])

    def test_a_manifest_release_of_another_major_stops_before_any_file_is_read(self):
        self.addAll()
        self.manifest["source"]["release"] = "llvmorg-22.1.1"
        self.writeManifest()
        self.refused("major 22, the engine's clang is 23")

    def test_an_engine_without_its_symbolizer_refuses_the_asan_profile_but_not_ubsan(self):
        self.addAll()
        os.remove(os.path.join(self.engine, "bin", "llvm-symbolizer"))
        self.refused("has 0 of llvm-symbolizer and llvm-symbolizer.exe", [sr.WINDOWS_X64])
        self.prepare([sr.LINUX_X64, sr.WINDOWS_ARM64])

    def test_an_engine_with_both_symbolizer_spellings_is_refused_rather_than_chosen_between(self):
        write(os.path.join(self.engine, "bin", "llvm-symbolizer.exe"))
        with self.assertRaisesRegex(pe.EngineError, "has 2 of"):
            sr.symbolizerPath(self.engine)

    def test_a_proof_failure_leaves_no_overlay(self):
        self.addAll()
        sr.checkProfiles.side_effect = pe.EngineError("link failed")
        self.refused("link failed")


class ReceiptTest(BundleCase):
    def setUp(self):
        super().setUp()
        self.addAll()
        out, self.receipt = self.prepare([sr.WINDOWS_X64])
        self.overlay = out

    def test_a_merged_runtime_matches_its_receipt(self):
        sr.verifyReceiptFiles(self.overlay, self.receipt)

    def test_a_changed_missing_or_linked_file_is_found(self):
        target = os.path.join(self.overlay, "windows", "x86_64-windows-gnu.asan", DLL)
        with open(target, "ab") as f:
            f.write(b"x")
        with self.assertRaisesRegex(pe.EngineError, "differs from the receipt"):
            sr.verifyReceiptFiles(self.overlay, self.receipt)
        os.remove(target)
        with self.assertRaisesRegex(pe.EngineError, "differs from the receipt"):
            sr.verifyReceiptFiles(self.overlay, self.receipt)

    def test_a_copied_file_that_became_a_reparse_point_is_found(self):
        target = os.path.join(self.overlay, "windows/x86_64-windows-gnu.asan", DLL)
        with reparse(target), mock.patch.object(os.path, "islink", return_value=False):
            with self.assertRaisesRegex(pe.EngineError, "differs from the receipt"):
                sr.verifyReceiptFiles(self.overlay, self.receipt)

    def test_a_missing_config_is_found(self):
        os.remove(os.path.join(self.overlay, "windows", "x86_64-windows-gnu.asan.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "config windows/x86_64-windows-gnu.asan.cfg is missing"):
            sr.verifyReceiptFiles(self.overlay, self.receipt)

    def test_prove_wants_a_runtime_that_is_the_runtime_child_of_the_engine(self):
        with mock.patch.object(pe, "verifyEngine", return_value=("h", "v", [])):
            with self.assertRaisesRegex(pe.EngineError, "not the `runtime` child"):
                sr.prove(self.engine, self.overlay)

    def test_prove_refuses_a_receipt_of_another_kind_or_one_that_certifies_redistribution(self):
        runtime = self.runtime
        write(os.path.join(runtime, sr.PROVENANCE), json.dumps(dict(self.receipt, kind="other")))
        with mock.patch.object(pe, "verifyEngine", return_value=("h", "v", [])):
            with self.assertRaisesRegex(pe.EngineError, "not a sanitizer-runtime-payload receipt"):
                sr.prove(self.engine, runtime)
            write(os.path.join(runtime, sr.PROVENANCE), json.dumps(dict(self.receipt, redistributionCertified=True)))
            with self.assertRaisesRegex(pe.EngineError, "not a sanitizer-runtime-payload receipt"):
                sr.prove(self.engine, runtime)


def record(target, profile, deploy=(), unwinder=None):
    return {"target": target, "profile": profile, "config": sr.profileConfig(target, profile),
            "base": sr.TARGETS[target]["base"], "directory": sr.profileDirectory(target, profile), "deploy": list(deploy),
            "unwinder": unwinder}


def finished(returncode=0, stdout="", stderr=""):
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


class RunTest(unittest.TestCase):
    UBSAN_REPORT = "%s:6:20: runtime error: signed integer overflow: 2147483647 + 1 cannot be represented in type 'int'\n"

    def run_(self, profile, index, done, target=sr.LINUX_X64):
        sr.checkRun(record(target, profile), sr.CASES[profile][index], done)

    def test_the_fixtures_hold_the_faults_the_cases_expect(self):
        directory = sr.FIXTURES
        self.assertEqual(sr.lineOf(os.path.join(directory, "sanitizerSignedOverflow.c"), "big + argc"), 6)
        self.assertIn("INT_MAX", read(os.path.join(directory, "sanitizerSignedOverflow.c")))
        self.assertIn("p[argc + 3] = 1", read(os.path.join(directory, "sanitizerHeapOverflow.c")))
        self.assertEqual(sr.lineOf(os.path.join(directory, "sanitizerHeapOverflow.c"), "p[argc + 3]"), 7)
        self.assertIn("malloc(4 * sizeof(int))", read(os.path.join(directory, "sanitizerHeapOverflow.c")))
        clean = read(os.path.join(directory, "sanitizerClean.c"))
        self.assertIn("p[argc + 2]", clean)
        self.assertIn('"ok"', clean)

    def test_a_clean_run_exits_zero_prints_ok_and_reports_nothing(self):
        self.run_("ubsan", 0, finished(0, sr.CLEAN_OUTPUT))
        for done in (finished(1, sr.CLEAN_OUTPUT), finished(0, "wrong\n"), finished(0, sr.CLEAN_OUTPUT, "runtime error")):
            with self.assertRaisesRegex(pe.EngineError, "expected a clean run"):
                self.run_("ubsan", 0, done)

    def test_a_signed_overflow_is_reported_with_its_source_line_and_exits_nonzero(self):
        self.run_("ubsan", 1, finished(1, "", self.UBSAN_REPORT % "C:/w/sanitizerSignedOverflow.c"))

    def test_an_overflow_that_exits_zero_prints_nothing_or_names_no_line_is_refused(self):
        report = self.UBSAN_REPORT % "C:/w/sanitizerSignedOverflow.c"
        with self.assertRaisesRegex(pe.EngineError, "exited 0 after a fault"):
            self.run_("ubsan", 1, finished(0, "", report))
        with self.assertRaisesRegex(pe.EngineError, "without 'runtime error: signed integer overflow'"):
            self.run_("ubsan", 1, finished(132, "", ""))
        with self.assertRaisesRegex(pe.EngineError, "without 'runtime error: signed integer overflow'"):
            self.run_("ubsan", 1, finished(-4, "", "Illegal instruction"))
        with self.assertRaisesRegex(pe.EngineError, "no source location sanitizerSignedOverflow.c:6:"):
            self.run_("ubsan", 1, finished(1, "", "runtime error: signed integer overflow\n"))
        with self.assertRaisesRegex(pe.EngineError, "no source location"):
            self.run_("ubsan", 1, finished(1, "", "sanitizerSignedOverflow.c:5:1: runtime error: signed integer overflow\n"))

    def test_a_heap_overflow_is_reported_and_exits_nonzero(self):
        report = "==1==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x1\n    #0 0x1 in main C:/w/sanitizerHeapOverflow.c:7:5\n"
        self.run_("asan", 1, finished(1, "", report), sr.WINDOWS_X64)
        with self.assertRaisesRegex(pe.EngineError, "exited 0 after a fault"):
            self.run_("asan", 1, finished(0, "", report), sr.WINDOWS_X64)
        with self.assertRaisesRegex(pe.EngineError, "no source location sanitizerHeapOverflow.c:7:"):
            self.run_("asan", 1, finished(1, "", "ERROR: AddressSanitizer: heap-buffer-overflow\n    #0 0x1 in main\n"),
                      sr.WINDOWS_X64)
        with self.assertRaisesRegex(pe.EngineError, "heap-buffer-overflow"):
            self.run_("asan", 1, finished(1, "", "ERROR: AddressSanitizer: stack-buffer-overflow"), sr.WINDOWS_X64)

    def test_each_profile_has_a_clean_case_and_one_fault_case(self):
        for profile, cases in sr.CASES.items():
            self.assertEqual(["report" in c for c in cases], [False, True])
            self.assertTrue(all(os.path.isfile(os.path.join(sr.FIXTURES, c["fixture"])) for c in cases))


class HostTest(unittest.TestCase):
    def can(self, target, system, machine):
        with mock.patch.object(sys, "platform", system), mock.patch("platform.machine", return_value=machine):
            return sr.hostCanRun(target)

    def test_a_host_runs_only_the_targets_of_its_system_and_cpu(self):
        self.assertTrue(self.can(sr.LINUX_X64, "linux", "x86_64"))
        self.assertTrue(self.can(sr.LINUX_ARM64, "linux", "aarch64"))
        self.assertTrue(self.can(sr.WINDOWS_X64, "win32", "AMD64"))
        self.assertTrue(self.can(sr.WINDOWS_ARM64, "win32", "ARM64"))
        for target, system, machine in ((sr.LINUX_X64, "darwin", "arm64"), (sr.LINUX_X64, "linux", "aarch64"),
                                        (sr.LINUX_ARM64, "linux", "x86_64"), (sr.WINDOWS_X64, "linux", "x86_64"),
                                        (sr.WINDOWS_X64, "win32", "ARM64"), (sr.WINDOWS_ARM64, "win32", "AMD64")):
            self.assertFalse(self.can(target, system, machine), (target, system, machine))

    def test_a_profile_the_host_cannot_run_is_reported_and_refused_under_require_run(self):
        records = [record(sr.WINDOWS_X64, "ubsan")]
        with mock.patch.object(sr, "hostCanRun", return_value=False), mock.patch.object(sr, "checkProfile") as check:
            sr.checkProfiles("/r", "/r/runtime", records, "/w", False)
            check.assert_called_once_with(os.path.join("/r", "bin", "clang"), "/r/runtime", "/w", records[0], False)
            with self.assertRaisesRegex(pe.EngineError, "cannot be run on this host"):
                sr.checkProfiles("/r", "/r/runtime", records, "/w", True)

    def test_the_environment_drops_what_would_change_a_sanitizer_run(self):
        with mock.patch.dict(os.environ, {"ASAN_OPTIONS": "halt_on_error=0", "UBSAN_OPTIONS": "halt_on_error=0", "KEEP": "1"}):
            found = sr.environment()
        self.assertEqual((found.get("KEEP"), "ASAN_OPTIONS" in found, "UBSAN_OPTIONS" in found), ("1", False, False))


class ProfileRunTest(TempCase):
    def setUp(self):
        super().setUp()
        self.runtime = self.path("runtime")
        self.commands, self.programs = [], []
        self.clang = self.path("root", "bin", "clang")
        self.symbolizer = self.path("root", "bin", "llvm-symbolizer.exe")
        write(self.symbolizer)
        write(os.path.join(self.runtime, "windows", "x86_64-windows-gnu.asan", DLL), b"dll")
        self.asan = record(sr.WINDOWS_X64, "asan", [{"name": DLL, "path": "windows/x86_64-windows-gnu.asan/" + DLL}])

    def run_(self, rec, execute, imports=(DLL, "kernel32.dll"), outcome=None):
        def step(name, command, work):
            self.commands.append((name, command))
            return finished()

        def program(command, work, extra=None):
            self.programs.append((command, sorted(os.listdir(work)), extra))
            return outcome(command) if outcome else finished(0, sr.CLEAN_OUTPUT)

        with mock.patch.object(sr, "runStep", step), mock.patch.object(sr, "runProgram", program), \
                mock.patch.object(pw, "readPe", return_value={"imports": {i: [] for i in imports}}):
            sr.checkProfile(self.clang, self.runtime, self.path("work"), rec, execute)

    def test_each_case_is_compiled_and_linked_through_the_profile_config_before_the_base_config(self):
        self.run_(self.asan, False)
        names = [n for n, _ in self.commands]
        self.assertEqual(names, ["compile sanitizerClean.c", "link sanitizerClean.c",
                                 "compile sanitizerHeapOverflow.c", "link sanitizerHeapOverflow.c"])
        for _, command in self.commands:
            self.assertEqual(command[:4], [self.clang, "--no-default-config",
                                           "--config=" + os.path.join(self.runtime, "windows/x86_64-windows-gnu.asan.cfg"),
                                           "--config=" + os.path.join(self.runtime, "windows/x86_64-windows-gnu.cfg")])
        self.assertEqual(self.programs, [])

    def test_the_dll_is_deployed_beside_every_executable_before_it_runs(self):
        self.run_(self.asan, True, outcome=lambda command: finished(0, sr.CLEAN_OUTPUT) if "Clean" in command[0]
                  else finished(1, "", "ERROR: AddressSanitizer: heap-buffer-overflow\n  #0 in main sanitizerHeapOverflow.c:7:5"))
        self.assertEqual(len(self.programs), 2)
        for command, listing, extra in self.programs:
            self.assertIn(DLL, listing)
            self.assertTrue(command[0].endswith(".exe"))
            self.assertEqual(extra, {"ASAN_SYMBOLIZER_PATH": self.symbolizer})

    def test_the_asan_proof_compiles_with_debug_info_and_names_the_engine_symbolizer_never_path(self):
        self.run_(self.asan, False)
        self.assertTrue(all("-g" in c for n, c in self.commands if n.startswith("compile")))
        os.remove(self.symbolizer)
        with self.assertRaisesRegex(pe.EngineError, "has 0 of llvm-symbolizer and llvm-symbolizer.exe"):
            self.run_(self.asan, True)

    def test_a_linked_executable_that_does_not_import_the_deployed_dll_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "imports .*kernel32.dll.*, not " + DLL):
            self.run_(self.asan, False, imports=("kernel32.dll",))

    def test_a_run_that_fails_the_expectation_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "exited 0 after a fault"):
            self.run_(self.asan, True)

    def test_a_linux_profile_links_an_out_file_and_needs_no_import_check(self):
        rec = record(sr.LINUX_X64, "ubsan", unwinder={"config": "x86_64-linux-gnu.2.31.cxx.cfg"})
        self.run_(rec, True, outcome=lambda command: finished(0, sr.CLEAN_OUTPUT) if "Clean" in command[0]
                  else finished(1, "", "sanitizerSignedOverflow.c:6:20: runtime error: signed integer overflow"))
        self.assertTrue(all(command[0].endswith(".out") for command, _, _ in self.programs))

    def test_a_linux_proof_names_the_cxx_config_first_as_the_compiler_does_then_the_profile_then_the_base(self):
        rec = record(sr.LINUX_X64, "ubsan", unwinder={"config": "x86_64-linux-gnu.2.31.cxx.cfg"})
        self.run_(rec, False)
        for _, command in self.commands:
            self.assertEqual(command[1:5], [
                "--no-default-config", "--config=" + os.path.join(self.runtime, "x86_64-linux-gnu.2.31.cxx.cfg"),
                "--config=" + os.path.join(self.runtime, "x86_64-linux-gnu.2.31.ubsan.cfg"),
                "--config=" + os.path.join(self.runtime, "x86_64-linux-gnu.2.31.cfg")])

    def test_a_windows_proof_has_no_unwinder_config(self):
        self.run_(record(sr.WINDOWS_X64, "ubsan"), False)
        self.assertTrue(all("cxx" not in " ".join(command) for _, command in self.commands))


class MainTest(TempCase):
    def test_a_failure_is_reported_and_exits_one(self):
        with mock.patch.object(sr, "prepareSanitizerRuntime", side_effect=pe.EngineError("boom")):
            with mock.patch("sys.stderr") as stderr:
                code = sr.main(["--engine", "e", "--runtime", "r", "--payload", "p", "--output", "o"])
        self.assertEqual(code, 1)
        self.assertIn("boom", "".join(c.args[0] for c in stderr.write.call_args_list))

    def test_preparing_needs_a_payload_and_an_output(self):
        with self.assertRaises(SystemExit):
            with mock.patch("sys.stderr"):
                sr.main(["--engine", "e", "--runtime", "r"])


if __name__ == "__main__":
    unittest.main()
