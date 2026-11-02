import contextlib
import inspect
import io
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock

import prepareCppRuntime as pc
import prepareDarwinRuntime as pd
import prepareEngine as pe
import prepareRuntime as pr
from prepareWindowsRuntimeTest import syntheticPe

LINUX_CXX = ("/z/lib/libcxx/include", "/z/lib/libcxxabi/include", "/z/lib/include", "/z/lib/libc/include/x86-linux-gnu",
             "/z/lib/libc/include/generic-glibc", "/z/lib/libc/include/any-linux-any", "/z/lib/libunwind/include")
DEFINES = ["-D_LIBCPP_ABI_VERSION=1", "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS"]
BASE = "\n".join(["-target x", "-D__GLIBC_MINOR__=31", "-isystem <CFGDIR>/include/libc/x86-linux-gnu",
                  "-isystem <CFGDIR>/include/libc/any-linux-any", "-Xlinker -L -Xlinker <CFGDIR>/t",
                  "-Xlinker --entry", "-Xlinker _start", "-Xlinker <CFGDIR>/t/crt1.o", "-Xlinker <CFGDIR>/t/libm.so.6"]) + "\n"
BASE_SO = "\n".join(["-target x", "-D__GLIBC_MINOR__=31", "-isystem <CFGDIR>/include/libc/x86-linux-gnu",
                     "-isystem <CFGDIR>/include/libc/any-linux-any", "-Xlinker -L -Xlinker <CFGDIR>/t", "-Xlinker -shared",
                     "-Xlinker <CFGDIR>/t/libm.so.6"]) + "\n"
SHARED_NM = "0000 T cppSum\n0000 U printf@GLIBC_2.2.5\n"
ARM_NM = "0000 U printf@GLIBC_2.17\n"
LINUX_ARM_CXX = ("/z/lib/libcxx/include", "/z/lib/libcxxabi/include", "/z/lib/include", "/z/lib/libc/include/aarch64-linux-gnu",
                 "/z/lib/libc/include/generic-glibc", "/z/lib/libc/include/any-linux-any", "/z/lib/libunwind/include")
ARM_LIBC = ["aarch64-linux-gnu", "generic-glibc", "any-linux-any"]
ARM_LOADER = "/lib/ld-linux-aarch64.so.1"
BASE_ARM = "\n".join(["-target aarch64", "-D__GLIBC_MINOR__=31", "-isystem <CFGDIR>/include/libc/aarch64-linux-gnu",
                      "-isystem <CFGDIR>/include/libc/any-linux-any", "-Xlinker -L -Xlinker <CFGDIR>/t",
                      "-Xlinker --dynamic-linker", "-Xlinker " + ARM_LOADER, "-Xlinker <CFGDIR>/t/crt1.o",
                      "-Xlinker <CFGDIR>/t/libm.so.6"]) + "\n"
BASE_ARM_SO = "\n".join(["-target aarch64", "-D__GLIBC_MINOR__=31", "-isystem <CFGDIR>/include/libc/aarch64-linux-gnu",
                         "-isystem <CFGDIR>/include/libc/any-linux-any", "-Xlinker -L -Xlinker <CFGDIR>/t", "-Xlinker -shared",
                         "-Xlinker <CFGDIR>/t/libm.so.6"]) + "\n"


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

    def test_the_linux_shared_config_is_the_executables_text_at_its_own_path_beside_the_shared_c_base(self):
        self.assertEqual(pc.renderConfig(pc.LINUX, "so", DEFINES), pc.renderConfig(pc.LINUX, "exe", DEFINES))
        spec = pc.VARIANTS[(pc.LINUX, "so")]
        self.assertEqual((spec["config"], spec["base"]), ("x86_64-linux-gnu.2.31.so.cxx.cfg", "x86_64-linux-gnu.2.31.so.cfg"))
        self.assertEqual(spec["config"], spec["base"][:-len(".cfg")] + ".cxx.cfg")
        self.assertEqual(spec["base"], pr.sharedDirectory(pc.LINUX) + ".cfg")
        self.assertEqual(spec["c"], pr.SHARED_TARGETS[pc.LINUX]["fixture"])
        self.assertEqual(spec["zigArgs"], ["-shared"])
        for name in (spec["fixture"], spec["c"]):
            self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, name)), name)

    def test_the_linux_shared_fixture_exports_its_c_abi_over_a_vector_a_destructor_and_a_caught_throw(self):
        text = read(os.path.join(pr.FIXTURES, pc.VARIANTS[(pc.LINUX, "so")]["fixture"]))
        for needle in ('extern "C"', "cppSum", "cppDestroyed", "std::vector", "~Guard", "throw ", "catch (", "std::printf"):
            self.assertIn(needle, text)

    def test_each_gnu_linux_target_has_its_own_directory_archives_and_config_pair_over_its_own_c_base(self):
        self.assertEqual((pc.LINUX_ARM, pc.LINUX_TARGETS), ("aarch64-linux-gnu.2.31", (pc.LINUX, pc.LINUX_ARM)))
        self.assertEqual(pc.TARGETS, [pc.LINUX, pc.LINUX_ARM, pc.WINDOWS, pc.MACOS_ARM, pc.MACOS])
        self.assertEqual({key for key in pc.VARIANTS if key[0] in pc.LINUX_TARGETS},
                         {(target, kind) for target in pc.LINUX_TARGETS for kind in ("exe", "so")})
        for target in pc.LINUX_TARGETS:
            exe, so = pc.VARIANTS[(target, "exe")], pc.VARIANTS[(target, "so")]
            self.assertEqual((exe["base"], exe["config"], exe["c"], exe.get("optional")),
                             (target + ".cfg", target + ".cxx.cfg", pr.TARGETS[target]["fixture"], None))
            self.assertEqual((so["base"], so["config"], so["c"], so["optional"]),
                             (pr.sharedDirectory(target) + ".cfg", target + ".so.cxx.cfg", pr.SHARED_TARGETS[target]["fixture"], True))
            self.assertEqual(pc.DIRECTORIES[target], target + ".cxx")
            self.assertEqual(pc.ARCHIVES[target], ["libc++abi.a", "libc++.a", "libunwind.a"])
            text = pc.renderConfig(target, "exe", DEFINES)
            self.assertEqual(pc.renderConfig(target, "so", DEFINES), text)
            self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/%s.cxx\n" % target, text)
        self.assertNotEqual(pc.renderConfig(pc.LINUX_ARM, "exe", DEFINES), pc.renderConfig(pc.LINUX, "exe", DEFINES))

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

    def test_a_shared_base_config_agrees_with_a_shared_link_and_refuses_executable_startup(self):
        pc.crossCheck(variant(variant="so", linkTokens=["-shared", "libm.so.6"]), BASE_SO)
        with self.assertRaisesRegex(pe.EngineError, "link tokens"):
            pc.crossCheck(variant(variant="so", linkTokens=["--entry", "_start", "libm.so.6"]), BASE_SO)

    def test_the_arm_base_configs_agree_with_zigs_arm_lines_and_refuse_the_x64_libc_directory_and_loader(self):
        arm = {"target": pc.LINUX_ARM, "libcDirectories": ARM_LIBC,
               "linkTokens": ["--dynamic-linker", ARM_LOADER, "crt1.o", "libm.so.6"]}
        pc.crossCheck(variant(**arm), BASE_ARM)
        pc.crossCheck(variant(**dict(arm, variant="so", linkTokens=["-shared", "libm.so.6"])), BASE_ARM_SO)
        with self.assertRaisesRegex(pe.EngineError, "libc directories"):
            pc.crossCheck(variant(**dict(arm, libcDirectories=["x86-linux-gnu", "generic-glibc", "any-linux-any"])), BASE_ARM)
        with self.assertRaisesRegex(pe.EngineError, "libc directories"):
            pc.crossCheck(variant(), BASE_ARM)
        with self.assertRaisesRegex(pe.EngineError, "link tokens"):
            pc.crossCheck(variant(**dict(arm, linkTokens=["--dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "crt1.o", "libm.so.6"])),
                          BASE_ARM)
        with self.assertRaisesRegex(pe.EngineError, "link tokens"):
            pc.crossCheck(variant(**dict(arm, variant="so", linkTokens=["--dynamic-linker", ARM_LOADER, "libm.so.6"])), BASE_ARM_SO)

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

    def test_arm_linux_archives_go_to_their_own_directory_and_are_normalized_only_while_their_symbols_stay(self):
        archive = self.path("cache", "libc++.a")
        write(archive)
        with mock.patch.object(pr, "copyInputs", return_value=[{"name": "libc++.a"}]) as copy, \
                mock.patch.object(pc, "archiveSymbols", side_effect=[[("T", "a")], [("T", "a")]]) as symbols:
            self.assertEqual(pc.copyArchives("/e", pc.LINUX_ARM, [archive], self.path("out")), [{"name": "libc++.a"}])
        self.assertEqual(copy.call_args[0][2], "aarch64-linux-gnu.2.31.cxx")
        self.assertEqual(symbols.call_count, 2)
        with mock.patch.object(pr, "copyInputs", return_value=[{"name": "libc++.a"}]), \
                mock.patch.object(pc, "archiveSymbols", side_effect=[[("T", "a")], [("T", "b")]]):
            with self.assertRaisesRegex(pe.EngineError, "changed its symbols"):
                pc.copyArchives("/e", pc.LINUX_ARM, [archive], self.path("out"))

    def test_the_arm_linux_target_follows_its_own_base_configs_and_never_the_x64_ones(self):
        write(self.path("rt", "aarch64-linux-gnu.2.31.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX_ARM])
        self.assertEqual(pc.selectVariants(self.path("rt"), [pc.LINUX_ARM]), [(pc.LINUX_ARM, "exe")])
        write(self.path("rt", "aarch64-linux-gnu.2.31.so.cfg"))
        self.assertEqual(pc.selectVariants(self.path("rt"), [pc.LINUX_ARM]), [(pc.LINUX_ARM, "exe"), (pc.LINUX_ARM, "so")])
        write(self.path("rt", "x86_64-linux-gnu.2.31.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX, pc.LINUX_ARM])
        self.assertEqual(pc.selectVariants(self.path("rt"), [pc.LINUX, pc.LINUX_ARM]),
                         [(pc.LINUX, "exe"), (pc.LINUX_ARM, "exe"), (pc.LINUX_ARM, "so")])
        os.remove(self.path("rt", "aarch64-linux-gnu.2.31.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX])
        with self.assertRaisesRegex(pe.EngineError, "aarch64-linux-gnu.2.31 has no base config"):
            pc.selectTargets(self.path("rt"), [pc.LINUX_ARM])

    def test_a_seed_cache_is_copied_and_the_shared_zig_cache_is_never_one(self):
        write(self.path("seed", "o", "entry"), "cached")
        pc.seedCache(self.path("seed"), self.path("work", "global"))
        self.assertEqual(read(self.path("work", "global", "o", "entry")), "cached")
        shared = os.path.expanduser("~/.cache/zig")
        for refused in (shared, os.path.join(shared, "o"), self.path("missing")):
            with self.assertRaisesRegex(pe.EngineError, "not a private cache"):
                pc.seedCache(refused, self.path("work2"))

    def test_the_linux_shared_variant_follows_its_base_config_and_needs_the_executables(self):
        write(self.path("rt", "x86_64-linux-gnu.2.31.cfg"))
        self.assertEqual(pc.selectVariants(self.path("rt"), [pc.LINUX]), [(pc.LINUX, "exe")])
        write(self.path("rt", "x86_64-linux-gnu.2.31.so.cfg"))
        self.assertEqual(pc.selectVariants(self.path("rt"), [pc.LINUX]), [(pc.LINUX, "exe"), (pc.LINUX, "so")])
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX])
        os.remove(self.path("rt", "x86_64-linux-gnu.2.31.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "no base config"):
            pc.selectTargets(self.path("rt"), [pc.LINUX])

    def test_a_missing_windows_dll_base_stays_refused_while_a_missing_linux_shared_base_is_skipped(self):
        write(self.path("rt", "x86_64-linux-gnu.2.31.cfg"))
        write(self.path("rt", "windows", "x86_64-windows-gnu.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "no base config"):
            pc.selectVariants(self.path("rt"), [pc.LINUX, pc.WINDOWS])

    def test_targets_follow_the_base_configs_the_runtime_has(self):
        write(self.path("rt", "x86_64-linux-gnu.2.31.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX])
        for name in ("x86_64-windows-gnu.cfg", "x86_64-windows-gnu.dll.cfg"):
            write(self.path("rt", "windows", name))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.LINUX, pc.WINDOWS])
        self.assertEqual(pc.selectTargets(self.path("rt"), [pc.WINDOWS]), [pc.WINDOWS])
        for names, message in ((["aarch64-windows-gnu"], "no C\\+\\+ runtime"), ([pc.LINUX, pc.LINUX], "duplicate")):
            with self.assertRaisesRegex(pe.EngineError, message):
                pc.selectTargets(self.path("rt"), names)
        os.remove(self.path("rt", "windows", "x86_64-windows-gnu.dll.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "no base config"):
            pc.selectTargets(self.path("rt"), [pc.WINDOWS])


def syntheticElf(path, needed=("libc.so.6", "libm.so.6"), ehFrame=True, kind=None, interp=False, machine=62):
    """An ELF64 whose one PT_LOAD maps file offset 0x200 at address 0x1000, holding a dynamic section and its strings.
    A `kind` (e_type) makes it a little-endian file of that type and `machine`; `interp` adds a PT_INTERP header, naming
    the loader when it is a string."""
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
    loader = interp.encode() + b"\0" if isinstance(interp, str) else b""
    if interp:
        headers.append(struct.pack("<IIQQQQQQ", 3, 4, 0x200 + len(body) if loader else 0x200, 0, 0, len(loader), 0, 0))
    head = bytearray(0x200)
    head[:4] = b"\x7fELF"
    if kind is not None:
        head[4:6] = bytes([2, 1])
        struct.pack_into("<HH", head, 16, kind, machine)
    struct.pack_into("<Q", head, 32, 64)
    struct.pack_into("<HH", head, 54, 56, len(headers))
    head[64:64 + 56 * len(headers)] = b"".join(headers)
    with open(path, "wb") as f:
        f.write(bytes(head) + body + loader)


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

    def sharedProblem(self, nm=SHARED_NM, **kwargs):
        syntheticElf(self.path("so"), **dict({"kind": 3}, **kwargs))
        with mock.patch.object(pe, "run", return_value=nm):
            return pc.elfCppProblem(self.path("so"), "nm", "so")

    def test_a_shared_object_that_exports_cppSum_on_glibc_with_an_unwind_header_and_no_interpreter_passes(self):
        self.assertIsNone(self.sharedProblem())

    def test_an_executable_a_pie_a_missing_export_a_foreign_dependency_or_no_unwind_header_is_no_shared_cpp_object(self):
        cases = [({"kind": 2}, SHARED_NM, "not a shared object"), ({"kind": 3, "interp": True}, SHARED_NM, "has an interpreter"),
                 ({}, "0000 U printf@GLIBC_2.2.5\n", "does not export cppSum"),
                 ({"needed": ("libc.so.6", "libstdc++.so.6")}, SHARED_NM, "not glibc's"),
                 ({"ehFrame": False}, SHARED_NM, "PT_GNU_EH_FRAME")]
        for kwargs, nm, message in cases:
            self.assertRegex(self.sharedProblem(nm, **kwargs), message)

    def test_a_shared_object_is_no_linux_executable(self):
        syntheticElf(self.path("so"), kind=3)
        with mock.patch.object(pe, "run", return_value=SHARED_NM):
            self.assertRegex(pc.elfCppProblem(self.path("so"), "nm"), "interpreter is")

    def test_the_inspection_of_a_linux_file_follows_its_variant(self):
        inspect = pc.inspectBinary("nm")
        for kind in ("exe", "so"):
            with mock.patch.object(pc, "elfCppProblem", return_value=kind) as elf:
                self.assertEqual(inspect("f", {"target": pc.LINUX, "variant": kind}), kind)
            elf.assert_called_once_with("f", "nm", kind, pc.LINUX)

    def linuxProblem(self, target, variantName, nm=SHARED_NM, **kwargs):
        syntheticElf(self.path("f"), **kwargs)
        with mock.patch.object(pe, "run", return_value=nm):
            return pc.elfCppProblem(self.path("f"), "nm", variantName, target)

    def test_a_linux_file_is_checked_against_the_machine_and_dependencies_of_its_own_target(self):
        arm = {"machine": 183, "needed": ("libc.so.6", "ld-linux-aarch64.so.1")}
        x64 = {"machine": 62, "needed": ("libc.so.6", "ld-linux-x86-64.so.2")}
        for target, own, other in ((pc.LINUX_ARM, arm, x64), (pc.LINUX, x64, arm)):
            self.assertIsNone(self.linuxProblem(target, "so", kind=3, **own))
            self.assertRegex(self.linuxProblem(target, "so", kind=3, **dict(other, needed=own["needed"])), "not an \\w+ ELF64 file")
            self.assertRegex(self.linuxProblem(target, "so", kind=3, **dict(own, needed=other["needed"])), "not glibc's")

    def test_an_arm_executable_names_the_arm_loader_and_the_x64_loader_a_missing_loader_or_a_pie_is_refused(self):
        own = {"kind": 2, "machine": 183, "needed": ("libc.so.6", "ld-linux-aarch64.so.1")}
        self.assertIsNone(self.linuxProblem(pc.LINUX_ARM, "exe", ARM_NM, interp=ARM_LOADER, **own))
        for interp in ("/lib64/ld-linux-x86-64.so.2", False):
            self.assertRegex(self.linuxProblem(pc.LINUX_ARM, "exe", ARM_NM, interp=interp, **own), "interpreter is")
        self.assertRegex(self.linuxProblem(pc.LINUX_ARM, "exe", ARM_NM, interp=ARM_LOADER, **dict(own, machine=62)),
                         "not an aarch64 ELF64 file")
        self.assertRegex(self.linuxProblem(pc.LINUX, "exe", ARM_NM, interp=ARM_LOADER, **own), "not an x86_64 ELF64 file")

    def test_an_arm_shared_object_has_no_interpreter_and_exports_cppSum(self):
        own = {"kind": 3, "machine": 183, "needed": ("libc.so.6", "ld-linux-aarch64.so.1")}
        self.assertIsNone(self.linuxProblem(pc.LINUX_ARM, "so", **own))
        self.assertRegex(self.linuxProblem(pc.LINUX_ARM, "so", interp=ARM_LOADER, **own), "has an interpreter")
        self.assertRegex(self.linuxProblem(pc.LINUX_ARM, "so", ARM_NM, **own), "does not export cppSum")
        self.assertRegex(self.linuxProblem(pc.LINUX_ARM, "so", **dict(own, kind=2)), "not a shared object")

    def test_a_windows_file_is_no_linux_file_of_either_cpu(self):
        syntheticPe(self.path("w.exe"), exports=())
        for target in pc.LINUX_TARGETS:
            for kind in ("exe", "so"):
                self.assertRegex(pc.elfCppProblem(self.path("w.exe"), "nm", kind, target), "not an \\w+ ELF64 file")

    def test_the_allowed_dependencies_name_each_targets_own_loader_and_the_x64_set_keeps_its_name(self):
        for target, other in ((pc.LINUX, pc.LINUX_ARM), (pc.LINUX_ARM, pc.LINUX)):
            own, foreign = (os.path.basename(pr.ELF_TARGETS[t]["interpreter"]) for t in (target, other))
            self.assertIn(own, pc.ELF_NEEDED_BY_TARGET[target])
            self.assertNotIn(foreign, pc.ELF_NEEDED_BY_TARGET[target])
            self.assertLessEqual(pc.GLIBC_NEEDED, pc.ELF_NEEDED_BY_TARGET[target])
        self.assertEqual(pc.ELF_NEEDED, pc.ELF_NEEDED_BY_TARGET[pc.LINUX])
        self.assertIn("ld-linux-x86-64.so.2", pc.ELF_NEEDED)

    def test_the_inspection_of_an_arm_linux_file_names_its_target_and_a_windows_file_never_reaches_the_elf_check(self):
        inspect = pc.inspectBinary("nm")
        for kind in ("exe", "so"):
            with mock.patch.object(pc, "elfCppProblem", return_value=kind) as elf:
                self.assertEqual(inspect("f", {"target": pc.LINUX_ARM, "variant": kind}), kind)
            elf.assert_called_once_with("f", "nm", kind, pc.LINUX_ARM)
        with mock.patch.object(pc, "peCppProblem", return_value="pe"), mock.patch.object(pc, "elfCppProblem") as elf:
            self.assertEqual(inspect("f", {"target": pc.WINDOWS, "variant": "dll"}), "pe")
        elf.assert_not_called()

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


    def test_the_shared_control_reads_the_shared_base_config_and_the_shared_c_fixture_alone(self):
        listing = "#include <...> search starts here:\n %s/runtime/include/libc/a\nEnd of search list.\n"
        for root in ("merged", "control"):
            write(self.path(root, "runtime", "x86_64-linux-gnu.2.31.so.cfg"))
        seen = []

        def run(command):
            root = next(r for r in ("merged", "control") if self.path(r) in " ".join(command))
            seen.append(command)
            if "-o" in command:
                with open(command[command.index("-o") + 1], "wb") as f:
                    f.write(b"so")
            return mock.Mock(returncode=0, stdout="", stderr=listing % self.path(root) if "-E" in command else "")

        pc.checkControl(run, self.path("merged", "runtime"), self.path("control", "runtime"), self.dir, variant(variant="so"))
        self.assertEqual(len(seen), 6)
        for command in seen:
            configs = [c for c in command if c.startswith("--config=")]
            self.assertEqual([os.path.basename(c) for c in configs], ["x86_64-linux-gnu.2.31.so.cfg"])
        self.assertEqual({os.path.basename(c) for command in seen for c in command if c.endswith(".c")}, {"runtimeLinuxShared.c"})

    def test_the_arm_controls_read_the_arm_base_configs_and_c_fixtures_and_never_a_cpp_file(self):
        listing = "#include <...> search starts here:\n %s/runtime/include/libc/a\nEnd of search list.\n"
        for kind, base, fixture in (("exe", "aarch64-linux-gnu.2.31.cfg", "runtimeLinux.c"),
                                    ("so", "aarch64-linux-gnu.2.31.so.cfg", "runtimeLinuxShared.c")):
            for root in ("merged", "control"):
                write(self.path(root, "runtime", base))
            seen = []

            def run(command):
                root = next(r for r in ("merged", "control") if self.path(r) in " ".join(command))
                seen.append(command)
                if "-o" in command:
                    with open(command[command.index("-o") + 1], "wb") as f:
                        f.write(b"same")
                return mock.Mock(returncode=0, stdout="", stderr=listing % self.path(root) if "-E" in command else "")

            pc.checkControl(run, self.path("merged", "runtime"), self.path("control", "runtime"), self.path("work", kind),
                            variant(target=pc.LINUX_ARM, variant=kind))
            self.assertEqual(len(seen), 6)
            for command in seen:
                self.assertEqual(os.path.basename(command[0]), "clang")
                self.assertEqual([os.path.basename(c) for c in command if c.startswith("--config=")], ["--config=" + base])
                self.assertFalse([c for c in command if ".cxx" in c or "c++" in c], command)
            self.assertEqual({os.path.basename(c) for command in seen for c in command if c.endswith(".c")}, {fixture})


class PairTest(TempCase):
    """checkVariant with the engine mocked: which configs each C++ and C command names."""

    def check(self, target, kind, libc):
        merged, root = self.path("tree", "runtime"), self.path("tree")
        names = ["cxx/libcxx", "cxx/libcxxabi"] + ["libc/" + d for d in libc] + ["cxx/libunwind"]
        listing = "#include <...> search starts here:\n%sEnd of search list.\n" % "".join(
            " %s/runtime/include/%s\n" % (root, n) for n in names)
        flags = ' "clang" "-cc1" "-triple" "x" "-fcxx-exceptions" "-fexceptions"\n'
        commands = []

        def run(command):
            commands.append(command)
            stderr = listing if "-E" in command else flags if "-###" in command else ""
            return mock.Mock(returncode=0, stdout="", stderr=stderr)

        spec = pc.VARIANTS[(target, kind)]
        found = dict(variant(target=target, variant=kind), zigCc1Flags=["-fcxx-exceptions", "-fexceptions"])
        outputs = pc.checkVariant(run, merged, self.dir, found, lambda binary, v: None)
        return spec, merged, commands, outputs

    def test_every_cpp_command_names_the_targets_cxx_config_then_its_base_and_every_c_command_the_base_alone(self):
        for target, libc in ((pc.LINUX, ["x86-linux-gnu", "any-linux-any"]), (pc.LINUX_ARM, ["aarch64-linux-gnu", "any-linux-any"])):
            for kind, count, suffix in (("exe", 10, ".out"), ("so", 5, ".so")):
                self.setUp()
                spec, merged, commands, outputs = self.check(target, kind, libc)
                pair = [os.path.join(merged, spec["config"]), os.path.join(merged, spec["base"])]
                self.assertEqual(len(commands), count, msg=(target, kind))
                for command in commands:
                    configs = [c[len("--config="):] for c in command if c.startswith("--config=")]
                    tool = os.path.basename(command[0])
                    expected = [] if tool == "llvm-ar" else pair[1:] if tool == "clang" and "-c" in command else pair
                    self.assertEqual(configs, expected, msg=(target, kind, command))
                    self.assertEqual("--no-default-config" in command, bool(expected))
                self.assertEqual({os.path.splitext(p)[1] for p in outputs.values()}, {suffix})
                self.assertTrue(all("cpp-%s-%s" % (target, kind) in p for p in outputs.values()))


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

    def produce(self, zig, engine, targets, work, output, seed, variants):
        self.variants = variants
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

    def test_the_variants_produced_are_those_whose_base_config_the_runtime_holds(self):
        pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "a"))
        self.assertEqual(self.variants, [(pc.LINUX, "exe")])
        write(os.path.join(self.runtime, "x86_64-linux-gnu.2.31.so.cfg"))
        pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "b"))
        self.assertEqual(self.variants, [(pc.LINUX, "exe"), (pc.LINUX, "so")])

    def test_the_arm_linux_variants_are_produced_with_the_x64_ones_when_the_runtime_holds_their_base_configs(self):
        for name in ("aarch64-linux-gnu.2.31.cfg", "aarch64-linux-gnu.2.31.so.cfg"):
            write(os.path.join(self.runtime, name))
        _, receipt = pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "a"))
        self.assertEqual(receipt["targets"], [pc.LINUX, pc.LINUX_ARM])
        self.assertEqual(self.variants, [(pc.LINUX, "exe"), (pc.LINUX_ARM, "exe"), (pc.LINUX_ARM, "so")])
        _, receipt = pc.prepareCppRuntime(self.zig, "/e", self.runtime, self.path("out", "b"), [pc.LINUX_ARM])
        self.assertEqual(receipt["targets"], [pc.LINUX_ARM])
        self.assertEqual(self.variants, [(pc.LINUX_ARM, "exe"), (pc.LINUX_ARM, "so")])

    def test_the_limits_say_the_arm_linux_files_are_never_run(self):
        self.assertTrue(any("aarch64-linux-gnu.2.31" in l and "never run" in l for l in pc.LIMITS))

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


class ProduceOverlayTest(TempCase):
    """produce() with the Zig runs mocked: what the Linux executable and shared variants share and what each gets."""

    def facts(self, directory):
        for name in pc.ARCHIVES[pc.LINUX]:
            write(self.path("archives", directory, name), directory + name)
        return {"zigLib": self.path("zig", "lib"), "libc": ["x86-linux-gnu"], "tokens": [], "definesInBase": [],
                "archives": [self.path("archives", directory, n) for n in pc.ARCHIVES[pc.LINUX]],
                "defines": ["-D_LIBCPP_ABI_VERSION=1"], "cc1": ["-fcxx-exceptions"]}

    def produce(self, sharedDirectory):
        for relative in pc.HEADERS.values():
            write(self.path("zig", "lib", relative, "header"))
        found = {(pc.LINUX, "exe"): self.facts("exe"), (pc.LINUX, "so"): self.facts(sharedDirectory)}
        names = [{"name": n} for n in pc.ARCHIVES[pc.LINUX]]
        with mock.patch.object(pc, "produceVariant", side_effect=lambda zig, target, variant, work, cache: found[(target, variant)]), \
                mock.patch.object(pc, "copyArchives", return_value=names), mock.patch.object(pc, "linkAliases", return_value=[]), \
                mock.patch.object(pr, "copyNotices", return_value=[]):
            return pc.produce("zig", "/e", [pc.LINUX], self.path("work"), self.path("out"), None, list(found))

    def test_the_shared_variant_gets_its_own_config_over_the_archives_it_shares_with_the_executable(self):
        variants, archives, _ = self.produce("exe")
        self.assertEqual([(v["variant"], v["config"], v["base"]) for v in variants], [
            ("exe", "x86_64-linux-gnu.2.31.cxx.cfg", "x86_64-linux-gnu.2.31.cfg"),
            ("so", "x86_64-linux-gnu.2.31.so.cxx.cfg", "x86_64-linux-gnu.2.31.so.cfg")])
        self.assertEqual(list(archives), [pc.LINUX])
        self.assertEqual(read(self.path("out", "x86_64-linux-gnu.2.31.so.cxx.cfg")),
                         read(self.path("out", "x86_64-linux-gnu.2.31.cxx.cfg")))

    def produceArm(self, armSharedDirectory):
        for relative in pc.HEADERS.values():
            write(self.path("zig", "lib", relative, "header"))
        found = {(pc.LINUX, "exe"): self.facts("exe"), (pc.LINUX_ARM, "exe"): self.facts("armExe"),
                 (pc.LINUX_ARM, "so"): self.facts(armSharedDirectory)}
        copied = []

        def copy(engine, target, paths, output):
            copied.append((target, [os.path.dirname(p) for p in paths]))
            return [{"name": n} for n in pc.ARCHIVES[target]]

        with mock.patch.object(pc, "produceVariant", side_effect=lambda zig, target, variant, work, cache: found[(target, variant)]), \
                mock.patch.object(pc, "copyArchives", side_effect=copy), mock.patch.object(pc, "linkAliases", return_value=[]), \
                mock.patch.object(pr, "copyNotices", return_value=[]):
            produced = pc.produce("zig", "/e", [pc.LINUX, pc.LINUX_ARM], self.path("work"), self.path("out"), None, list(found))
        return produced, copied

    def test_each_cpu_gets_its_own_archives_and_configs_and_only_the_cpus_own_exe_and_so_must_match(self):
        (variants, archives, _), copied = self.produceArm("armExe")
        self.assertEqual(list(archives), [pc.LINUX, pc.LINUX_ARM])
        self.assertEqual(copied, [(pc.LINUX, [self.path("archives", "exe")] * 3), (pc.LINUX_ARM, [self.path("archives", "armExe")] * 3)])
        self.assertEqual(archives[pc.LINUX_ARM]["directory"], "aarch64-linux-gnu.2.31.cxx")
        self.assertEqual([(v["target"], v["variant"], v["config"], v["base"]) for v in variants], [
            (pc.LINUX, "exe", "x86_64-linux-gnu.2.31.cxx.cfg", "x86_64-linux-gnu.2.31.cfg"),
            (pc.LINUX_ARM, "exe", "aarch64-linux-gnu.2.31.cxx.cfg", "aarch64-linux-gnu.2.31.cfg"),
            (pc.LINUX_ARM, "so", "aarch64-linux-gnu.2.31.so.cxx.cfg", "aarch64-linux-gnu.2.31.so.cfg")])
        for name in ("aarch64-linux-gnu.2.31.cxx.cfg", "aarch64-linux-gnu.2.31.so.cxx.cfg"):
            self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/aarch64-linux-gnu.2.31.cxx\n", read(self.path("out", name)))

    def test_an_arm_shared_link_that_names_other_archives_than_the_arm_executable_is_refused_though_the_x64_pair_matches(self):
        with self.assertRaisesRegex(pe.EngineError, "aarch64-linux-gnu.2.31 so links other C.. archives than the executable"):
            self.produceArm("armSo")

    def test_a_shared_link_that_names_other_archives_than_the_executable_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "links other C.. archives than the executable"):
            self.produce("so")


class ProduceTest(TempCase):
    """produceVariant on a fake Zig whose lines are those of a real C++ run."""

    def setUp(self):
        super().setUp()
        self.cache = self.path("cache")
        for name in pc.ARCHIVES[pc.LINUX] + ["crt1.o", "libm.so.6"] + pc.ARCHIVES[pc.WINDOWS] + ["crt2.obj", "zigc.lib"]:
            write(os.path.join(self.cache, name))
        self.fixture = os.path.join(pr.FIXTURES, "runtimeCpp.cpp")
        self.sharedFixture = os.path.join(pr.FIXTURES, "runtimeCppShared.cpp")

    def zigRun(self, target, compile_, link, source="runtimeCpp.cpp"):
        def run(zig, target_, variant, work, cache):
            return compile_ + "\n" + link + "\n" + '"zig" -cc1 -main-file-name %s -fcxx-exceptions -fexceptions\n' % source, \
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

    def sharedLines(self, flags="-shared"):
        isystem = " ".join("-isystem " + d for d in LINUX_CXX)
        compile_ = ("/z/zig clang %s -target x86_64-unknown-linux5.10.0-gnu2.31.0 -fPIC -DNDEBUG -D__GLIBC_MINOR__=31 "
                    "-D_LIBCPP_ABI_VERSION=1 %s -Xclang -target-cpu -Xclang x86-64") % (self.sharedFixture, isystem)
        link = "ld.lld %s -o %s %s/runtimeCppShared.o --as-needed %s %s/libm.so.6" % (
            flags, self.path("out"), self.cache, " ".join(self.cache + "/" + n for n in pc.ARCHIVES[pc.LINUX]), self.cache)
        return compile_, link

    def test_a_linux_shared_run_yields_a_link_without_executable_startup_and_the_same_archives(self):
        with self.zigRun(pc.LINUX, *self.sharedLines(), source="runtimeCppShared.cpp"):
            found = pc.produceVariant("/z/zig", pc.LINUX, "so", self.dir, self.cache)
        self.assertEqual(found["tokens"], ["-shared", "--as-needed", "libm.so.6"])
        self.assertEqual([os.path.basename(p) for p in found["archives"]], pc.ARCHIVES[pc.LINUX])
        self.assertEqual(found["defines"], ["-D_LIBCPP_ABI_VERSION=1"])
        self.assertEqual(found["cc1"], ["-fcxx-exceptions", "-fexceptions"])

    def test_a_linux_shared_run_with_executable_startup_a_soname_or_no_shared_flag_is_refused(self):
        for flags, message in (("-shared --entry _start", "carries --entry"), ("-shared -pie", "carries -pie"),
                               ("-shared --dynamic-linker /l", "carries --dynamic-linker"), ("", "names -shared 0 times"),
                               ("-shared -shared", "names -shared 2 times")):
            with self.zigRun(pc.LINUX, *self.sharedLines(flags), source="runtimeCppShared.cpp"):
                with self.assertRaisesRegex(pe.EngineError, message):
                    pc.produceVariant("/z/zig", pc.LINUX, "so", self.dir, self.cache)

    def test_an_arm_linux_run_yields_its_libc_names_loader_tokens_and_the_archives(self):
        isystem = " ".join("-isystem " + d for d in LINUX_ARM_CXX)
        compile_ = ("/z/zig clang %s -target aarch64-unknown-linux5.10.0-gnu2.31.0 -fPIC -DNDEBUG -D__GLIBC_MINOR__=31 "
                    "-D_LIBCPP_ABI_VERSION=1 %s -Xclang -target-cpu -Xclang generic") % (self.fixture, isystem)
        link = "ld.lld -m aarch64linux --dynamic-linker %s -o %s %s/crt1.o %s/runtimeCpp.o --as-needed %s %s/libm.so.6" % (
            ARM_LOADER, self.path("out"), self.cache, self.cache, " ".join(self.cache + "/" + n for n in pc.ARCHIVES[pc.LINUX_ARM]),
            self.cache)
        with self.zigRun(pc.LINUX_ARM, compile_, link):
            found = pc.produceVariant("/z/zig", pc.LINUX_ARM, "exe", self.dir, self.cache)
        self.assertEqual(found["libc"], ARM_LIBC)
        self.assertEqual(found["tokens"], ["-m", "aarch64linux", "--dynamic-linker", ARM_LOADER, "crt1.o", "--as-needed", "libm.so.6"])
        self.assertEqual([os.path.basename(p) for p in found["archives"]], pc.ARCHIVES[pc.LINUX_ARM])
        self.assertEqual((found["defines"], found["definesInBase"]), (["-D_LIBCPP_ABI_VERSION=1"], ["-D__GLIBC_MINOR__=31"]))

    def test_an_arm_linux_shared_run_yields_a_link_without_executable_startup_and_the_arm_archives(self):
        isystem = " ".join("-isystem " + d for d in LINUX_ARM_CXX)
        compile_ = ("/z/zig clang %s -target aarch64-unknown-linux5.10.0-gnu2.31.0 -fPIC -DNDEBUG -D_LIBCPP_ABI_VERSION=1 %s "
                    "-Xclang -target-cpu -Xclang generic") % (self.sharedFixture, isystem)
        link = "ld.lld -shared -o %s %s/runtimeCppShared.o --as-needed %s %s/libm.so.6" % (
            self.path("out"), self.cache, " ".join(self.cache + "/" + n for n in pc.ARCHIVES[pc.LINUX_ARM]), self.cache)
        with self.zigRun(pc.LINUX_ARM, compile_, link, source="runtimeCppShared.cpp"):
            found = pc.produceVariant("/z/zig", pc.LINUX_ARM, "so", self.dir, self.cache)
        self.assertEqual(found["tokens"], ["-shared", "--as-needed", "libm.so.6"])
        self.assertEqual(found["libc"], ARM_LIBC)
        with self.zigRun(pc.LINUX_ARM, compile_, link.replace("-shared", "-shared --entry _start"), source="runtimeCppShared.cpp"):
            with self.assertRaisesRegex(pe.EngineError, "carries --entry"):
                pc.produceVariant("/z/zig", pc.LINUX_ARM, "so", self.dir, self.cache)

    def test_zig_is_run_for_the_arm_target_with_a_linux_output_and_the_shared_flag_only_for_the_object(self):
        commands = []

        def fake(command, **kwargs):
            commands.append(command)
            return mock.Mock(returncode=0, stderr="lines")

        for kind, shared in (("exe", False), ("so", True)):
            with mock.patch.object(pc.subprocess, "run", side_effect=fake):
                stderr, output, private = pc.runZig("/z/zig", pc.LINUX_ARM, kind, self.dir, self.cache)
            command = commands[-1]
            self.assertEqual(command[command.index("-target") + 1], pc.LINUX_ARM)
            self.assertEqual("-shared" in command, shared)
            self.assertEqual(os.path.basename(output), "fixture.out")
            self.assertEqual(command[command.index("-o") + 1], output)
            self.assertEqual(private, os.path.join(self.dir, pc.LINUX_ARM, kind))
            self.assertIn("runtimeCppShared.cpp" if shared else "runtimeCpp.cpp", [os.path.basename(c) for c in command])

    def test_a_linux_run_that_links_another_way_is_refused(self):
        isystem = " ".join("-isystem " + d for d in LINUX_CXX)
        compile_ = "/z/zig clang %s -target x -DNDEBUG -D_LIBCPP_ABI_VERSION=1 %s -Xclang -target-cpu -Xclang x86-64" % (
            self.fixture, isystem)
        link = "ld.lld -o %s %s/crt1.o %s/runtimeCpp.o" % (self.path("out"), self.cache, self.cache)
        with self.zigRun(pc.LINUX, compile_, link):
            with self.assertRaisesRegex(pe.EngineError, "in a row|not hold|do not hold"):
                pc.produceVariant("/z/zig", pc.LINUX, "exe", self.dir, self.cache)


class HostTest(TempCase):
    """The Linux shared object run by a C host that links through the executable's C base config and -ldl alone."""
    OUTPUT = "cpp caught=count destroyed=2\nhost ok\n"

    def setUp(self):
        super().setUp()
        self.merged = self.path("tree", "runtime")
        self.commands = []

    def run_(self, returncode=0, stdout=OUTPUT, stderr=""):
        def run(command):
            self.commands.append(command)
            if "-o" in command:
                write(command[command.index("-o") + 1])
            return mock.Mock(returncode=returncode, stdout=stdout if command[0].endswith("host.out") else "", stderr=stderr)
        return run

    def test_the_host_fixture_is_c_that_loads_the_shared_object_and_calls_its_two_exports(self):
        text = read(os.path.join(pr.FIXTURES, pc.HOST_FIXTURE))
        for needle in ("dlopen(argv[1]", 'dlsym(library, "cppSum")', 'dlsym(library, "cppDestroyed")', "dlclose(library)",
                       "sum(3) != 6", "sum(-1) != -1", "destroyed() != 2"):
            self.assertIn(needle, text)
        self.assertNotIn("#include <vector>", text)

    def test_the_host_compiles_and_links_with_the_executables_c_base_config_and_ldl_then_runs_each_shared_object(self):
        pc.checkHost(self.run_(), self.merged, self.dir, [self.path("a.so"), self.path("b.so")])
        self.assertEqual([c[0].rsplit("/", 1)[-1] for c in self.commands], ["clang", "clang", "host.out", "host.out"])
        compileCommand, linkCommand = self.commands[:2]
        self.assertIn("-c", compileCommand)
        self.assertEqual(os.path.basename(next(c for c in compileCommand if c.endswith(".c"))), pc.HOST_FIXTURE)
        self.assertNotIn("-c", linkCommand)
        for command in (compileCommand, linkCommand):
            self.assertEqual([c for c in command if c.startswith("--config=")], ["--config=" + os.path.join(
                self.merged, "x86_64-linux-gnu.2.31.cfg")])
            self.assertIn("--no-default-config", command)
            self.assertFalse([c for c in command if ".cxx" in c or "c++" in c], command)
        self.assertEqual([c for c in linkCommand if c.startswith("-l")], ["-ldl"])
        self.assertFalse([c for c in compileCommand if c.startswith("-l")])
        self.assertEqual([c[1:] for c in self.commands[2:]], [[self.path("a.so")], [self.path("b.so")]])

    def test_a_host_that_exits_nonzero_prints_other_output_or_warns_is_refused(self):
        cases = (({"returncode": 4, "stderr": "host: cppSum: undefined"}, r"C host run failed \(4\) or warned: .*cppSum"),
                 ({"stdout": "host ok\n"}, "C host printed"), ({"stderr": "warning"}, r"C host run failed \(0\) or warned: warning"))
        for index, (kwargs, message) in enumerate(cases):
            with self.assertRaisesRegex(pe.EngineError, message):
                pc.checkHost(self.run_(**kwargs), self.merged, self.path("work%d" % index), [self.path("a.so")])

    def test_a_compile_or_link_failure_stops_before_anything_runs(self):
        run = mock.Mock(return_value=mock.Mock(returncode=1, stdout="", stderr="no dlopen"))
        with self.assertRaisesRegex(pe.EngineError, "C host compile failed"):
            pc.checkHost(run, self.merged, self.dir, [self.path("a.so")])
        self.assertEqual(run.call_count, 1)

    def test_only_a_matching_glibc_linux_host_runs_its_linux_object(self):
        for system, machine, loader, message in (("Windows", "AMD64", True, "Windows"), ("FreeBSD", "amd64", True, "FreeBSD"),
                                                 ("Linux", "ppc64", True, "ppc64"), ("Linux", "x86_64", False, "loader")):
            target, problem = pc.executionTarget(system, machine, loader)
            self.assertIsNone(target)
            self.assertRegex(problem, message)
        self.assertEqual(pc.executionTarget("Linux", "x86_64", True), (pc.LINUX, None))
        for machine in ("aarch64", "arm64"):
            self.assertEqual(pc.executionTarget("Linux", machine, True), (pc.LINUX_ARM, None))
            target, problem = pc.executionTarget("Linux", machine, False)
            self.assertIsNone(target)
            self.assertIn(pr.ELF_TARGETS[pc.LINUX_ARM]["interpreter"], problem)
        with mock.patch.object(pc.os.path, "exists", return_value=True) as exists:
            self.assertEqual(pc.executionTarget("Linux", "aarch64"), (pc.LINUX_ARM, None))
        exists.assert_called_once_with(pr.ELF_TARGETS[pc.LINUX_ARM]["interpreter"])

    def test_an_arm_host_selects_only_its_own_shared_variant_and_links_the_matching_c_host(self):
        receipt = {"variants": [variant(target=t, variant="so") for t in pc.LINUX_TARGETS]}
        selected = pc.executedVariants(receipt, pc.LINUX_ARM)
        self.assertEqual([(v["target"], v["variant"]) for v in selected], [(pc.LINUX_ARM, "so")])
        run = self.run_()
        pc.checkHost(run, self.merged, self.path("arm-host"), [self.path("arm.so")], target=pc.LINUX_ARM)
        for command in self.commands[:2]:
            self.assertIn("--config=" + os.path.join(self.merged, pc.LINUX_ARM + ".cfg"), command)
            self.assertFalse(any(pc.LINUX + ".cfg" in word for word in command))
        self.assertIn("-ldl", self.commands[1])

    def test_a_run_that_outlasts_its_timeout_is_refused_naming_the_target_and_mode(self):
        with mock.patch.object(pc, "RUN_TIMEOUT_SECONDS", 7), mock.patch.object(
                pc.subprocess, "run", side_effect=pc.subprocess.TimeoutExpired("host.out", 7)) as called:
            with self.assertRaisesRegex(pe.EngineError, r"x86_64-linux-gnu.2.31 so: host.out a.so timed out after 7 s"):
                pc.boundedRun(pc.LINUX + " so")(["host.out", "a.so"])
        self.assertEqual(called.call_args.kwargs["timeout"], 7)

    def receipt(self, *variants):
        return {"files": ["x"], "variants": [variant(variant=v) for v in variants]}

    def execute(self, receipt, problem=None):
        outputs = {"plain": self.path("plain.so"), "written": self.path("written.so")}
        calls = mock.Mock()
        with mock.patch.object(pc, "executionTarget", return_value=(None if problem else pc.LINUX, problem)), \
                mock.patch.object(pc, "openProof", return_value=("/e", "/e/runtime", receipt)), \
                mock.patch.object(pc.shutil, "copytree"), mock.patch.object(pc.shutil, "rmtree"), \
                mock.patch.object(pc, "controlTree", return_value="control"), \
                mock.patch.object(pc, "checkControl", calls.control), \
                mock.patch.object(pc, "checkVariant", calls.variant, return_value=outputs), \
                mock.patch.object(pc, "checkHost", calls.host), mock.patch.object(pc.tempfile, "mkdtemp", return_value=self.dir):
            pc.execute("/e", "/e/runtime")
        return calls

    def test_execute_checks_only_the_linux_shared_variant_control_link_and_host_in_that_order(self):
        calls = self.execute(self.receipt("exe", "so"))
        self.assertEqual([c[0] for c in calls.mock_calls], ["control", "variant", "host"])
        self.assertEqual(calls.control.call_args.args[-1]["variant"], "so")
        self.assertEqual(calls.variant.call_args.args[3]["variant"], "so")
        self.assertEqual(calls.host.call_args.args[-1], [self.path("plain.so"), self.path("written.so")])

    def test_execute_refuses_a_host_that_cannot_run_it_and_an_overlay_without_a_shared_variant(self):
        with mock.patch.object(pe, "verifyEngine") as verify, mock.patch.object(pc, "executionTarget", return_value=(None, "host is Windows AMD64")):
            with self.assertRaisesRegex(pe.EngineError, "--execute: host is Windows AMD64"):
                pc.execute("/e", "/e/runtime")
        verify.assert_not_called()
        with self.assertRaisesRegex(pe.EngineError, "no Linux shared-object variant"):
            self.execute(self.receipt("exe"))

    def test_a_failed_native_check_removes_only_its_private_relocated_tree(self):
        work = self.path("execute")
        os.makedirs(work)
        with mock.patch.object(pc, "executionTarget", return_value=(pc.LINUX, None)), \
                mock.patch.object(pc, "openProof", return_value=("/e", "/e/runtime", self.receipt("so"))), \
                mock.patch.object(pc.tempfile, "mkdtemp", return_value=work), \
                mock.patch.object(pc.shutil, "copytree"), \
                mock.patch.object(pc, "controlTree", return_value="control"), \
                mock.patch.object(pc, "checkControl", side_effect=pe.EngineError("control failed")):
            with self.assertRaisesRegex(pe.EngineError, "control failed"):
                pc.execute("/e", "/e/runtime")
        self.assertFalse(os.path.exists(work))
        self.assertTrue(os.path.isdir(self.dir))

    def test_execute_does_not_run_an_arm_shared_object_on_an_x86_64_host(self):
        receipt = {"files": ["x"], "variants": [variant(target=pc.LINUX_ARM, variant="so")]}
        with self.assertRaisesRegex(pe.EngineError, "no Linux shared-object variant"):
            self.execute(receipt)

    def test_execute_says_it_is_execution_only_and_prove_still_says_not_run(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.execute(self.receipt("so"))
        self.assertEqual(out.getvalue().count("run by the C host; execution only; hermetic proof not run"), 2)
        self.assertNotIn("denied", out.getvalue())

    def test_execute_is_its_own_mode_that_refuses_prove_and_the_safeguards_it_would_ignore(self):
        base = ["--execute", "--engine", "/e", "--runtime", "/e/runtime"]
        for extra in (["--prove"], ["--zig", "z"], ["--deny", "/d"], ["--output", "o"], ["--target", pc.LINUX],
                      ["--seed-cache", "c"]):
            with mock.patch.object(pc, "execute") as execute, mock.patch.object(pc, "prove") as prove:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    pc.main(base + extra)
            execute.assert_not_called()
            prove.assert_not_called()
        with mock.patch.object(pc, "execute") as execute, mock.patch.object(pc, "prove") as prove:
            self.assertEqual(pc.main(base), 0)
        execute.assert_called_once_with("/e", "/e/runtime")
        prove.assert_not_called()

    def test_prove_keeps_its_signature_and_never_runs_the_host(self):
        self.assertEqual(list(inspect.signature(pc.prove).parameters), ["engine", "runtime", "denied", "zig"])
        self.assertEqual(list(inspect.signature(pc.checkOverlay).parameters), ["run", "merged", "control", "work", "receipt"])
        with mock.patch.object(pc, "prove") as prove:
            self.assertEqual(pc.main(["--prove", "--engine", "/e", "--runtime", "/e/runtime", "--deny", "/d"]), 0)
        prove.assert_called_once_with("/e", "/e/runtime", ["/d"], None)


MACOS_CXX = ("/z/lib/libcxx/include", "/z/lib/libcxxabi/include", "/z/lib/include", "/z/lib/libc/include/any-darwin-any")
MACOS_FLOOR = {"platformVersion": "11.0.0", "sdkVersion": "11.0.0", "compileMinimum": "11.0.0", "zigOnlyInputs": ["libcompiler_rt.a"]}
MACOS_INCLUDES = ["runtime/include/cxx/libcxx", "runtime/include/cxx/libcxxabi", "lib/clang/22/include",
                  "runtime/darwin/sysroot/usr/include"]


def macosVariant(target=pc.MACOS_ARM, kind="exe", **changes):
    return dict({"target": target, "variant": kind, "base": "darwin/%s.cfg" % target, "libcDirectories": ["any-darwin-any"],
                 "definesInBase": [], "linkTokens": ["-dynamic", "-lSystem"], "macos": dict(MACOS_FLOOR)}, **changes)


def syntheticMachO(path, target=pc.MACOS_ARM, kind="exe", imports=((pd.LC_LOAD_DYLIB, pd.LIBSYSTEM),),
                   sections=pc.MACHO_UNWIND_SECTIONS, segment="__TEXT", installName=pc.DYLIB_INSTALL_NAME, minos=pd.MINOS,
                   signature=None):
    """A 64-bit Mach-O header with the bounded load commands of a linked C++ executable or dylib."""
    spec = pd.TARGETS[target]
    padded = lambda text: text.encode() + b"\0" * (1 + -(len(text) + 1) % 8)
    named = lambda text: struct.pack("<IIII", 24, 2, 0, 0) + padded(text)
    layout = segment.encode().ljust(16, b"\0") + struct.pack("<QQQQiiII", 0, 0, 0, 0, 5, 5, len(sections), 0) + b"".join(
        name.encode().ljust(16, b"\0") + segment.encode().ljust(16, b"\0") + struct.pack("<QQIIIIIIII", *[0] * 10)
        for name in sections)
    commands = [(pc.LC_SEGMENT_64, layout), (pd.LC_BUILD_VERSION, struct.pack("<IIII", pd.PLATFORM_MACOS, minos, minos, 0))]
    if kind == "dylib":
        commands.append((pc.LC_ID_DYLIB, named(installName)))
    else:
        dyld = struct.pack("<I", 12) + pd.DYLINKER.encode() + b"\0"
        dyld += b"\0" * (-(8 + len(dyld)) % 8)
        commands += [(pd.LC_MAIN, struct.pack("<QQ", 0, 0)), (pc.LC_LOAD_DYLINKER, dyld)]
    commands += [(command, named(name)) for command, name in imports]
    if spec["codeSignature"] if signature is None else signature:
        commands.append((pd.LC_CODE_SIGNATURE, struct.pack("<II", 0, 0)))
    body = b"".join(struct.pack("<II", command, 8 + len(payload)) + payload for command, payload in commands)
    with open(path, "wb") as f:
        f.write(struct.pack("<IiiIIIII", pd.MH_MAGIC_64, spec["cpuType"], 0, pc.MH_DYLIB if kind == "dylib" else pd.MH_EXECUTE,
                            len(commands), len(body), 0, 0) + body)


class DarwinConfigTest(unittest.TestCase):
    def test_each_macos_target_pairs_one_config_over_its_one_c_base_for_the_executable_and_the_dylib(self):
        for target in pc.DARWIN_TARGETS:
            exe, dylib = pc.VARIANTS[(target, "exe")], pc.VARIANTS[(target, "dylib")]
            self.assertEqual((exe["base"], exe["config"]), ("darwin/" + pd.configName(target), "darwin/%s.cxx.cfg" % target))
            self.assertEqual((dylib["base"], dylib["config"]), (exe["base"], exe["config"]))
            self.assertEqual((exe["zigArgs"], dylib["zigArgs"], exe["zigLibraries"], dylib["zigLibraries"]), ([], ["-shared"], [], []))
            self.assertEqual((exe["linkFlags"], dylib["linkFlags"]), ([], ["-dynamiclib", "-install_name", pc.DYLIB_INSTALL_NAME]))
            self.assertEqual((exe["c"], dylib["c"]), ("runtimeDarwin.c", "runtimeDarwinDylib.c"))
            self.assertEqual(pc.DIRECTORIES[target], "darwin/%s.cxx" % target)
            self.assertEqual(pc.ARCHIVES[target], ["libc++abi.a", "libc++.a"])
            self.assertEqual((pc.STEMS[target], pc.SPELLINGS[target]), (["c++abi", "c++"], {}))
            for name in (exe["fixture"], exe["c"], dylib["fixture"], dylib["c"]):
                self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, name)), name)
        self.assertEqual(pc.VARIANTS[(pc.MACOS, "dylib")]["fixture"], pc.VARIANTS[(pc.LINUX, "so")]["fixture"])

    def test_the_macos_config_has_no_unwind_include_library_or_alias_and_is_the_same_for_both_variants(self):
        for target in pc.DARWIN_TARGETS:
            text = pc.renderConfig(target, "exe", DEFINES)
            self.assertEqual(text.splitlines(), ["-isystem <CFGDIR>/../include/cxx/libcxx",
                                                 "-isystem <CFGDIR>/../include/cxx/libcxxabi"] + DEFINES + [
                "-Xlinker -L -Xlinker <CFGDIR>/%s.cxx" % target, "$-lc++abi", "$-lc++"])
            self.assertEqual(pc.renderConfig(target, "dylib", DEFINES), text)
        self.assertNotEqual(pc.renderConfig(pc.MACOS_ARM, "exe", DEFINES), pc.renderConfig(pc.MACOS, "exe", DEFINES))

    def test_the_other_targets_keep_three_archives_the_other_spellings_and_the_late_unwind_include(self):
        for target in (pc.LINUX, pc.LINUX_ARM, pc.WINDOWS):
            self.assertEqual((pc.STEMS[target], pc.SPELLINGS[target], len(pc.ARCHIVES[target])),
                             (pc.LIBRARY_STEMS, pc.OTHER_SPELLINGS, 3))
            text = pc.renderConfig(target, "exe", DEFINES)
            self.assertIn("-stdlib++-isystem ", text)
            self.assertTrue(text.endswith("$-lc++abi\n$-lc++\n$-lunwind\n"))

    def test_zig_is_asked_for_the_macos_floor_of_the_c_base_config_and_other_targets_keep_their_spelling(self):
        self.assertEqual(pd.MINIMUM_VERSION, "11.0")
        self.assertEqual((pc.zigTarget(pc.MACOS_ARM), pc.zigTarget(pc.MACOS)), ("aarch64-macos.11.0", "x86_64-macos.11.0"))
        for target in (pc.LINUX, pc.LINUX_ARM, pc.WINDOWS):
            self.assertEqual(pc.zigTarget(target), target)
        self.assertEqual(pc.versionOf("11.0"), pc.versionOf("11.0.0"))
        with self.assertRaisesRegex(pe.EngineError, "not dotted numbers"):
            pc.versionOf("11.x")

    def test_the_macos_fixtures_are_the_c_base_proof_a_c_dylib_and_a_cpp_program_without_the_unwind_header(self):
        self.assertEqual(read(os.path.join(pr.FIXTURES, "runtimeDarwin.c")), pd.FIXTURE)
        self.assertIn("addNumbers", read(os.path.join(pr.FIXTURES, "runtimeDarwinDylib.c")))
        text = read(os.path.join(pr.FIXTURES, "runtimeCppDarwin.cpp"))
        self.assertNotIn("libunwind", text)
        for needle in ("std::thread", "throw ", "catch (", "std::vector"):
            self.assertIn(needle, text)
        self.assertIn("libunwind.h", read(os.path.join(pr.FIXTURES, "runtimeCpp.cpp")))


class DarwinCrossCheckTest(unittest.TestCase):
    def test_the_real_macos_base_configs_agree_with_zigs_lines_for_both_variants(self):
        for target in pc.DARWIN_TARGETS:
            for kind in ("exe", "dylib"):
                pc.crossCheck(macosVariant(target, kind), pd.renderDarwinConfig(target))

    def test_the_link_tokens_of_zigs_own_linker_are_not_compared_with_the_base_config(self):
        pc.crossCheck(macosVariant(linkTokens=["-dynamic", "--not-in-the-base"]), pd.renderDarwinConfig(pc.MACOS_ARM))

    def test_a_floor_a_triple_an_sysroot_a_linker_or_a_define_the_base_config_lacks_is_refused(self):
        base = pd.renderDarwinConfig(pc.MACOS_ARM)
        for found, text, message in (
                (macosVariant(macos=dict(MACOS_FLOOR, platformVersion="13.0.0")), base, "is not 11.0"),
                (macosVariant(macos=dict(MACOS_FLOOR, compileMinimum="13.0")), base, "is not 11.0"),
                (macosVariant(), base.replace("macos11.0", "macos13.0"), "has no --target=aarch64-apple-macos11.0"),
                (macosVariant(pc.MACOS), base, "has no --target=x86_64-apple-macos11.0"),
                (macosVariant(libcDirectories=["any-linux-any"]), base, "libc directories"),
                (macosVariant(libcDirectories=["any-darwin-any", "generic-glibc"]), base, "libc directories"),
                (macosVariant(), base.replace("-isysroot", "-iwithsysroot"), "libc directories"),
                (macosVariant(), base.replace("ld64.lld", "ld.lld"), "no ld64.lld"),
                (macosVariant(definesInBase=["-D_X=1"]), base, "does not")):
            with self.assertRaisesRegex(pe.EngineError, message):
                pc.crossCheck(found, text)

    def test_a_non_macos_variant_keeps_the_strict_libc_and_link_token_checks(self):
        with self.assertRaisesRegex(pe.EngineError, "libc directories"):
            pc.crossCheck(variant(libcDirectories=["any-darwin-any"]), BASE)
        with self.assertRaisesRegex(pe.EngineError, "link tokens"):
            pc.crossCheck(variant(linkTokens=["-dynamic", "-lSystem"]), BASE)


class DarwinLineTest(TempCase):
    """The `zig ld` pseudo-line, the compile line and Zig's own invocation of a macOS target."""

    def setUp(self):
        super().setUp()
        self.cache = self.path("cache")
        for name in ("libc++abi.a", "libc++.a", "libcompiler_rt.a"):
            write(os.path.join(self.cache, name))
        self.output = self.path("out", "fixture.out")

    def link(self, dylib=False, platform="-platform_version macos 11.0.0 11.0.0", deadStrip=True, extra="", output=None, inputs=None,
             start="zig ld", objectName="runtimeCppDarwin.o"):
        c = self.cache
        inputs = inputs or "%s/%s %s/libc++abi.a %s/libc++.a -lSystem %s/libcompiler_rt.a" % (c, objectName, c, c, c)
        return "%s -dynamic%s %s%s %s -o %s %s" % (start, " -dylib" if dylib else "", platform,
                                                  " -dead_strip" if deadStrip else "", extra, output or self.output, inputs)

    def parse(self, line, dylib=False, objectName="runtimeCppDarwin.o"):
        return pc.parseMachOLinkArgv(line, self.output, objectName, self.cache, self.dir, dylib)

    def test_the_include_order_of_a_macos_target_has_no_libunwind_and_a_trailing_or_missing_one_is_refused(self):
        self.assertEqual(pc.splitIsystem(list(MACOS_CXX), False), ("/z/lib", ["any-darwin-any"]))
        for order in (MACOS_CXX + ("/z/lib/libunwind/include",), MACOS_CXX[:-1], MACOS_CXX[1:]):
            with self.assertRaisesRegex(pe.EngineError, "include order"):
                pc.splitIsystem(list(order), False)
        with self.assertRaisesRegex(pe.EngineError, "include order"):
            pc.splitIsystem(list(MACOS_CXX))

    def test_an_executable_plan_yields_its_version_the_archives_in_order_and_the_inputs_only_zigs_runtime_adds(self):
        for deadStrip in (True, False):
            found = self.parse(self.link(deadStrip=deadStrip))
            self.assertEqual((found["version"], found["sdk"], found["zigOnly"]), ("11.0.0", "11.0.0", ["libcompiler_rt.a"]))
            self.assertEqual([os.path.basename(p) for p in found["inputs"]], ["libc++abi.a", "libc++.a", "libcompiler_rt.a"])
            self.assertEqual(found["tokens"], ["-dynamic"] + (["-dead_strip"] if deadStrip else []) + ["-lSystem"])

    def test_a_dylib_plan_names_dylib_and_an_executable_plan_never_does(self):
        found = self.parse(self.link(dylib=True, objectName="runtimeCppShared.o"), True, "runtimeCppShared.o")
        self.assertEqual(found["tokens"], ["-dynamic", "-dylib", "-dead_strip", "-lSystem"])
        with self.assertRaisesRegex(pe.EngineError, "not a dynamic executable"):
            self.parse(self.link(dylib=True))
        with self.assertRaisesRegex(pe.EngineError, "not a dynamic dylib"):
            self.parse(self.link(), True)

    def test_a_plan_that_is_not_zigs_the_floor_or_the_inputs_Zig_prints_is_refused_by_name(self):
        c = self.cache
        other = self.path("elsewhere")
        write(os.path.join(other, "libc++abi.a"))
        for line, message in (
                (self.link(start="ld64.lld"), "expected zig ld"),
                (self.link(platform="-platform_version ios 11.0.0 11.0.0"), "no macos -platform_version"),
                (self.link(platform=""), "no macos -platform_version"),
                (self.link(platform="-platform_version macos 11.0.0 sdk"), "not dotted numbers"),
                (self.link(extra="-platform_version macos 13.0.0 13.0.0"), "option -platform_version"),
                (self.link(extra="-syslibroot /sdk"), "option -syslibroot"),
                (self.link(extra="-undefined dynamic_lookup"), "option -undefined"),
                (self.link(extra="-install_name x"), "option -install_name"),
                (self.link(extra="-L/lib"), "option -L/lib"),
                (self.link(extra="-dynamic"), "are not a dynamic executable"),
                (self.link(output=self.path("other")), "link line writes"),
                (self.link(inputs="%s/runtimeCppDarwin.o -lSystem %s/libc++abi.a %s/libc++.a" % (c, c, c)), "not the fixture object"),
                (self.link(inputs="%s/runtimeCppDarwin.o -lSystem" % c), "not the fixture object"),
                (self.link(inputs="%s/libc++abi.a %s/libc++.a -lSystem" % (c, c)), "not the fixture object"),
                (self.link(inputs="%s/runtimeCppDarwin.o %s/libc++abi.a %s/libc++.a -lSystem -lSystem" % (c, c, c)),
                 "not the fixture object"),
                (self.link(inputs="%s/runtimeCppDarwin.o %s/libc++abi.a %s/libc++.a -lSystem" % (c, other, c)), "private cache"),
                (self.link(inputs="%s/runtimeCppDarwin.o %s/missing.a %s/libc++.a -lSystem" % (c, c, c)), "not a regular file")):
            with self.assertRaisesRegex(pe.EngineError, message):
                self.parse(line)

    def zigRun(self, compile_, link, source):
        def run(zig, target, variant, work, cache):
            return compile_ + "\n" + link + "\n" + '"zig" -cc1 -main-file-name %s -fcxx-exceptions -fexceptions\n' % source, \
                self.output, self.dir
        return mock.patch.object(pc, "runZig", side_effect=run)

    def compileLine(self, fixture, minimum="-mmacos-version-min=11.0.0", isystem=MACOS_CXX):
        return ("/z/zig clang %s -target aarch64-macos.11.0-none %s -Wno-overriding-option -fno-PIE -fPIC -DNDEBUG "
                "-D_LIBCPP_ABI_VERSION=1 %s -Xclang -target-cpu -Xclang apple_m1") % (
            fixture, minimum, " ".join("-isystem " + d for d in isystem))

    def produce(self, target, kind, **changes):
        spec = pc.VARIANTS[(target, kind)]
        stem = os.path.splitext(spec["fixture"])[0]
        compile_ = self.compileLine(os.path.join(pr.FIXTURES, spec["fixture"]), **{k: v for k, v in changes.items() if k in (
            "minimum", "isystem")})
        link = self.link(dylib=kind == "dylib", objectName=stem + ".o", **{k: v for k, v in changes.items() if k in (
            "platform", "inputs")})
        with self.zigRun(compile_, link, spec["fixture"]):
            return pc.produceVariant("/z/zig", target, kind, self.dir, self.cache)

    def test_a_macos_run_yields_the_floor_the_sysroot_headers_and_the_two_archives_for_each_cpu_and_variant(self):
        for target in pc.DARWIN_TARGETS:
            for kind in ("exe", "dylib"):
                found = self.produce(target, kind)
                self.assertEqual(found["macos"], MACOS_FLOOR)
                self.assertEqual(found["libc"], ["any-darwin-any"])
                self.assertEqual([os.path.basename(p) for p in found["archives"]], pc.ARCHIVES[target])
                self.assertEqual((found["defines"], found["definesInBase"]), (["-D_LIBCPP_ABI_VERSION=1"], []))
                self.assertEqual(found["cc1"], ["-fcxx-exceptions", "-fexceptions"])
                self.assertEqual(found["tokens"], ["-dynamic"] + (["-dylib"] if kind == "dylib" else []) + ["-dead_strip", "-lSystem"])

    def test_a_floor_other_than_the_base_configs_on_either_line_or_none_is_refused(self):
        for changes, message in (({"minimum": "-mmacos-version-min=13.0.0"}, "compiled for macOS 13.0.0"),
                                 ({"minimum": ""}, "-mmacos-version-min 0 times"),
                                 ({"minimum": "-mmacos-version-min=11.0.0 -mmacos-version-min=11.0.0"}, "-mmacos-version-min 2 times"),
                                 ({"platform": "-platform_version macos 13.0.0 13.0.0"}, "linked for 13.0.0")):
            with self.assertRaisesRegex(pe.EngineError, message):
                self.produce(pc.MACOS_ARM, "exe", **changes)

    def test_a_libunwind_include_or_archives_out_of_order_in_a_macos_run_are_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "include order"):
            self.produce(pc.MACOS_ARM, "exe", isystem=MACOS_CXX + ("/z/lib/libunwind/include",))
        c = self.cache
        with self.assertRaisesRegex(pe.EngineError, "in a row"):
            self.produce(pc.MACOS, "exe", inputs="%s/runtimeCppDarwin.o %s/libc++.a %s/libc++abi.a -lSystem" % (c, c, c))

    def test_zig_is_run_for_the_macos_floor_with_the_shared_flag_only_for_the_dylib_and_no_libc_flag(self):
        commands = []

        def fake(command, **kwargs):
            commands.append(command)
            return mock.Mock(returncode=0, stderr="lines")

        for target in pc.DARWIN_TARGETS:
            for kind, shared, extension in (("exe", False, "out"), ("dylib", True, "dylib")):
                with mock.patch.object(pc.subprocess, "run", side_effect=fake):
                    stderr, output, private = pc.runZig("/z/zig", target, kind, self.dir, self.cache)
                command = commands[-1]
                self.assertEqual(command[command.index("-target") + 1], target + ".11.0")
                self.assertEqual("-shared" in command, shared)
                self.assertEqual(os.path.basename(output), "fixture." + extension)
                self.assertEqual(command[command.index("-o") + 1], output)
                self.assertEqual(private, os.path.join(self.dir, target, kind))
                self.assertIn("runtimeCppShared.cpp" if shared else "runtimeCppDarwin.cpp", [os.path.basename(c) for c in command])
                self.assertFalse({"-lm", "-lpthread"} & set(command))


class DarwinInspectTest(TempCase):
    NM = "0000 T _cppSum\n"

    def problem(self, kind="exe", target=pc.MACOS_ARM, nm=NM, built=None, builtFor=None, **kwargs):
        syntheticMachO(self.path("f"), builtFor or target, built or kind, **kwargs)
        with mock.patch.object(pe, "run", return_value=nm):
            return pc.machOCppProblem(self.path("f"), kind, target, "nm")

    def test_an_executable_and_a_dylib_of_each_cpu_on_libsystem_alone_with_unwind_sections_pass(self):
        for target in pc.DARWIN_TARGETS:
            for kind in ("exe", "dylib"):
                self.assertIsNone(self.problem(kind, target), msg=(target, kind))

    def test_an_executable_needs_no_export_and_the_nm_is_asked_only_for_a_dylib(self):
        syntheticMachO(self.path("f"))
        with mock.patch.object(pe, "run") as nm:
            self.assertIsNone(pc.machOCppProblem(self.path("f"), "exe", pc.MACOS_ARM, "nm"))
        nm.assert_not_called()

    def test_a_wrong_cpu_kind_install_name_dependency_floor_signature_or_unwind_section_is_a_problem(self):
        libcxx = (pd.LC_LOAD_DYLIB, "/usr/lib/libc++.1.dylib")
        system = (pd.LC_LOAD_DYLIB, pd.LIBSYSTEM)
        cases = [({"builtFor": pc.MACOS}, "cpu type"), ({"target": pc.MACOS, "builtFor": pc.MACOS_ARM}, "cpu type"),
                 ({"kind": "dylib", "built": "exe"}, "not a dylib named"),
                 ({"kind": "exe", "built": "dylib"}, "not an executable with LC_MAIN"),
                 ({"kind": "dylib", "installName": "/tmp/scratch/libx.dylib"}, "not a dylib named"),
                 ({"imports": (system, libcxx)}, "not exactly"), ({"imports": (system, (0x80000018, "/usr/lib/libunwind.dylib"))}, "not exactly"),
                 ({"imports": (system, (0x8000001f, "/usr/lib/libunwind.dylib"))}, "not exactly"), ({"imports": ()}, "not exactly"),
                 ({"minos": 0x000d0000}, "build version"),
                 ({"signature": False}, "LC_CODE_SIGNATURE is absent"),
                 ({"target": pc.MACOS, "signature": True}, "LC_CODE_SIGNATURE is present"),
                 ({"sections": ("__gcc_except_tab",)}, "__unwind_info"), ({"sections": ("__unwind_info",)}, "__gcc_except_tab"),
                 ({"segment": "__DATA"}, "no __TEXT section"), ({"sections": ()}, "no __TEXT section"),
                 ({"kind": "dylib", "nm": "0000 T _other\n"}, "does not export _cppSum")]
        for kwargs, message in cases:
            self.assertRegex(self.problem(**kwargs) or "", message)

    def test_a_truncated_file_is_a_malformed_problem_and_a_file_of_another_format_is_a_named_error(self):
        with open(self.path("short"), "wb") as f:
            f.write(struct.pack("<IiiIIIII", pd.MH_MAGIC_64, pd.TARGETS[pc.MACOS_ARM]["cpuType"], 0, 2, 3, 0, 0, 0))
        self.assertRegex(pc.machOCppProblem(self.path("short"), "exe", pc.MACOS_ARM, "nm"), "malformed Mach-O")
        syntheticElf(self.path("elf"))
        self.assertIn("not a 64-bit Mach-O", pc.machOCppProblem(self.path("elf"), "exe", pc.MACOS_ARM, "nm"))

    def test_bad_command_sizes_and_out_of_command_section_tables_use_the_common_reader(self):
        for target in pc.DARWIN_TARGETS:
            for offset, value in ((16, 0xffffffff), (36, 0), (36, 12), (36, 72), (32 + 64, 0xffffffff)):
                syntheticMachO(self.path("bad"), target)
                with open(self.path("bad"), "r+b") as f:
                    f.seek(offset)
                    f.write(struct.pack("<I", value))
                with self.subTest(target=target, offset=offset, value=value):
                    self.assertIn("malformed Mach-O", pc.machOCppProblem(self.path("bad"), "exe", target, "nm"))

    def test_inspection_follows_the_target_and_a_macos_file_never_reaches_the_elf_or_pe_check(self):
        inspect_ = pc.inspectBinary("nm")
        with mock.patch.object(pc, "machOCppProblem", return_value="m") as macho, \
                mock.patch.object(pc, "elfCppProblem", return_value="e") as elf, \
                mock.patch.object(pc, "peCppProblem", return_value="p") as windows:
            self.assertEqual(inspect_("f", {"target": pc.MACOS, "variant": "dylib"}), "m")
            macho.assert_called_once_with("f", "dylib", pc.MACOS, "nm")
            elf.assert_not_called()
            windows.assert_not_called()
            self.assertEqual(inspect_("f", {"target": pc.LINUX_ARM, "variant": "so"}), "e")
            elf.assert_called_once_with("f", "nm", "so", pc.LINUX_ARM)
            self.assertEqual(inspect_("f", {"target": pc.WINDOWS, "variant": "dll"}), "p")
            windows.assert_called_once_with("f", "dll")
            self.assertEqual(macho.call_count, 1)


class DarwinOverlayTest(TempCase):
    def test_macos_archives_go_to_their_own_directory_and_are_normalized_only_while_their_symbols_stay(self):
        archive = self.path("cache", "libc++.a")
        write(archive)
        for target in pc.DARWIN_TARGETS:
            with mock.patch.object(pr, "copyInputs", return_value=[{"name": "libc++.a"}]) as copy, \
                    mock.patch.object(pc, "archiveSymbols", side_effect=[[("T", "_a")], [("T", "_a")]]) as symbols:
                self.assertEqual(pc.copyArchives("/e", target, [archive], self.path("out")), [{"name": "libc++.a"}])
            self.assertEqual(copy.call_args[0][2], "darwin/%s.cxx" % target)
            self.assertEqual(symbols.call_count, 2)
            with mock.patch.object(pr, "copyInputs", return_value=[{"name": "libc++.a"}]), \
                    mock.patch.object(pc, "archiveSymbols", side_effect=[[("T", "_a")], [("T", "_b")]]):
                with self.assertRaisesRegex(pe.EngineError, "changed its symbols"):
                    pc.copyArchives("/e", target, [archive], self.path("out"))

    def test_archive_symbols_are_the_address_type_name_rows_and_never_a_member_heading_of_three_words(self):
        listing = ("\nlibc++.a(x y.o):\n0000000000000000 T __ZNSt3__16threadD1Ev\n"
                   "/a dir/other archive.a(m z.o):\n0000000000000010 W __ZTVSt9exception\n"
                   "member with spaces.o:\n                 U _undefined\n00000020 D _data\n")
        with mock.patch.object(pe, "run", return_value=listing) as nm:
            self.assertEqual(pc.archiveSymbols("/e", "/x/libc++.a"),
                             [("D", "_data"), ("T", "__ZNSt3__16threadD1Ev"), ("W", "__ZTVSt9exception")])
        self.assertEqual(nm.call_args[0][0][1:], ["--defined-only", "--extern-only", "/x/libc++.a"])

    def test_a_macos_directory_gets_no_alias_and_no_symlink(self):
        directory = self.path("d")
        for name in pc.ARCHIVES[pc.MACOS]:
            write(os.path.join(directory, name))
        self.assertEqual(pc.linkAliases(directory, pc.ARCHIVES[pc.MACOS], pc.SPELLINGS[pc.MACOS]), [])
        self.assertEqual([n for n in os.listdir(directory) if os.path.islink(os.path.join(directory, n))], [])

    def facts(self, directory, defines=None):
        for name in pc.ARCHIVES[pc.MACOS_ARM]:
            write(self.path("archives", directory, name), directory + name)
        return {"zigLib": self.path("zig", "lib"), "libc": ["any-darwin-any"], "tokens": ["-dynamic", "-lSystem"],
                "definesInBase": [], "defines": defines or ["-D_LIBCPP_ABI_VERSION=1"], "cc1": ["-fcxx-exceptions"],
                "archives": [self.path("archives", directory, n) for n in pc.ARCHIVES[pc.MACOS_ARM]], "macos": dict(MACOS_FLOOR)}

    def produce(self, dylibDirectory="exe", dylibDefines=None):
        for relative in pc.HEADERS.values():
            write(self.path("zig", "lib", relative, "header"))
        found = {(pc.MACOS_ARM, "exe"): self.facts("exe"), (pc.MACOS_ARM, "dylib"): self.facts(dylibDirectory, dylibDefines)}
        names = [{"name": n} for n in pc.ARCHIVES[pc.MACOS_ARM]]
        with mock.patch.object(pc, "produceVariant", side_effect=lambda zig, target, variant, work, cache: found[(target, variant)]), \
                mock.patch.object(pc, "copyArchives", return_value=names), \
                mock.patch.object(pc, "linkAliases", return_value=[]) as aliases, mock.patch.object(pr, "copyNotices", return_value=[]):
            return pc.produce("zig", "/e", [pc.MACOS_ARM], self.path("work"), self.path("out"), None, list(found)), aliases

    def test_the_executable_and_the_dylib_share_one_config_written_once_and_records_that_carry_the_macos_floor(self):
        (variants, archives, _), aliases = self.produce()
        self.assertEqual([(v["variant"], v["config"], v["base"]) for v in variants], [
            ("exe", "darwin/aarch64-macos.cxx.cfg", "darwin/aarch64-macos.cfg"),
            ("dylib", "darwin/aarch64-macos.cxx.cfg", "darwin/aarch64-macos.cfg")])
        self.assertEqual([v["macos"] for v in variants], [MACOS_FLOOR, MACOS_FLOOR])
        self.assertEqual(os.listdir(self.path("out", "darwin")), ["aarch64-macos.cxx.cfg"])
        self.assertEqual(read(self.path("out", "darwin", "aarch64-macos.cxx.cfg")),
                         pc.renderConfig(pc.MACOS_ARM, "exe", ["-D_LIBCPP_ABI_VERSION=1"]))
        self.assertEqual((archives[pc.MACOS_ARM]["directory"], archives[pc.MACOS_ARM]["aliases"]), ("darwin/aarch64-macos.cxx", []))
        self.assertEqual(aliases.call_args[0][2], {})

    def test_a_dylib_that_links_other_archives_or_would_write_other_config_text_than_the_executable_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "aarch64-macos dylib links other C.. archives than the executable"):
            self.produce("dylib")
        self.setUp()
        with self.assertRaisesRegex(pe.EngineError, "aarch64-macos dylib: its config text differs"):
            self.produce(dylibDefines=["-D_LIBCPP_ABI_VERSION=2"])

    def test_selection_follows_the_darwin_base_config_the_runtime_holds_and_one_base_gives_both_variants(self):
        write(self.path("rt", "darwin", "aarch64-macos.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.MACOS_ARM])
        self.assertEqual(pc.selectVariants(self.path("rt"), [pc.MACOS_ARM]), [(pc.MACOS_ARM, "exe"), (pc.MACOS_ARM, "dylib")])
        write(self.path("rt", "darwin", "x86_64-macos.cfg"))
        self.assertEqual(pc.selectTargets(self.path("rt"), []), [pc.MACOS_ARM, pc.MACOS])
        self.assertEqual(pc.selectTargets(self.path("rt"), [pc.MACOS]), [pc.MACOS])
        os.remove(self.path("rt", "darwin", "x86_64-macos.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "no base config"):
            pc.selectTargets(self.path("rt"), [pc.MACOS])

    def test_the_cli_passes_macos_targets_to_the_producer(self):
        with mock.patch.object(pc, "prepareCppRuntime", return_value=("/o", {"files": [], "variants": []})) as prepare, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pc.main(["--zig", "/z", "--engine", "/e", "--runtime", "/r", "--output", "/o",
                                      "--target", pc.MACOS_ARM, "--target", pc.MACOS]), 0)
        prepare.assert_called_once_with("/z", "/e", "/r", "/o", [pc.MACOS_ARM, pc.MACOS], None)

    def test_the_overlay_check_runs_the_macos_cross_check_on_the_real_base_text_for_each_variant(self):
        merged = self.path("tree", "runtime")
        write(os.path.join(merged, "darwin", "aarch64-macos.cfg"), pd.renderDarwinConfig(pc.MACOS_ARM))
        receipt = {"variants": [macosVariant(pc.MACOS_ARM, "exe"), macosVariant(pc.MACOS_ARM, "dylib")]}
        with mock.patch.object(pc, "checkControl") as control, mock.patch.object(pc, "checkVariant", return_value={}) as checked:
            outputs = pc.checkOverlay(None, merged, "control", self.dir, receipt)
        self.assertEqual(sorted(outputs), [(pc.MACOS_ARM, "dylib"), (pc.MACOS_ARM, "exe")])
        self.assertEqual((control.call_count, checked.call_count), (2, 2))
        receipt["variants"][1]["macos"]["compileMinimum"] = "13.0.0"
        with mock.patch.object(pc, "checkControl"), mock.patch.object(pc, "checkVariant", return_value={}):
            with self.assertRaisesRegex(pe.EngineError, "is not 11.0"):
                pc.checkOverlay(None, merged, "control", self.dir, receipt)


class DarwinControlTest(TempCase):
    def test_the_macos_controls_read_the_darwin_base_and_c_fixtures_and_the_dylib_gets_its_fixed_install_name(self):
        listing = "#include <...> search starts here:\n %s/runtime/darwin/sysroot/usr/include\nEnd of search list.\n"
        install = ["-dynamiclib", "-install_name", pc.DYLIB_INSTALL_NAME]
        for target in pc.DARWIN_TARGETS:
            for kind, fixture, flags in (("exe", "runtimeDarwin.c", []), ("dylib", "runtimeDarwinDylib.c", install)):
                for root in ("merged", "control"):
                    write(self.path(root, "runtime", "darwin", target + ".cfg"))
                seen = []

                def run(command):
                    root = next(r for r in ("merged", "control") if self.path(r) in " ".join(command))
                    seen.append(command)
                    if "-o" in command:
                        with open(command[command.index("-o") + 1], "wb") as f:
                            f.write(b"same")
                    return mock.Mock(returncode=0, stdout="", stderr=listing % self.path(root) if "-E" in command else "")

                pc.checkControl(run, self.path("merged", "runtime"), self.path("control", "runtime"), self.path("work", target, kind),
                                macosVariant(target, kind))
                self.assertEqual(len(seen), 6)
                for command in seen:
                    self.assertEqual([os.path.basename(c) for c in command if c.startswith("--config=")],
                                     ["--config=%s.cfg" % target])
                    self.assertFalse([c for c in command if ".cxx" in c or "c++" in c], command)
                self.assertEqual({os.path.basename(c) for command in seen for c in command if c.endswith(".c")}, {fixture})
                links = [c for c in seen if "-c" not in c and "-E" not in c]
                self.assertEqual(len(links), 2)
                for command in links:
                    self.assertEqual("-dynamiclib" in command, bool(flags))
                    if flags:
                        at = command.index("-dynamiclib")
                        self.assertEqual(command[at:at + 3], flags)
                outputs = [c[c.index("-o") + 1] for c in links]
                self.assertEqual(len({os.path.basename(o) for o in outputs}), 1)
                self.assertEqual(len({os.path.dirname(o) for o in outputs}), 2)


class DarwinPairTest(TempCase):
    """checkVariant of a macOS variant with the engine mocked."""

    def check(self, target, kind, names=MACOS_INCLUDES):
        merged, root = self.path("tree", "runtime"), self.path("tree")
        listing = "#include <...> search starts here:\n%sEnd of search list.\n" % "".join(" %s/%s\n" % (root, n) for n in names)
        flags = ' "clang" "-cc1" "-triple" "x" "-fcxx-exceptions" "-fexceptions"\n'
        commands = []

        def run(command):
            commands.append(command)
            return mock.Mock(returncode=0, stdout="", stderr=listing if "-E" in command else flags if "-###" in command else "")

        found = dict(macosVariant(target, kind), zigCc1Flags=["-fcxx-exceptions", "-fexceptions"])
        outputs = pc.checkVariant(run, merged, self.dir, found, lambda binary, v: None)
        return pc.VARIANTS[(target, kind)], merged, commands, outputs

    def test_every_macos_command_names_the_one_cxx_config_then_the_one_base_and_only_the_dylib_links_as_one(self):
        install = ["-dynamiclib", "-install_name", pc.DYLIB_INSTALL_NAME]
        for target in pc.DARWIN_TARGETS:
            for kind, count, suffix in (("exe", 10, ".out"), ("dylib", 5, ".dylib")):
                self.setUp()
                spec, merged, commands, outputs = self.check(target, kind)
                pair = [os.path.join(merged, spec["config"]), os.path.join(merged, spec["base"])]
                self.assertEqual(len(commands), count, msg=(target, kind))
                for command in commands:
                    configs = [c[len("--config="):] for c in command if c.startswith("--config=")]
                    tool = os.path.basename(command[0])
                    expected = [] if tool == "llvm-ar" else pair[1:] if tool == "clang" and "-c" in command else pair
                    self.assertEqual(configs, expected, msg=(target, kind, command))
                    self.assertFalse({"-lm", "-lpthread"} & set(command), command)
                links = [c for c in commands if os.path.basename(c[0]) == "clang++" and "-c" not in c and "-E" not in c
                         and "-###" not in c]
                self.assertEqual(len(links), 2)
                for command in links:
                    at = command.index("-dynamiclib") if kind == "dylib" else None
                    self.assertEqual(command[at:at + 3] if kind == "dylib" else [c for c in command if c.startswith("-dynamic")],
                                     install if kind == "dylib" else [])
                self.assertIn("-lc++", links[1])
                self.assertEqual({os.path.splitext(p)[1] for p in outputs.values()}, {suffix})
                self.assertTrue(all("cpp-%s-%s" % (target, kind) in p for p in outputs.values()))
                if kind == "exe":
                    self.assertIn("--format=darwin", next(c for c in commands if os.path.basename(c[0]) == "llvm-ar"))
                    archiveAt = lambda c: next((i for i, a in enumerate(c) if os.path.basename(a) == "libclient.a"), None)
                    clients = [c[archiveAt(c) + 1:c.index("-o")] for c in commands
                               if os.path.basename(c[0]) == "clang" and archiveAt(c) is not None]
                    self.assertEqual(clients, [["-lc++"], ["-lc++", "-lc++abi"]])

    def test_an_include_list_that_is_not_libcxx_abi_builtin_sysroot_alone_is_refused(self):
        a, b, builtin, sysroot = MACOS_INCLUDES
        for names in (MACOS_INCLUDES + ["runtime/include/cxx/libunwind"], [a, b, sysroot], [b, a, builtin, sysroot],
                      [a, b, sysroot, builtin], [a, b, builtin], [a, b, "lib/clang/22/include/x", sysroot]):
            self.setUp()
            with self.assertRaisesRegex(pe.EngineError, "include order .* is not libcxx, libcxxabi, builtin, sysroot"):
                self.check(pc.MACOS_ARM, "exe", names)


class DarwinHostTest(unittest.TestCase):
    """Which native host runs which target, and the receipt variants it needs."""

    def test_an_arm64_mac_runs_aarch64_macos_and_an_intel_mac_x86_64_macos(self):
        for machine in ("arm64", "aarch64"):
            self.assertEqual(pc.executionTarget("Darwin", machine), (pc.MACOS_ARM, None))
        self.assertEqual(pc.executionTarget("Darwin", "x86_64", translated=False), (pc.MACOS, None))

    def test_an_x86_64_process_that_rosetta_translates_is_not_an_intel_mac(self):
        target, problem = pc.executionTarget("Darwin", "x86_64", translated=True)
        self.assertIsNone(target)
        self.assertRegex(problem, "Rosetta")
        with mock.patch.object(pc, "translatedByRosetta", return_value=True) as probe:
            self.assertIsNone(pc.executionTarget("Darwin", "x86_64")[0])
        probe.assert_called_once_with()
        with mock.patch.object(pc, "translatedByRosetta") as probe:
            pc.executionTarget("Darwin", "arm64")
            pc.executionTarget("Linux", "x86_64", True)
        probe.assert_not_called()

    def rosettaProbe(self, returncode=0, value=0, error=0, size=None):
        def query(name, result, length, newValue, newSize):
            self.assertEqual((name, newValue, newSize), (b"sysctl.proc_translated", None, 0))
            result._obj.value = value
            if size is not None:
                length._obj.value = size
            return returncode
        library = mock.Mock()
        library.sysctlbyname.side_effect = query
        with mock.patch("ctypes.CDLL", return_value=library) as load, mock.patch("ctypes.get_errno", return_value=error):
            translated = pc.translatedByRosetta()
        load.assert_called_once_with(None, use_errno=True)
        return translated

    def test_the_rosetta_probe_reads_the_native_sysctl_and_only_enoent_means_an_absent_native_flag(self):
        import errno
        self.assertTrue(self.rosettaProbe(value=1))
        self.assertFalse(self.rosettaProbe(value=0))
        self.assertFalse(self.rosettaProbe(returncode=-1, error=errno.ENOENT))
        with self.assertRaisesRegex(pe.EngineError, "sysctl.proc_translated failed"):
            self.rosettaProbe(returncode=-1, error=errno.EACCES)
        for value, size in ((2, None), (-1, None), (0, 0), (1, 8)):
            with self.assertRaisesRegex(pe.EngineError, "sysctl.proc_translated returned invalid"):
                self.rosettaProbe(value=value, size=size)

    def test_a_foreign_host_or_cpu_runs_no_target(self):
        for system, machine in (("Linux", "ppc64"), ("Linux", "riscv64"), ("Windows", "AMD64"), ("Darwin", "ppc64"),
                                ("Darwin", "i386")):
            target, problem = pc.executionTarget(system, machine, True, False)
            self.assertIsNone(target, msg=(system, machine))
            self.assertIn("%s %s" % (system, machine), problem)

    def receipt(self, *pairs):
        return {"variants": [macosVariant(t, k) if t in pc.DARWIN_TARGETS else variant(target=t, variant=k) for t, k in pairs]}

    def test_each_mac_cpu_picks_its_own_executable_then_dylib_and_ignores_the_other_cpus(self):
        both = self.receipt(*[(t, k) for t in pc.DARWIN_TARGETS for k in ("dylib", "exe")] + [(pc.LINUX, "so")])
        for target in pc.DARWIN_TARGETS:
            found = pc.executedVariants(both, target)
            self.assertEqual([(v["target"], v["variant"]) for v in found], [(target, "exe"), (target, "dylib")])
        self.assertEqual([(v["target"], v["variant"]) for v in pc.executedVariants(both, pc.LINUX)], [(pc.LINUX, "so")])

    def test_a_missing_or_duplicate_variant_is_refused_by_name(self):
        for target in pc.DARWIN_TARGETS:
            other = [t for t in pc.DARWIN_TARGETS if t != target][0]
            cases = ((self.receipt((target, "dylib"), (other, "exe")), "no %s executable" % target),
                     (self.receipt((target, "exe"), (other, "dylib")), "no %s dylib" % target),
                     (self.receipt((other, "exe"), (other, "dylib")), "no %s executable" % target),
                     (self.receipt((target, "exe"), (target, "dylib"), (target, "exe")), "2 %s executable variants" % target),
                     (self.receipt((target, "exe"), (target, "dylib"), (target, "dylib")), "2 %s dylib variants" % target))
            for receipt, message in cases:
                with self.assertRaisesRegex(pe.EngineError, "--execute: the overlay has .*%s" % message):
                    pc.executedVariants(receipt, target)
        with self.assertRaisesRegex(pe.EngineError, "no Linux shared-object variant"):
            pc.executedVariants(self.receipt((pc.LINUX, "exe"), (pc.LINUX_ARM, "so")), pc.LINUX)


class DarwinRunTest(TempCase):
    """The native runs: expected output from the fixture sources, the C host without libdl, the run order."""

    def fixture(self, name):
        return read(os.path.join(pr.FIXTURES, name))

    def test_the_expected_output_is_what_the_fixture_sources_print(self):
        executable = self.fixture("runtimeCppDarwin.cpp")
        values = [int(n) for n in re.search(r"std::vector<int> values\{([\d, ]+)\}", executable).group(1).split(",")]
        what = re.search(r'throw std::runtime_error\("(\w+)"\)', executable).group(1)
        self.assertIn('"cpp sum=%d what=%s\\n"', executable)
        self.assertEqual(pc.EXECUTABLE_OUTPUT, "cpp sum=%d what=%s\n" % (sum(values), what))
        archive, client = self.fixture("cppArchive.cpp"), self.fixture("cppArchiveClient.c")
        each = int(re.search(r"std::vector<int> values\(count, (\d+)\)", archive).group(1))
        count = int(re.search(r"cppArchiveSum\((\d+)\)", client).group(1))
        self.assertIn('"archive sum=%d\\n"', client)
        self.assertEqual(pc.CLIENT_OUTPUT, "archive sum=%d\n" % (each * count))
        self.assertEqual(pc.RUN_OUTPUTS, {"plain": pc.EXECUTABLE_OUTPUT, "written": pc.EXECUTABLE_OUTPUT,
                                          "client": pc.CLIENT_OUTPUT, "client with every spelling": pc.CLIENT_OUTPUT})
        host = self.fixture(pc.HOST_FIXTURE)
        self.assertIn('puts("host ok")', host)
        self.assertIn('"cpp caught=%s destroyed=%d\\n"', self.fixture("runtimeCppShared.cpp"))

    def files(self):
        return {name: self.path(name.replace(" ", "-")) for name in pc.RUN_OUTPUTS}

    def runner(self, returncode=0, stderr="", printed=None):
        commands = []
        byPath = {self.path(n.replace(" ", "-")): o for n, o in pc.RUN_OUTPUTS.items()}

        def run(command):
            commands.append(command)
            return mock.Mock(returncode=returncode, stdout=byPath[command[0]] if printed is None else printed, stderr=stderr)
        return run, commands

    def test_each_linked_executable_runs_alone_by_its_absolute_path(self):
        run, commands = self.runner()
        pc.checkRuns(run, self.files())
        self.assertEqual(commands, [[self.path(n.replace(" ", "-"))] for n in sorted(pc.RUN_OUTPUTS)])
        self.assertTrue(all(os.path.isabs(c[0]) for c in commands))

    def test_a_run_that_fails_prints_otherwise_or_warns_is_refused(self):
        for kwargs, message in (({"returncode": 1}, r"client run failed \(1\)"), ({"stderr": "dyld: warning"}, "warned: dyld: warning"),
                                ({"printed": "cpp sum=0 what=boom\n"}, "printed .*sum=0")):
            run, commands = self.runner(**kwargs)
            with self.assertRaisesRegex(pe.EngineError, message):
                pc.checkRuns(run, self.files())
            self.assertEqual(len(commands), 1)

    def test_missing_or_extra_linked_files_are_refused_before_anything_runs(self):
        files = self.files()
        for changed in ({k: v for k, v in files.items() if k != "written"}, dict(files, extra=self.path("extra"))):
            run, commands = self.runner()
            with self.assertRaisesRegex(pe.EngineError, "are not the .* to run"):
                pc.checkRuns(run, changed)
            self.assertEqual(commands, [])

    def host(self, target):
        commands = []

        def run(command):
            commands.append(command)
            if "-o" in command:
                write(command[command.index("-o") + 1])
            return mock.Mock(returncode=0, stdout=pc.HOST_OUTPUT if command[0].endswith("host.out") else "", stderr="")
        merged = self.path(target, "tree", "runtime")
        pc.checkHost(run, merged, self.path(target, "work"), [self.path("a.dylib"), self.path("b.dylib")], target=target)
        return merged, commands

    def test_the_mac_host_links_only_its_own_darwin_c_base_with_no_libdl_and_no_cpp(self):
        for target in pc.DARWIN_TARGETS:
            merged, commands = self.host(target)
            self.assertEqual([os.path.basename(c[0]) for c in commands], ["clang", "clang", "host.out", "host.out"])
            for command in commands[:2]:
                self.assertEqual([c for c in command if c.startswith("--config=")],
                                 ["--config=" + os.path.join(merged, "darwin/%s.cfg" % target)])
                self.assertIn("--no-default-config", command)
                self.assertFalse([c for c in command if c.startswith("-l") or "c++" in c or ".cxx" in c or "dylib" in c], command)
            self.assertIn("host-" + target, commands[1][commands[1].index("-o") + 1])
            self.assertEqual([c[1:] for c in commands[2:]], [[self.path("a.dylib")], [self.path("b.dylib")]])
            self.assertEqual(pc.HOST_FIXTURE, os.path.basename(next(c for c in commands[0] if c.endswith(".c"))))

    def test_the_mac_host_runs_with_no_library_path_environment(self):
        with mock.patch.object(pc.subprocess, "run", return_value=mock.Mock()) as called:
            pc.boundedRun("aarch64-macos dylib")(["host.out", "a.dylib"])
        self.assertEqual(sorted(called.call_args.kwargs["env"]), ["HOME", "PATH"])

    def test_a_mac_run_that_outlasts_its_timeout_names_the_target_and_variant(self):
        for kind in ("exe", "dylib"):
            with mock.patch.object(pc.subprocess, "run", side_effect=pc.subprocess.TimeoutExpired("x", 45)):
                with self.assertRaisesRegex(pe.EngineError, "x86_64-macos %s: /t/x timed out after 45 s" % kind):
                    pc.boundedRun("x86_64-macos " + kind)(["/t/x"])


class DarwinExecuteTest(TempCase):
    """pc.execute on a native Mac with every check mocked: order, selection, refusal before compiling, cleanup."""

    def start(self, target, receipt=None, **patches):
        receipt = receipt or {"files": ["x"], "variants": [macosVariant(t, k) for t in pc.DARWIN_TARGETS for k in ("dylib", "exe")]}
        calls = mock.Mock()
        exeFiles = {name: self.path(name.replace(" ", "-")) for name in pc.RUN_OUTPUTS}
        dylibFiles = {"plain": self.path("plain.dylib"), "written": self.path("written.dylib")}
        variant = lambda run, merged, work, found, inspect: exeFiles if found["variant"] == "exe" else dylibFiles
        self.work = self.path("execute")
        os.makedirs(self.work)
        wanted = {"executionTarget": mock.Mock(return_value=(target, None)), "openProof": mock.Mock(return_value=("/e", "/e/runtime", receipt)),
                  "boundedRun": mock.Mock(side_effect=lambda label: label), "controlTree": mock.Mock(return_value="control"),
                  "checkControl": calls.control, "checkVariant": calls.variant, "checkRuns": calls.runs, "checkHost": calls.host,
                  "inspectBinary": mock.Mock(return_value="inspect")}
        calls.variant.side_effect = variant
        wanted.update(patches)
        patchers = [mock.patch.object(pc, name, value) for name, value in wanted.items()] + [
            mock.patch.object(pc.shutil, "copytree"), mock.patch.object(pc.tempfile, "mkdtemp", return_value=self.work)]
        for patcher in patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        return calls, wanted

    def test_each_mac_cpu_checks_control_link_then_run_for_the_executable_then_the_dylib(self):
        for target in pc.DARWIN_TARGETS:
            self.setUp()
            calls, wanted = self.start(target)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                pc.execute("/e", "/e/runtime")
            self.assertEqual([c[0] for c in calls.mock_calls], ["control", "variant", "runs", "control", "variant", "host"])
            kinds = [c.args[-1]["variant"] for c in calls.control.call_args_list]
            self.assertEqual(kinds, ["exe", "dylib"])
            self.assertEqual({c.args[-1]["target"] for c in calls.control.call_args_list}, {target})
            self.assertEqual([c.args[0] for c in calls.control.call_args_list], ["%s exe" % target, "%s dylib" % target])
            self.assertEqual(calls.runs.call_args.args[1], {n: self.path(n.replace(" ", "-")) for n in pc.RUN_OUTPUTS})
            self.assertEqual(calls.host.call_args.args[-1], [self.path("plain.dylib"), self.path("written.dylib")])
            self.assertEqual(calls.host.call_args.kwargs, {"target": target})
            self.assertEqual(out.getvalue().count("run natively; execution only; hermetic proof not run"), 4)
            self.assertEqual(out.getvalue().count("run by the C host; execution only; hermetic proof not run"), 2)
            self.assertNotIn("denied", out.getvalue())
            self.assertFalse(os.path.exists(self.work))

    def test_a_foreign_host_or_a_missing_receipt_variant_fails_before_any_copy_or_compile(self):
        for receipt, target, message in (
                ({"files": [], "variants": [macosVariant(pc.MACOS, "exe"), macosVariant(pc.MACOS, "dylib")]}, pc.MACOS_ARM, "no aarch64-macos executable"),
                ({"files": [], "variants": [macosVariant(pc.MACOS_ARM, "exe")]}, pc.MACOS_ARM, "no aarch64-macos dylib"),
                ({"files": [], "variants": [macosVariant(pc.MACOS_ARM, "exe")] * 2 + [macosVariant(pc.MACOS_ARM, "dylib")]}, pc.MACOS_ARM, "2 aarch64-macos executable variants")):
            self.setUp()
            calls, wanted = self.start(target, receipt)
            with self.assertRaisesRegex(pe.EngineError, "--execute: .*" + message):
                pc.execute("/e", "/e/runtime")
            self.assertEqual(calls.mock_calls, [])
            pc.shutil.copytree.assert_not_called()
            pc.tempfile.mkdtemp.assert_not_called()
        self.setUp()
        calls, wanted = self.start(pc.MACOS_ARM, executionTarget=mock.Mock(return_value=(None, "host is Linux aarch64")))
        with self.assertRaisesRegex(pe.EngineError, "--execute: host is Linux aarch64"):
            pc.execute("/e", "/e/runtime")
        wanted["openProof"].assert_not_called()
        self.assertEqual(calls.mock_calls, [])

    def test_a_failed_run_stops_the_dylib_and_removes_only_the_private_tree(self):
        calls, wanted = self.start(pc.MACOS_ARM)
        calls.runs.side_effect = pe.EngineError("client run failed (1)")
        with self.assertRaisesRegex(pe.EngineError, "client run failed"):
            pc.execute("/e", "/e/runtime")
        self.assertEqual([c[0] for c in calls.mock_calls], ["control", "variant", "runs"])
        self.assertFalse(os.path.exists(self.work))
        self.assertTrue(os.path.isdir(self.dir))

    def test_a_failed_host_removes_the_private_tree_too(self):
        calls, wanted = self.start(pc.MACOS)
        calls.host.side_effect = pe.EngineError("C host run failed (3)")
        with self.assertRaisesRegex(pe.EngineError, "C host run failed"):
            pc.execute("/e", "/e/runtime")
        self.assertFalse(os.path.exists(self.work))

    def test_prove_and_the_hermetic_overlay_check_never_run_or_select_a_host(self):
        for function in (pc.prove, pc.checkOverlay):
            source = inspect.getsource(function)
            for name in ("checkHost", "checkRuns", "executionTarget", "executedVariants", "translatedByRosetta"):
                self.assertNotIn(name, source, msg=(function.__name__, name))
        self.assertIn("linked and inspected; not run", inspect.getsource(pc.prove))

    def test_the_limits_say_a_mac_file_runs_only_natively_and_never_under_rosetta(self):
        text = " ".join(pc.LIMITS)
        self.assertIn("native Mac of its CPU, never under Rosetta", text)
        self.assertIn("without the sandbox of --prove", text)


if __name__ == "__main__":
    unittest.main()
