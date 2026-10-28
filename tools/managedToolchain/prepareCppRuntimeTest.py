import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
from prepareWindowsRuntimeTest import syntheticPe

LINUX_CXX = ("/z/lib/libcxx/include", "/z/lib/libcxxabi/include", "/z/lib/include", "/z/lib/libc/include/x86-linux-gnu",
             "/z/lib/libc/include/generic-glibc", "/z/lib/libc/include/any-linux-any", "/z/lib/libunwind/include")
DEFINES = ["-D_LIBCPP_ABI_VERSION=1", "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS"]
BASE = "\n".join(["-target x", "-D__GLIBC_MINOR__=31", "-isystem <CFGDIR>/include/libc/x86-linux-gnu",
                  "-isystem <CFGDIR>/include/libc/any-linux-any", "-Xlinker -L -Xlinker <CFGDIR>/t",
                  "-Xlinker --entry", "-Xlinker _start", "-Xlinker <CFGDIR>/t/crt1.o", "-Xlinker <CFGDIR>/t/libm.so.6"]) + "\n"


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareCppRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


def variant(**changes):
    return dict({"target": pc.LINUX, "variant": "exe", "libcDirectories": ["x86-linux-gnu", "generic-glibc", "any-linux-any"],
                 "definesInBase": ["-D__GLIBC_MINOR__=31"], "linkTokens": ["--entry", "_start", "crt1.o", "libm.so.6"]}, **changes)


class ConfigTest(unittest.TestCase):
    def test_a_linux_config_orders_headers_defines_late_unwind_directory_and_link_tail(self):
        self.assertEqual(pc.renderConfig(pc.LINUX, "exe", DEFINES).splitlines(), [
            "-isystem <CFGDIR>/include/cxx/libcxx", "-isystem <CFGDIR>/include/cxx/libcxxabi"] + DEFINES + [
            "-stdlib++-isystem <CFGDIR>/include/cxx/libunwind",
            "-Xlinker -L -Xlinker <CFGDIR>/x86_64-linux-gnu.2.31.cxx", "$-lc++abi", "$-lc++", "$-lunwind"])

    def test_the_windows_configs_reach_the_shared_headers_one_level_up_and_their_own_directory_beside_them(self):
        for kind in ("exe", "dll"):
            text = pc.renderConfig(pc.WINDOWS, kind, DEFINES)
            self.assertIn("-isystem <CFGDIR>/../include/cxx/libcxx\n", text)
            self.assertIn("-stdlib++-isystem <CFGDIR>/../include/cxx/libunwind\n", text)
            self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu.cxx\n", text)
        self.assertEqual({pc.VARIANTS[(pc.WINDOWS, k)]["config"] for k in ("exe", "dll")},
                         {"windows/x86_64-windows-gnu.cxx.cfg", "windows/x86_64-windows-gnu.dll.cxx.cfg"})

    def test_a_define_that_would_need_quoting_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "quoting"):
            pc.renderConfig(pc.LINUX, "exe", ["-DX=a b"])

    def test_only_the_library_defines_of_zigs_line_are_carried_and_the_rest_must_already_be_in_the_base_config(self):
        self.assertTrue("-D_LIBCPP_HAS_THREADS=1".startswith(pc.CPP_DEFINES))
        self.assertTrue("-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS".startswith(pc.CPP_DEFINES))
        self.assertFalse("-D__GLIBC_MINOR__=31".startswith(pc.CPP_DEFINES))


class LineTest(TempCase):
    def test_zigs_include_order_yields_its_lib_directory_and_the_libc_names(self):
        self.assertEqual(pc.splitIsystem(list(LINUX_CXX)),
                         ("/z/lib", ["x86-linux-gnu", "generic-glibc", "any-linux-any"]))

    def test_an_include_order_other_than_libcxx_abi_builtin_libc_unwind_is_refused(self):
        for order in (LINUX_CXX[1:], LINUX_CXX[:-1], (LINUX_CXX[1], LINUX_CXX[0]) + LINUX_CXX[2:]):
            with self.assertRaisesRegex(pe.EngineError, "include order"):
                pc.splitIsystem(list(order))

    def test_the_archives_must_follow_each_other_in_the_order_abi_cxx_unwind(self):
        names = pc.ARCHIVES[pc.LINUX]
        inputs = ["/c/crt1.o"] + ["/c/" + n for n in names] + ["/c/libm.so.6"]
        self.assertEqual(pc.splitArchives(inputs, names), ["/c/" + n for n in names])
        for broken in (inputs[:2] + inputs[3:], [inputs[0], inputs[2], inputs[1]] + inputs[3:],
                       inputs[:2] + ["/c/libm.so.6"] + inputs[2:]):
            with self.assertRaisesRegex(pe.EngineError, "in a row"):
                pc.splitArchives(broken, names)

    def test_the_cc1_line_of_the_fixture_gives_the_driver_defaults_it_carries(self):
        stderr = ('"/z/zig" -cc1 -triple x -main-file-name other.cpp -fno-use-cxa-atexit\n'
                  '"/z/zig" -cc1 -triple x -main-file-name main.cpp -fcxx-exceptions -fexceptions -exception-model=seh\n')
        self.assertEqual(pc.cc1Flags(stderr, "main.cpp"), ["-fcxx-exceptions", "-fexceptions", "-exception-model=seh"])
        with self.assertRaisesRegex(pe.EngineError, "no cc1 line"):
            pc.cc1Flags(stderr, "missing.cpp")


class CrossCheckTest(unittest.TestCase):
    def test_the_base_config_agrees_with_zigs_cxx_line(self):
        pc.crossCheck(variant(), BASE)

    def test_a_define_zig_passes_that_the_base_config_lacks_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "does not"):
            pc.crossCheck(variant(definesInBase=["-D__GLIBC_MINOR__=31", "-D_X=1"]), BASE)

    def test_a_libc_directory_order_zig_does_not_have_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "libc directories"):
            pc.crossCheck(variant(libcDirectories=["any-linux-any", "x86-linux-gnu"]), BASE)

    def test_a_link_token_the_base_config_lacks_or_reorders_is_refused(self):
        for tokens in (["--entry", "_start", "crt1.o", "libm.so.6", "--extra"], ["crt1.o", "--entry"]):
            with self.assertRaisesRegex(pe.EngineError, "link tokens"):
                pc.crossCheck(variant(linkTokens=tokens), BASE)

    def test_windows_library_lines_compare_as_lib_file_names(self):
        self.assertEqual(pc.baseTokens("-Xlinker <CFGDIR>/w/crt2.obj\n$-lzigc\n-Xlinker --image-base=1\n"),
                         ["crt2.obj", "zigc.lib", "--image-base=1"])


class OverlayTest(TempCase):
    def test_an_alias_is_a_relative_link_to_the_file_it_stands_for_per_target_naming(self):
        for names, expected in ((pc.ARCHIVES[pc.LINUX], {"libstdc++.a": "libc++.a", "libsupc++.a": "libc++abi.a",
                                                         "libgcc_eh.a": "libunwind.a", "libgcc_s.a": "libunwind.a"}),
                                (pc.ARCHIVES[pc.WINDOWS], {"stdc++.lib": "c++.lib", "supc++.lib": "c++abi.lib",
                                                           "gcc_eh.lib": "unwind.lib", "gcc_s.lib": "unwind.lib"})):
            directory = self.path(names[0])
            for name in names:
                write(os.path.join(directory, name))
            records = pc.linkAliases(directory, names)
            self.assertEqual({r["alias"]: r["target"] for r in records}, expected)
            self.assertEqual({a: os.readlink(os.path.join(directory, a)) for a in expected}, expected)

    def test_an_alias_that_would_replace_a_file_is_refused(self):
        names = pc.ARCHIVES[pc.LINUX]
        for name in names + ["libstdc++.a"]:
            write(self.path("d", name))
        with self.assertRaisesRegex(pe.EngineError, "collides"):
            pc.linkAliases(self.path("d"), names)

    def test_merging_adds_the_new_paths_keeps_links_and_refuses_a_taken_path_before_copying_any(self):
        write(self.path("overlay", "a", "new.txt"), "new")
        write(self.path("overlay", "lib.a"), "archive")
        os.symlink("lib.a", self.path("overlay", "alias.a"))
        write(self.path("runtime", "a", "old.txt"), "old")
        pc.mergeOverlay(self.path("overlay"), self.path("runtime"))
        self.assertEqual((read(self.path("runtime", "a", "new.txt")), read(self.path("runtime", "a", "old.txt"))), ("new", "old"))
        self.assertEqual(os.readlink(self.path("runtime", "alias.a")), "lib.a")
        write(self.path("overlay2", "fresh"), "x")
        write(self.path("overlay2", "a", "old.txt"), "other")
        with self.assertRaisesRegex(pe.EngineError, "already has"):
            pc.mergeOverlay(self.path("overlay2"), self.path("runtime"))
        self.assertFalse(os.path.exists(self.path("runtime", "fresh")))
        self.assertEqual(read(self.path("runtime", "a", "old.txt")), "old")

    def test_a_normalized_archive_whose_symbols_changed_is_refused(self):
        archive = self.path("cache", "libc++abi.a")
        write(archive)
        with mock.patch.object(pr, "copyInputs", return_value=[{"name": "libc++abi.a"}]), \
                mock.patch.object(pc, "archiveSymbols", side_effect=[[("T", "a")], [("T", "b")]]):
            with self.assertRaisesRegex(pe.EngineError, "changed its symbols"):
                pc.copyArchives("/e", pc.LINUX, [archive], self.path("out"))

    def test_windows_archives_are_copied_opaque(self):
        with mock.patch.object(pr, "copyInputs", return_value=[{"name": "c++.lib"}]) as copy, \
                mock.patch.object(pc, "archiveSymbols") as symbols:
            self.assertEqual(pc.copyArchives("/e", pc.WINDOWS, ["/c/c++.lib"], "/o"), [{"name": "c++.lib"}])
        symbols.assert_not_called()
        self.assertEqual(copy.call_args[0][2], "windows/x86_64-windows-gnu.cxx")

    def test_a_seed_cache_is_copied_and_the_shared_zig_cache_is_never_one(self):
        write(self.path("seed", "o", "entry"), "cached")
        pc.seedCache(self.path("seed"), self.path("work", "global"))
        self.assertEqual(read(self.path("work", "global", "o", "entry")), "cached")
        shared = os.path.expanduser("~/.cache/zig")
        for refused in (shared, os.path.join(shared, "o"), self.path("missing")):
            with self.assertRaisesRegex(pe.EngineError, "not a private cache"):
                pc.seedCache(refused, self.path("work2"))

    def test_targets_follow_the_base_configs_the_runtime_has(self):
        write(self.path("rt", "x86_64-linux-gnu.2.31.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX])
        for name in ("x86_64-windows-gnu.cfg", "x86_64-windows-gnu.dll.cfg"):
            write(self.path("rt", "windows", name))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX, pc.WINDOWS])
        self.assertEqual(pc.selectTargets(self.path("rt"), [pc.WINDOWS]), [pc.WINDOWS])
        for names, message in ((["aarch64-linux-gnu.2.31"], "no C\\+\\+ runtime"), ([pc.LINUX, pc.LINUX], "duplicate")):
            with self.assertRaisesRegex(pe.EngineError, message):
                pc.selectTargets(self.path("rt"), names)
        os.remove(self.path("rt", "windows", "x86_64-windows-gnu.dll.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "no base config"):
            pc.selectTargets(self.path("rt"), [pc.WINDOWS])


def syntheticElf(path, needed=("libc.so.6", "libm.so.6"), ehFrame=True):
    """An ELF64 whose one PT_LOAD maps file offset 0x200 at address 0x1000, holding a dynamic section and its strings."""
    strings = b"\0" + b"".join(n.encode() + b"\0" for n in needed)
    offsets, at = [], 1
    for n in needed:
        offsets.append(at)
        at += len(n) + 1
    dynamic = b"".join(struct.pack("<QQ", 1, o) for o in offsets) + struct.pack("<QQ", 5, 0x1000 + 16 * (len(needed) + 2)) + bytes(16)
    body = dynamic + strings
    headers = [struct.pack("<IIQQQQQQ", 1, 5, 0x200, 0x1000, 0x1000, len(body), len(body), 0),
               struct.pack("<IIQQQQQQ", 2, 6, 0x200, 0x1000, 0x1000, len(dynamic), len(dynamic), 0)]
    if ehFrame:
        headers.append(struct.pack("<IIQQQQQQ", 0x6474e550, 4, 0, 0, 0, 0, 0, 0))
    head = bytearray(0x200)
    head[:4] = b"\x7fELF"
    struct.pack_into("<Q", head, 32, 64)
    struct.pack_into("<HH", head, 54, 56, len(headers))
    head[64:64 + 56 * len(headers)] = b"".join(headers)
    with open(path, "wb") as f:
        f.write(bytes(head) + body)


class InspectTest(TempCase):
    def test_the_dynamic_dependencies_and_the_unwind_header_are_read_from_an_elf(self):
        syntheticElf(self.path("a"))
        self.assertEqual(pc.readElf(self.path("a")), (["libc.so.6", "libm.so.6"], True))
        syntheticElf(self.path("b"), needed=("libstdc++.so.6",), ehFrame=False)
        self.assertEqual(pc.readElf(self.path("b")), (["libstdc++.so.6"], False))

    def test_a_dependency_outside_glibc_or_a_missing_unwind_header_is_a_problem(self):
        for kwargs, message in (({"needed": ("libc.so.6", "libstdc++.so.6")}, "not glibc's"), ({"needed": ("libm.so.6",)}, "not glibc's"),
                                ({"ehFrame": False}, "PT_GNU_EH_FRAME")):
            syntheticElf(self.path("x"), **kwargs)
            with mock.patch.object(pr, "elfProblem", return_value=None), \
                    mock.patch.object(pr, "elfInterpreterProblem", return_value=None), \
                    mock.patch.object(pr, "glibcSymbolProblem", return_value=None):
                self.assertRegex(pc.elfCppProblem(self.path("x"), "nm"), message)

    def test_an_elf_problem_of_the_c_checks_comes_first(self):
        syntheticElf(self.path("x"))
        with mock.patch.object(pr, "elfProblem", return_value="not x86_64"):
            self.assertEqual(pc.elfCppProblem(self.path("x"), "nm"), "not x86_64")

    def pe(self, name, exceptionTable=True, **kwargs):
        syntheticPe(self.path(name), **kwargs)
        if exceptionTable:
            with open(self.path(name), "r+b") as f:
                f.seek(0x98 + 136)
                f.write(struct.pack("<II", 0x1000, 12))
        return self.path(name)

    def test_a_windows_executable_and_dll_on_the_c_runtime_with_an_exception_table_pass(self):
        self.assertIsNone(pc.peCppProblem(self.pe("exe", exports=()), "exe"))
        self.assertIsNone(pc.peCppProblem(self.pe("dll", dll=True, exports=("cppSum",)), "dll"))

    def test_a_wrong_kind_missing_export_foreign_runtime_or_missing_exception_table_is_a_problem(self):
        cases = [(self.pe("a", exports=()), "dll", "not an x86_64 dll"), (self.pe("b", dll=True, exports=("cppSum",)), "exe", "not an x86_64 exe"),
                 (self.pe("c", dll=True), "dll", "lack cppSum"),
                 (self.pe("d", exports=(), imports=(("KERNEL32.dll", ["x"]), ("libc++.dll", ["y"]))), "exe", "unexpected"),
                 (self.pe("e", exports=(), imports=(("KERNEL32.dll", ["x"]),)), "exe", "universal C runtime"),
                 (self.pe("f", exports=(), exceptionTable=False), "exe", "no exception table"),
                 (self.pe("g", exports=(), subsystem=2), "exe", "not console")]
        for path, kind, message in cases:
            self.assertRegex(pc.peCppProblem(path, kind), message)


class ControlTest(TempCase):
    def test_the_c_include_list_object_and_linked_file_must_not_change_with_the_overlay(self):
        listing = "#include <...> search starts here:\n %s/runtime/include/libc/a\nEnd of search list.\n"
        for root in ("merged", "control"):
            write(self.path(root, "runtime", "x86_64-linux-gnu.2.31.cfg"))
        linked = {"merged": b"exe", "control": b"exe"}

        def run(command):
            root = next(r for r in ("merged", "control") if self.path(r) in " ".join(command))
            if "-o" in command:
                with open(command[command.index("-o") + 1], "wb") as f:
                    f.write(b"obj" if "-c" in command else linked[root])
            return mock.Mock(returncode=0, stdout="", stderr=listing % self.path(root) if "-E" in command else "")

        pc.checkControl(run, self.path("merged", "runtime"), self.path("control", "runtime"), self.dir, variant())
        linked["merged"] = b"changed"
        self.setUp()
        for root in ("merged", "control"):
            write(self.path(root, "runtime", "x86_64-linux-gnu.2.31.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "C linked file changes"):
            pc.checkControl(run, self.path("merged", "runtime"), self.path("control", "runtime"), self.dir, variant())


class PipelineTest(TempCase):
    def setUp(self):
        super().setUp()
        self.zig = self.path("zig")
        write(self.zig, "#!/bin/sh\n")
        os.chmod(self.zig, 0o755)
        self.runtime = self.path("runtime")
        write(os.path.join(self.runtime, "x86_64-linux-gnu.2.31.cfg"))
        self.checked = []
        for patcher in (mock.patch.object(pr, "engineMajor", return_value=("aarch64-macos", "22.1.1", "22")),
                        mock.patch.object(pr, "zigIdentity", return_value={"version": "0.16.0", "sha256": "z"}),
                        mock.patch.object(pc, "produce", side_effect=self.produce),
                        mock.patch.object(pc, "verifyTrees", side_effect=lambda *a: ("m", "c")),
                        mock.patch.object(pc, "checkOverlay", side_effect=self.check)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def produce(self, zig, engine, targets, work, output, seed):
        for name in ("include/cxx/libcxx/vector", "include/cxx/libcxxabi/cxxabi.h", "include/cxx/libunwind/libunwind.h",
                     "x86_64-linux-gnu.2.31.cxx.cfg", "x86_64-linux-gnu.2.31.cxx/libc++.a"):
            write(os.path.join(output, name), name)
        self.seed = seed
        return [{"target": pc.LINUX, "variant": "exe"}], {pc.LINUX: {}}, {"zigLib": "/z/lib", "notices": ["notices/libcxx/LICENSE.TXT"]}

    def check(self, run, merged, control, work, receipt):
        self.checked.append(receipt)
        if getattr(self, "refuse", False):
            raise pe.EngineError("C++ link failed")

    def test_the_overlay_is_written_checked_and_described_by_a_receipt_that_certifies_nothing(self):
        out, receipt = pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "overlay"), None, "/seed")
        self.assertEqual((self.seed, receipt["targets"], receipt["seededFromCache"]), ("/seed", [pc.LINUX], True))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual(json.loads(read(os.path.join(out, pc.PROVENANCE))), receipt)
        self.assertEqual(receipt["files"], sorted(receipt["files"]))
        self.assertIn("x86_64-linux-gnu.2.31.cxx.cfg", receipt["files"])
        self.assertNotIn(pc.PROVENANCE, receipt["files"])
        self.assertEqual(receipt["headers"]["libcxx"]["files"], 1)
        self.assertEqual(receipt["limits"], pc.LIMITS)
        self.assertTrue(any("never run" in l for l in receipt["limits"]))
        self.assertEqual(self.checked, [receipt])

    def test_a_check_that_fails_leaves_neither_the_output_nor_a_partial(self):
        self.refuse = True
        with self.assertRaisesRegex(pe.EngineError, "C\\+\\+ link failed"):
            pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "overlay"))
        self.assertEqual(os.listdir(self.path("out")), [])

    def test_an_existing_output_is_never_replaced(self):
        os.makedirs(self.path("taken"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("taken"))
        self.assertEqual(self.checked, [])

    def test_an_output_claimed_while_checking_is_never_replaced(self):
        def claim(*args):
            os.makedirs(self.path("out", "overlay"))

        with mock.patch.object(pc, "checkOverlay", side_effect=claim):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "overlay"))
        self.assertEqual(os.listdir(self.path("out", "overlay")), [])
        self.assertEqual([n for n in os.listdir(self.path("out")) if ".partial-" in n], [])

    def test_adding_the_overlay_merges_it_into_the_runtime_and_leaves_no_scratch(self):
        receipt = pc.addCppRuntime(self.zig, "/e", self.runtime, [pc.LINUX])
        self.assertEqual(receipt["targets"], [pc.LINUX])
        self.assertEqual(read(os.path.join(self.runtime, "x86_64-linux-gnu.2.31.cxx.cfg")), "x86_64-linux-gnu.2.31.cxx.cfg")
        self.assertTrue(os.path.isfile(os.path.join(self.runtime, pc.PROVENANCE)))
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("cppOverlay-")], [])

    def test_a_zig_that_is_not_executable_is_refused_first(self):
        os.chmod(self.zig, 0o644)
        with self.assertRaisesRegex(pe.EngineError, "not executable"):
            pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out"))


class ProduceTest(TempCase):
    """produceVariant on a fake Zig whose lines are those of a real C++ run."""

    def setUp(self):
        super().setUp()
        self.cache = self.path("cache")
        for name in pc.ARCHIVES[pc.LINUX] + ["crt1.o", "libm.so.6"] + pc.ARCHIVES[pc.WINDOWS] + ["crt2.obj", "zigc.lib"]:
            write(os.path.join(self.cache, name))
        self.fixture = os.path.join(pr.FIXTURES, "runtimeCpp.cpp")

    def zigRun(self, target, compile_, link):
        def run(zig, target_, variant, work, cache):
            return compile_ + "\n" + link + "\n" + '"zig" -cc1 -main-file-name runtimeCpp.cpp -fcxx-exceptions -fexceptions\n', \
                self.path("out"), self.dir
        return mock.patch.object(pc, "runZig", side_effect=run)

    def test_a_linux_run_yields_defines_libc_names_link_tokens_and_the_archives(self):
        isystem = " ".join("-isystem " + d for d in LINUX_CXX)
        compile_ = ("/z/zig clang %s -target x86_64-unknown-linux5.10.0-gnu2.31.0 -fno-PIE -fPIC -DNDEBUG -D__GLIBC_MINOR__=31 "
                    "-D_LIBCPP_ABI_VERSION=1 %s -Xclang -target-cpu -Xclang x86-64") % (self.fixture, isystem)
        link = "ld.lld --entry _start -o %s %s/crt1.o %s/runtimeCpp.o --as-needed %s %s/libm.so.6" % (
            self.path("out"), self.cache, self.cache, " ".join(self.cache + "/" + n for n in pc.ARCHIVES[pc.LINUX]), self.cache)
        with self.zigRun(pc.LINUX, compile_, link):
            found = pc.produceVariant("/z/zig", pc.LINUX, "exe", self.dir, self.cache)
        self.assertEqual(found["defines"], ["-D_LIBCPP_ABI_VERSION=1"])
        self.assertEqual(found["definesInBase"], ["-D__GLIBC_MINOR__=31"])
        self.assertEqual(found["libc"], ["x86-linux-gnu", "generic-glibc", "any-linux-any"])
        self.assertEqual(found["tokens"], ["--entry", "_start", "crt1.o", "--as-needed", "libm.so.6"])
        self.assertEqual([os.path.basename(p) for p in found["archives"]], pc.ARCHIVES[pc.LINUX])
        self.assertEqual(found["cc1"], ["-fcxx-exceptions", "-fexceptions"])

    def test_a_linux_run_that_links_another_way_is_refused(self):
        isystem = " ".join("-isystem " + d for d in LINUX_CXX)
        compile_ = "/z/zig clang %s -target x -DNDEBUG -D_LIBCPP_ABI_VERSION=1 %s -Xclang -target-cpu -Xclang x86-64" % (
            self.fixture, isystem)
        link = "ld.lld -o %s %s/crt1.o %s/runtimeCpp.o" % (self.path("out"), self.cache, self.cache)
        with self.zigRun(pc.LINUX, compile_, link):
            with self.assertRaisesRegex(pe.EngineError, "in a row|not hold|do not hold"):
                pc.produceVariant("/z/zig", pc.LINUX, "exe", self.dir, self.cache)


if __name__ == "__main__":
    unittest.main()
