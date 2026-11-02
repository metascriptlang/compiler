import contextlib
import io
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
import prepareWindowsRuntime as pw
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws

REV = pws.LLVM_PINS["23.1.0"]
TARGETS = [pw.TARGET, pw.ARM64_TARGET]
SITE = ("#ifndef _LIBCPP___CONFIG_SITE\n#define _LIBCPP___CONFIG_SITE\n#define _LIBCPP_ABI_VERSION 1\n"
        "#define _LIBCPP_HAS_THREADS 1\n#define _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS\n"
        "#define _LIBCPP_HAS_THREAD_API_PTHREAD 0\n#define _LIBCPP_HAS_THREAD_API_EXTERNAL 0\n"
        "#define _LIBCPP_HAS_THREAD_API_WIN32 0\n#define _LIBCPP_HAS_THREAD_API_C11 0\n"
        "#define __USE_MINGW_ANSI_STDIO 1\n#endif\n")
SITE_WIN32 = SITE.replace("WIN32 0", "WIN32 1")
SYMBOLS = {"libc++.a": ["__cxa_throw", "__cxa_begin_catch", "__cxa_end_catch", "__gxx_personality_seh0",
                        "_ZNSt3__16threadD1Ev"],
           "libc++abi.a": ["__cxa_throw", "__cxa_begin_catch", "__cxa_end_catch", "__gxx_personality_seh0"],
           "libunwind.a": ["_Unwind_RaiseException", "_Unwind_Resume", "_Unwind_Backtrace"]}
SOURCE_FILES = {"libcxx/include/vector": b"// vector\n", "libcxx/include/__config": b"// config\n",
                "libcxxabi/include/cxxabi.h": b"// cxxabi\n", "libunwind/include/libunwind.h": b"// libunwind\n",
                "libunwind/include/__libunwind_config.h": b"// libunwind config\n",
                "libunwind/include/unwind.h": b"// unwind\n", "libunwind/include/unwind_itanium.h": b"// itanium\n",
                "libunwind/include/unwind_arm_ehabi.h": b"// ehabi\n",
                "libcxx/cmake/caches/MinGW.cmake": b"# cache\n", "libcxx/LICENSE.TXT": b"libcxx license\n",
                "libcxxabi/LICENSE.TXT": b"libcxxabi license\n", "libunwind/LICENSE.TXT": b"libunwind license\n"}
BASE_RECEIPT = {"kind": pws.RECEIPT_KIND, "targets": TARGETS, "engineRelative": pw.ENGINE_RELATIVE,
                "sources": {"llvm-project": {"rev": REV, "version": "23.1.0", "major": "23"}}}


def write(path, data=b"x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def read(path):
    with open(path, "rb") as f:
        return f.read()


FOREIGN = {"include/cxx/libcxx/vector": b"// zig libcxx\n", "include/cxx/libunwind/libunwind.h": b"// zig libunwind\n",
           "notices/cpp-provenance.json": b"{\"kind\": \"local-zig-cpp-runtime-proof\"}\n",
           "notices/libcxx/LICENSE.TXT": b"zig libcxx license\n",
           "x86_64-linux-gnu.2.31.cxx/libc++.a": b"linux archive\n", "x86_64-linux-gnu.2.31.cxx.cfg": b"-stdlib=libc++\n",
           "aarch64-macos.cxx.cfg": b"-stdlib=libc++\n", "aarch64-macos.cxx/libc++.a": b"darwin archive\n"}


def snapshot(root, only=FOREIGN):
    return {relative: read(os.path.join(root, *relative.split("/"))) for relative in only}


def coff(machine):
    return struct.pack("<H", machine) + bytes(14)


def importMember(machine):
    return struct.pack("<HHHH", 0, 0xFFFF, 0, machine) + bytes(8)


def archive(members):
    out = b"!<arch>\n"
    for name, body in members:
        header = ("%-16s%-12s%-6s%-6s%-8s%-10d`\n" % (name + "/", "0", "0", "0", "644", len(body))).encode("ascii")
        out += header + body + (b"\n" if len(body) % 2 else b"")
    return out


def symbols(engine, path):
    return [("T", name) for name in SYMBOLS[os.path.basename(path)]]


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareWindowsSourceCppRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def makeSource(self):
        root = self.path("llvm")
        for relative, data in SOURCE_FILES.items():
            write(os.path.join(root, *relative.split("/")), data)
        return root

    def makeInstall(self, name, source, machine=pw.TARGETS[pw.TARGET]["machine"], site=SITE, leave=()):
        prefix = self.path(name)
        for archiveName in pwc.ARCHIVES + pwc.LEFT_OUT:
            if archiveName not in leave:
                write(os.path.join(prefix, "lib", archiveName), archive([("m.o", coff(machine))]))
        for relative, destination in (("libcxx/include/vector", "c++/v1/vector"),
                                      ("libcxx/include/__config", "c++/v1/__config"),
                                      ("libcxxabi/include/cxxabi.h", "c++/v1/cxxabi.h"),
                                      ("libunwind/include/libunwind.h", "libunwind.h"),
                                      ("libunwind/include/__libunwind_config.h", "__libunwind_config.h"),
                                      ("libunwind/include/unwind.h", "unwind.h"),
                                      ("libunwind/include/unwind_itanium.h", "unwind_itanium.h"),
                                      ("libunwind/include/unwind_arm_ehabi.h", "unwind_arm_ehabi.h")):
            shutil.copyfile(os.path.join(source, *relative.split("/")),
                            self.ensure(os.path.join(prefix, "include", *destination.split("/"))))
        generated = {"__config_site": site, "__assertion_handler": b"generated assertion handler\n",
                     "module.modulemap": b'module std_config { textual header "__config_site" }\n',
                     "libcxx.imp": b"[]\n"}
        for name, data in generated.items():
            write(os.path.join(prefix, "include", "c++", "v1", name), data)
        return prefix

    def ensure(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return path

    def stage(self, prefix, target, source, output):
        with mock.patch.object(pc, "archiveSymbols", side_effect=symbols):
            return pwc.stagePayload(prefix, target, source, "/engine", output)

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

    def command(self, target=pw.TARGET, tools=None):
        return pwc.runtimesCommand(self.llvm, self.stage, target, self.path("build"), self.path("prefix"),
                                   tools or {"cmake": "/t/cmake", "ninja": "/t/ninja"}, "/t/python3")

    def definitions(self, command):
        return dict(word[2:].split("=", 1) for word in command if word.startswith("-D"))

    def test_the_upstream_mingw_cache_is_loaded_first_and_the_source_is_the_runtimes_directory(self):
        command = self.command()
        self.assertEqual(command[:3], ["/t/cmake", "-C", os.path.join(self.llvm, "libcxx", "cmake", "caches", "MinGW.cmake")])
        self.assertLess(command.index("-C"), min(i for i, w in enumerate(command) if w.startswith("-D")))
        self.assertEqual(command[command.index("-S") + 1], os.path.join(self.llvm, "runtimes"))

    def test_the_three_runtimes_are_static_only_with_no_tests_modules_benchmarks_or_docs(self):
        found = self.definitions(self.command())
        self.assertEqual(found["LLVM_ENABLE_RUNTIMES"], "libunwind;libcxxabi;libcxx")
        for name in ("LIBCXX", "LIBCXXABI", "LIBUNWIND"):
            self.assertEqual((found[name + "_ENABLE_SHARED"], found[name + "_ENABLE_STATIC"], found[name + "_INCLUDE_TESTS"]),
                             ("OFF", "ON", "OFF"))
        self.assertEqual((found["LIBCXX_INSTALL_MODULES"], found["LIBCXX_INCLUDE_BENCHMARKS"], found["LIBCXX_INCLUDE_DOCS"],
                          found["LLVM_INCLUDE_TESTS"]), ("OFF",) * 4)
        self.assertEqual((found["LIBCXX_CXX_ABI"], found["LIBCXXABI_USE_LLVM_UNWINDER"], found["LIBCXX_ENABLE_STATIC_ABI_LIBRARY"],
                          found["LLVM_ENABLE_PER_TARGET_RUNTIME_DIR"], found["LIBUNWIND_INSTALL_HEADERS"]),
                         ("libcxxabi", "ON", "ON", "OFF", "ON"))
        self.assertTrue(all(found[n] == "ON" for n in ("LIBCXX_USE_COMPILER_RT", "LIBCXXABI_USE_COMPILER_RT",
                                                       "LIBUNWIND_USE_COMPILER_RT")))
        self.assertEqual([found[n] for n in ("LIBCXX_LIBDIR_SUFFIX", "LIBCXXABI_LIBDIR_SUFFIX", "LIBUNWIND_LIBDIR_SUFFIX")],
                         ["", "", ""])

    def test_each_target_has_its_triple_its_own_c_config_as_init_flags_and_a_private_prefix(self):
        for target, triple in ((pw.TARGET, "x86_64-w64-windows-gnu"), (pw.ARM64_TARGET, "aarch64-w64-windows-gnu")):
            found = self.definitions(self.command(target))
            config = os.path.join(self.stage, "runtime", "windows", target + ".cfg")
            for language in ("C", "CXX", "ASM"):
                self.assertEqual(found["CMAKE_%s_COMPILER_TARGET" % language], triple)
                self.assertEqual(found["CMAKE_%s_FLAGS_INIT" % language], "--no-default-config --config=" + config)
                self.assertEqual(found["CMAKE_%s_COMPILER_WORKS" % language], "TRUE")
            self.assertEqual(found["CMAKE_INSTALL_PREFIX"], self.path("prefix"))
            self.assertEqual(found["CMAKE_SYSTEM_NAME"], "Windows")
            self.assertEqual(found["Python3_EXECUTABLE"], "/t/python3")

    def test_the_compiler_is_the_staged_engines_and_no_flag_names_the_cxx_config_or_a_foreign_header_directory(self):
        found = self.definitions(self.command())
        self.assertEqual(found["CMAKE_CXX_COMPILER"], os.path.join(self.stage, "bin", "clang++"))
        self.assertEqual(found["CMAKE_C_COMPILER"], os.path.join(self.stage, "bin", "clang"))
        self.assertFalse([v for v in found.values() if ".cxx" in v or "include/cxx" in v])
        self.assertNotIn(self.stage + os.sep, found["CMAKE_INSTALL_PREFIX"])

    def test_ninja_is_used_when_found_and_makefiles_when_not(self):
        self.assertEqual(self.command()[self.command().index("-G") + 1], "Ninja")
        without = self.command(tools={"cmake": "/t/cmake"})
        self.assertEqual(without[without.index("-G") + 1], "Unix Makefiles")
        self.assertFalse([w for w in without if w.startswith("-DCMAKE_MAKE_PROGRAM")])

    def test_the_markers_cover_every_file_the_recipe_and_the_notices_read(self):
        for name in ("runtimes/CMakeLists.txt", pwc.CACHE, "libcxx/LICENSE.TXT", "libcxxabi/LICENSE.TXT",
                     "libunwind/LICENSE.TXT", "cmake/Modules/LLVMVersion.cmake"):
            self.assertIn(name, pwc.LLVM_CPP_MARKERS)

    def test_the_python_is_the_given_one_and_must_be_python_3(self):
        with mock.patch.object(pe, "run", return_value="Python 3.11.2\n"):
            self.assertEqual(pwc.resolvePython("/t/py"), (os.path.abspath("/t/py"), "Python 3.11.2"))
        with mock.patch.object(pe, "run", return_value="Python 2.7.18\n"):
            with self.assertRaisesRegex(pe.EngineError, "not Python 3"):
                pwc.resolvePython("/t/py")
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaisesRegex(pe.EngineError, "no python3"):
                pwc.resolvePython()


class ConfigTest(unittest.TestCase):
    def test_the_config_sets_libcxx_then_the_header_directories_the_search_directory_and_the_link_tail(self):
        self.assertEqual(pwc.renderCxxConfig(pw.TARGET),
                         "-stdlib=libc++\n-isystem <CFGDIR>/x86_64-windows-gnu.cxx/include/c++/v1\n"
                         "-idirafter <CFGDIR>/x86_64-windows-gnu.cxx/include\n"
                         "-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu.cxx\n$-lc++\n$-lunwind\n")

    def test_the_config_names_the_public_unwind_headers_late_and_its_own_target_alone_and_links_no_pthread(self):
        for target in TARGETS:
            text = pwc.renderCxxConfig(target)
            lines = text.splitlines()
            self.assertIn("-idirafter <CFGDIR>/%s.cxx/include" % target, lines)
            self.assertEqual([l for l in lines if "-isystem" in l or "-I" in l.split()],
                             ["-isystem <CFGDIR>/%s.cxx/include/c++/v1" % target])
            self.assertNotIn("pthread", text)
            self.assertEqual(text.count("<CFGDIR>/%s.cxx" % target), text.count("<CFGDIR>/"))

    def test_the_config_never_sets_an_unwind_library_the_stdlib_isystem_the_zig_headers_or_nostdlib(self):
        for target in TARGETS:
            text = pwc.renderCxxConfig(target)
            for forbidden in ("--unwindlib", "-stdlib++-isystem", "include/cxx", "-nostdlib", "-lstdc++", "-lgcc",
                              "-resource-dir", "--sysroot", "-B"):
                self.assertNotIn(forbidden, text)
            lines = text.splitlines()
            tails = [l for l in lines if l.startswith("$")]
            self.assertEqual(lines[-len(tails):], tails)
            self.assertTrue(all(l.startswith("$-l") for l in tails))

    def test_both_variants_name_one_payload_and_pair_with_their_own_base_config(self):
        self.assertEqual(pwc.configPath(pw.TARGET, "exe"), "windows/x86_64-windows-gnu.cxx.cfg")
        self.assertEqual(pwc.configPath(pw.TARGET, "dll"), "windows/x86_64-windows-gnu.dll.cxx.cfg")
        self.assertEqual(pwc.baseConfigPath(pw.ARM64_TARGET, "dll"), "windows/aarch64-windows-gnu.dll.cfg")
        self.assertEqual(pwc.payloadDirectory(pw.ARM64_TARGET), "windows/aarch64-windows-gnu.cxx")


class ConfigSiteTest(unittest.TestCase):
    def test_the_upstream_default_site_with_all_four_thread_apis_zero_is_the_effective_win32_api_selected_by_none(self):
        facts, problem = pwc.configSiteFacts(SITE)
        self.assertIsNone(problem)
        self.assertEqual(facts[1:], ("WIN32", []))
        self.assertEqual(facts[0]["__USE_MINGW_ANSI_STDIO"], "1")
        self.assertEqual([facts[0]["_LIBCPP_HAS_THREAD_API_" + api] for api in pwc.THREAD_APIS], ["0"] * 4)

    def test_a_site_that_selects_win32_itself_is_the_same_effective_api_selected_by_the_site(self):
        facts, problem = pwc.configSiteFacts(SITE_WIN32)
        self.assertIsNone(problem)
        self.assertEqual(facts[1:], ("WIN32", ["WIN32"]))

    def test_a_site_without_visibility_annotations_disabled_is_not_static_only(self):
        facts, problem = pwc.configSiteFacts(SITE.replace("#define _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS\n", ""))
        self.assertIsNone(facts)
        self.assertIn("static-only", problem)

    def test_ansi_stdio_must_be_one(self):
        for text in (SITE.replace("#define __USE_MINGW_ANSI_STDIO 1\n", ""),
                     SITE.replace("__USE_MINGW_ANSI_STDIO 1", "__USE_MINGW_ANSI_STDIO 0")):
            self.assertIn("__USE_MINGW_ANSI_STDIO", pwc.configSiteFacts(text)[1])

    def test_pthread_external_or_c11_selected_by_the_site_is_refused_naming_it_and_never_linked_with_pthread(self):
        for api in ("PTHREAD", "EXTERNAL", "C11"):
            facts, problem = pwc.configSiteFacts(SITE.replace(api + " 0", api + " 1"))
            self.assertIsNone(facts)
            self.assertIn("selects the %s thread API" % api, problem)
            self.assertIn("builds no other", problem)

    def test_two_selected_thread_apis_are_refused_whatever_they_are(self):
        for first, second in (("WIN32", "PTHREAD"), ("PTHREAD", "C11"), ("EXTERNAL", "WIN32")):
            text = SITE.replace(first + " 0", first + " 1").replace(second + " 0", second + " 1")
            self.assertIn("not at most one", pwc.configSiteFacts(text)[1])

    def test_a_thread_api_value_that_is_not_zero_or_one_or_is_missing_and_a_site_without_threads_are_refused(self):
        for text, name in ((SITE.replace("WIN32 0", "WIN32 2"), "_LIBCPP_HAS_THREAD_API_WIN32"),
                           (SITE.replace("PTHREAD 0", "PTHREAD yes"), "_LIBCPP_HAS_THREAD_API_PTHREAD"),
                           (SITE.replace("#define _LIBCPP_HAS_THREAD_API_C11 0\n", ""), "_LIBCPP_HAS_THREAD_API_C11")):
            self.assertIn("%s as" % name, pwc.configSiteFacts(text)[1])
        for text in (SITE.replace("THREADS 1", "THREADS 0"), SITE.replace("#define _LIBCPP_HAS_THREADS 1\n", "")):
            self.assertIn("_LIBCPP_HAS_THREADS as", pwc.configSiteFacts(text)[1])


class InstallTest(TempCase):
    def setUp(self):
        super().setUp()
        self.source = self.makeSource()

    def test_a_complete_install_is_accepted_with_or_without_the_left_out_archive(self):
        self.assertIsNone(pwc.installProblem(self.makeInstall("a", self.source)))
        self.assertIsNone(pwc.installProblem(self.makeInstall("b", self.source, leave=pwc.LEFT_OUT)))

    def test_all_four_upstream_generated_include_artifacts_are_accepted_and_required(self):
        expected = ["c++/v1/" + name for name in
                    ("__config_site", "__assertion_handler", "module.modulemap", "libcxx.imp")]
        self.assertEqual(pwc.GENERATED_HEADERS, expected)
        prefix = self.makeInstall("generated", self.source)
        self.assertIsNone(pwc.installProblem(prefix))
        self.assertIsNone(pwc.headerProblem(prefix, self.source))
        for relative in expected:
            path = os.path.join(prefix, "include", *relative.split("/"))
            data = read(path)
            os.remove(path)
            self.assertIn("include lacks " + relative, pwc.installProblem(prefix))
            write(path, data)
        write(os.path.join(prefix, "include", "c++", "v1", "module.modulemap.extra"), b"stray\n")
        self.assertIn("module.modulemap.extra is in no pinned source", pwc.headerProblem(prefix, self.source))

    def test_a_missing_archive_a_shared_or_import_library_and_any_other_library_are_refused(self):
        self.assertIn("lib lacks libunwind.a", pwc.installProblem(self.makeInstall("a", self.source, leave=["libunwind.a"])))
        for name in ("libc++.dll", "libc++.dll.a", "libc++.lib", "libunwind.so"):
            prefix = self.makeInstall("p" + name, self.source)
            write(os.path.join(prefix, "lib", name))
            self.assertIn("lib holds " + name, pwc.installProblem(prefix))

    def test_an_entry_outside_include_and_lib_a_directory_in_lib_and_a_missing_header_are_refused(self):
        prefix = self.makeInstall("a", self.source)
        write(os.path.join(prefix, "share", "libc++", "v1", "std.cppm"))
        self.assertIn("not %s" % pwc.INSTALL_ROOTS, pwc.installProblem(prefix))
        prefix = self.makeInstall("b", self.source)
        os.makedirs(os.path.join(prefix, "lib", "cmake"))
        self.assertIn("lib/cmake is not a regular file", pwc.installProblem(prefix))
        prefix = self.makeInstall("c", self.source)
        os.remove(os.path.join(prefix, "include", "libunwind.h"))
        self.assertIn("include lacks libunwind.h", pwc.installProblem(prefix))

    def test_a_name_that_would_need_quoting_is_refused(self):
        prefix = self.makeInstall("a", self.source)
        write(os.path.join(prefix, "include", "c++", "v1", "a b"))
        self.assertIn("unsupported name", pwc.installProblem(prefix))

    def test_a_link_in_the_install_is_refused_before_anything_is_opened(self):
        prefix = self.makeInstall("a", self.source)
        self.symlink(os.path.join(prefix, "include", "libunwind.h"), os.path.join(prefix, "include", "alias.h"))
        self.assertIn("is a link", pwc.installProblem(prefix))
        prefix = self.makeInstall("b", self.source)
        os.remove(os.path.join(prefix, "lib", "libc++.a"))
        self.symlink(os.path.join(prefix, "lib", "libc++abi.a"), os.path.join(prefix, "lib", "libc++.a"))
        self.assertIn("lib/libc++.a is not a regular file", pwc.installProblem(prefix))

    def test_every_header_is_a_byte_copy_of_the_pinned_source_but_the_generated_ones(self):
        prefix = self.makeInstall("a", self.source)
        write(os.path.join(prefix, "include", "c++", "v1", "__assertion_handler"), b"generated\n")
        self.assertIsNone(pwc.headerProblem(prefix, self.source))
        write(os.path.join(prefix, "include", "c++", "v1", "vector"), b"// from another cohort\n")
        self.assertIn("c++/v1/vector differs", pwc.headerProblem(prefix, self.source))

    def test_a_header_that_no_pinned_source_directory_holds_is_refused(self):
        prefix = self.makeInstall("a", self.source)
        write(os.path.join(prefix, "include", "c++", "v1", "stray"), b"x\n")
        self.assertIn("stray is in no pinned source", pwc.headerProblem(prefix, self.source))
        prefix = self.makeInstall("b", self.source)
        write(os.path.join(prefix, "include", "unwind_stray.h"), b"x\n")
        self.assertIn("unwind_stray.h is in no pinned source", pwc.headerProblem(prefix, self.source))
        prefix = self.makeInstall("c", self.source)
        write(os.path.join(prefix, "include", "unwind.h"), b"// a zig unwind.h\n")
        self.assertIn("installed header unwind.h differs", pwc.headerProblem(prefix, self.source))


class StagePayloadTest(TempCase):
    def setUp(self):
        super().setUp()
        self.source = self.makeSource()
        self.output = self.path("overlay")

    def test_the_archives_and_the_include_tree_are_copied_with_machines_hashes_and_the_config_site_facts(self):
        prefix = self.makeInstall("p", self.source)
        payload = self.stage(prefix, pw.TARGET, self.source, self.output)
        directory = os.path.join(self.output, "windows", "x86_64-windows-gnu.cxx")
        self.assertEqual(sorted(os.listdir(directory)), ["include"] + sorted(pwc.ARCHIVES))
        self.assertEqual([a["name"] for a in payload["archives"]], pwc.ARCHIVES)
        self.assertEqual({a["machine"] for a in payload["archives"]}, {"0x8664"})
        self.assertEqual((payload["threadApi"], payload["threadApiSite"]), ("WIN32", []))
        self.assertEqual(payload["leftOut"], ["libc++experimental.a"])
        self.assertEqual(payload["configSite"]["sha256"], pe.sha256File(os.path.join(
            directory, "include", "c++", "v1", "__config_site")))
        self.assertEqual(payload["archives"][0]["sha256"], pe.sha256File(os.path.join(directory, "libc++.a")))
        self.assertEqual(read(os.path.join(directory, "include", "libunwind.h")), SOURCE_FILES["libunwind/include/libunwind.h"])

    def test_arm64_archives_are_checked_against_the_arm64_machine(self):
        arm = pw.TARGETS[pw.ARM64_TARGET]["machine"]
        payload = self.stage(self.makeInstall("p", self.source, machine=arm), pw.ARM64_TARGET, self.source, self.output)
        self.assertEqual({a["machine"] for a in payload["archives"]}, {"0xaa64"})
        with self.assertRaisesRegex(pe.EngineError, "machine 0x8664, not 0xaa64"):
            self.stage(self.makeInstall("q", self.source), pw.ARM64_TARGET, self.source, self.path("other"))

    def test_a_member_of_another_machine_an_empty_archive_and_an_import_only_archive_are_refused_and_nothing_is_written(self):
        for name, body, message in (
                ("wrong", archive([("m.o", coff(0x8664)), ("n.o", coff(0xaa64))]), "0xaa64"),
                ("empty", b"!<arch>\n", "holds no member"),
                ("import", archive([("i.o", importMember(0x8664))]), "import member")):
            prefix = self.makeInstall(name, self.source)
            write(os.path.join(prefix, "lib", "libc++abi.a"), body)
            with self.assertRaisesRegex(pe.EngineError, message):
                self.stage(prefix, pw.TARGET, self.source, self.path("out-" + name))
            self.assertFalse(os.path.lexists(self.path("out-" + name)))

    def test_an_archive_without_the_needed_symbols_is_refused_naming_them(self):
        prefix = self.makeInstall("p", self.source)
        with mock.patch.object(pc, "archiveSymbols", side_effect=lambda e, p: [
                ("T", n) for n in SYMBOLS[os.path.basename(p)] if n != "__gxx_personality_seh0"]):
            with self.assertRaisesRegex(pe.EngineError, "does not define __gxx_personality_seh0"):
                pwc.stagePayload(prefix, pw.TARGET, self.source, "/engine", self.output)
        with mock.patch.object(pc, "archiveSymbols", side_effect=lambda e, p: [
                ("T", n) for n in SYMBOLS[os.path.basename(p)] if not n.startswith("_ZNSt")]):
            with self.assertRaisesRegex(pe.EngineError, "defines no libc..? symbol"):
                pwc.stagePayload(prefix, pw.TARGET, self.source, "/engine", self.output)

    def test_wrong_headers_and_a_wrong_config_site_are_refused_before_any_copy(self):
        prefix = self.makeInstall("p", self.source)
        write(os.path.join(prefix, "include", "c++", "v1", "vector"), b"// zig\n")
        with self.assertRaisesRegex(pe.EngineError, "differs from the pinned source"):
            self.stage(prefix, pw.TARGET, self.source, self.output)
        prefix = self.makeInstall("q", self.source, site=SITE.replace("PTHREAD 0", "PTHREAD 1"))
        with self.assertRaisesRegex(pe.EngineError, "selects the PTHREAD thread API"):
            self.stage(prefix, pw.TARGET, self.source, self.output)
        self.assertFalse(os.path.lexists(self.output))

    def test_the_install_check_runs_before_the_archives_are_opened(self):
        prefix = self.makeInstall("p", self.source, leave=["libc++.a"])
        with mock.patch.object(pws, "builtinsProblem") as opened:
            with self.assertRaisesRegex(pe.EngineError, "lib lacks libc\\+\\+.a"):
                self.stage(prefix, pw.TARGET, self.source, self.output)
        opened.assert_not_called()


class OverlayTest(TempCase):
    def buildOverlay(self, targets=TARGETS, site=SITE):
        source = self.makeSource()
        runtime = self.path("runtime")
        base = json.dumps(BASE_RECEIPT, sort_keys=True) + "\n"
        write(os.path.join(runtime, "windows", "notices", pws.PROVENANCE), base)
        overlay = self.path("overlay")
        os.makedirs(overlay)
        payloads = {}
        for target in targets:
            payloads[target] = self.stage(self.makeInstall("prefix-" + target, source, pw.TARGETS[target]["machine"], site),
                                          target, source, overlay)
        for target in targets:
            for variant in pws.SOURCE_VARIANTS:
                pe.writeText(os.path.join(overlay, *pwc.configPath(target, variant).split("/")),
                             pwc.renderCxxConfig(target))
        notices = pwc.copyNotices(overlay, source)
        with mock.patch.object(pws, "toolVersions", return_value={"cmake": "cmake 3"}):
            receipt = pwc.writeProvenance(overlay, "linux", "23.1.0", "23", list(targets), payloads, notices,
                                          (BASE_RECEIPT, pe.sha256File(os.path.join(
                                              runtime, "windows", "notices", pws.PROVENANCE))),
                                          source, REV, {}, ("/py", "Python 3.11.2"))
        return runtime, overlay, receipt

    def merged(self, **options):
        runtime, overlay, receipt = self.buildOverlay(**options)
        pc.mergeOverlay(overlay, runtime)
        return runtime, receipt

    def test_a_clean_runtime_has_no_collision_and_each_owned_windows_path_is_one(self):
        runtime = self.path("runtime")
        os.makedirs(os.path.join(runtime, "windows"))
        self.assertIsNone(pwc.collisionProblem(runtime, TARGETS))
        for relative in ("windows/x86_64-windows-gnu.cxx.cfg", "windows/x86_64-windows-gnu.dll.cxx.cfg",
                         "windows/aarch64-windows-gnu.dll.cxx.cfg", "windows/x86_64-windows-gnu.cxx",
                         "windows/aarch64-windows-gnu.cxx", pwc.PROVENANCE, pwc.NOTICE_DIRECTORY):
            path = os.path.join(runtime, *relative.split("/"))
            if relative.endswith(("cxx", "windows-source-cpp")):
                os.makedirs(path)
            else:
                write(path)
            self.assertIn(relative, pwc.collisionProblem(runtime, TARGETS))
            if os.path.isdir(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
        self.assertIsNone(pwc.collisionProblem(runtime, TARGETS))

    def test_the_zig_cohorts_of_other_paths_are_no_collision_and_one_target_of_a_two_target_runtime_is_refused_alone(self):
        runtime = self.path("runtime")
        for relative, data in FOREIGN.items():
            write(os.path.join(runtime, *relative.split("/")), data)
        self.assertIsNone(pwc.collisionProblem(runtime, TARGETS))
        write(os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx", "libc++.a"))
        self.assertIn("windows/x86_64-windows-gnu.cxx", pwc.collisionProblem(runtime, TARGETS))
        self.assertIn("windows/x86_64-windows-gnu.cxx", pwc.collisionProblem(runtime, [pw.TARGET]))
        self.assertIsNone(pwc.collisionProblem(runtime, [pw.ARM64_TARGET]))

    def test_the_overlay_merges_beside_the_zig_cohorts_other_platforms_and_shared_headers_leaving_every_byte_of_them(self):
        runtime, overlay, receipt = self.buildOverlay()
        for relative, data in FOREIGN.items():
            write(os.path.join(runtime, *relative.split("/")), data)
        self.assertIsNone(pwc.collisionProblem(runtime, TARGETS))
        pc.mergeOverlay(overlay, runtime)
        self.assertEqual(snapshot(runtime), FOREIGN)
        self.assertIsNone(pwc.receiptProblem(receipt, runtime))
        self.assertEqual([r["path"] for r in receipt["files"] if r["path"] in FOREIGN], [])
        self.assertTrue(os.path.isfile(os.path.join(runtime, *pwc.PROVENANCE.split("/"))))
        self.assertEqual(read(os.path.join(runtime, "notices", "cpp-provenance.json")), FOREIGN["notices/cpp-provenance.json"])

    def test_a_receipt_describes_its_overlay_and_lists_every_owned_file_with_its_hash(self):
        runtime, receipt = self.merged()
        self.assertIsNone(pwc.receiptProblem(receipt, runtime))
        paths = [r["path"] for r in receipt["files"]]
        self.assertEqual(paths, sorted(paths))
        self.assertIn("windows/x86_64-windows-gnu.cxx/libc++.a", paths)
        self.assertIn("windows/aarch64-windows-gnu.dll.cxx.cfg", paths)
        self.assertIn("notices/windows-source-cpp/libcxx/LICENSE.TXT", paths)
        self.assertNotIn(pwc.PROVENANCE, paths)
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual(receipt["base"]["path"], "windows/notices/windows-provenance.json")
        self.assertEqual(receipt["kind"], "source-built-windows-cpp-runtime")
        self.assertEqual(receipt["payloads"][pw.TARGET]["configSite"]["defines"]["__USE_MINGW_ANSI_STDIO"], "1")

    def test_one_target_alone_leaves_the_other_target_out(self):
        runtime, receipt = self.merged(targets=[pw.ARM64_TARGET])
        self.assertIsNone(pwc.receiptProblem(receipt, runtime))
        self.assertFalse(os.path.lexists(os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx")))
        self.assertEqual([v["variant"] for v in receipt["variants"]], ["exe", "dll"])

    def test_the_overlay_merges_into_a_runtime_that_has_none_of_its_paths_and_only_once(self):
        runtime, overlay, _ = self.buildOverlay()
        pc.mergeOverlay(overlay, runtime)
        with self.assertRaisesRegex(pe.EngineError, "already has"):
            pc.mergeOverlay(overlay, runtime)

    def test_a_changed_archive_an_unlisted_file_and_a_removed_file_are_refused(self):
        runtime, receipt = self.merged()
        archivePath = os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx", "libc++.a")
        original = read(archivePath)
        write(archivePath, original + b"\0")
        self.assertIn("libc++.a does not match the receipt", pwc.receiptProblem(receipt, runtime))
        write(archivePath, original)
        write(os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx", "libextra.a"))
        self.assertIn("libextra.a", pwc.receiptProblem(receipt, runtime))
        os.remove(os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx", "libextra.a"))
        os.remove(archivePath)
        self.assertIn("libc++.a", pwc.receiptProblem(receipt, runtime))

    def test_a_link_in_an_owned_path_is_refused_whatever_it_points_to(self):
        runtime, receipt = self.merged()
        victim = os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx", "libc++abi.a")
        copy = read(victim)
        os.remove(victim)
        write(self.path("elsewhere.a"), copy)
        self.symlink(self.path("elsewhere.a"), victim)
        self.assertIn("is a link", pwc.receiptProblem(receipt, runtime))

    def test_a_changed_c_runtime_receipt_a_wrong_kind_and_a_file_outside_the_owned_paths_are_refused(self):
        runtime, receipt = self.merged()
        base = os.path.join(runtime, "windows", "notices", pws.PROVENANCE)
        original = read(base)
        write(base, original + b" ")
        self.assertIn("not the one this overlay was built on", pwc.receiptProblem(receipt, runtime))
        write(base, original)
        self.assertIn("not 'source-built-windows-cpp-runtime'", pwc.receiptProblem(dict(receipt, kind="local-zig-cpp-runtime-proof"), runtime))
        outside = dict(receipt, files=receipt["files"] + [{"path": "windows/x86_64-windows-gnu/crt2.o", "sha256": "0"}])
        self.assertIn("outside the paths the overlay owns", pwc.receiptProblem(outside, runtime))

    def test_a_receipt_that_records_another_thread_api_than_the_effective_win32_one_is_refused(self):
        runtime, receipt = self.merged()
        for change in ({"threadApi": "PTHREAD"}, {"threadApiSite": ["PTHREAD"]},
                       {"threadApiSite": ["WIN32", "PTHREAD"]}):
            payloads = {t: dict(p, **change) for t, p in receipt["payloads"].items()}
            self.assertIn("records the thread API", pwc.receiptProblem(dict(receipt, payloads=payloads), runtime))
        self.assertEqual([p["threadApiSite"] for p in receipt["payloads"].values()], [[], []])

    def test_a_config_that_is_not_the_producers_is_refused(self):
        runtime, receipt = self.merged()
        config = os.path.join(runtime, "windows", "x86_64-windows-gnu.cxx.cfg")
        original = read(config)
        for extra in (b"-lstdc++\n", b"--unwindlib=libunwind\n"):
            write(config, original + extra)
            self.assertIn("does not match the receipt", pwc.receiptProblem(receipt, runtime))
        forged = dict(receipt, files=[dict(r, sha256=pe.sha256File(config)) if r["path"].endswith("x86_64-windows-gnu.cxx.cfg")
                                      else r for r in receipt["files"]])
        self.assertIn("is not the config this producer writes", pwc.receiptProblem(forged, runtime))

    def test_missing_duplicated_or_unknown_targets_and_variants_are_refused(self):
        runtime, receipt = self.merged()
        self.assertIn("not distinct", pwc.receiptProblem(dict(receipt, targets=[pw.TARGET, pw.TARGET]), runtime))
        self.assertIn("not distinct", pwc.receiptProblem(dict(receipt, targets=["x86_64-linux-gnu.2.31"]), runtime))
        self.assertIn("variants are not exactly", pwc.receiptProblem(dict(receipt, variants=receipt["variants"][1:]), runtime))
        self.assertIn("engineRelative", pwc.receiptProblem(dict(receipt, engineRelative="../engine"), runtime))


class BaseReceiptTest(TempCase):
    def runtime(self, receipt):
        runtime = self.path("runtime")
        write(os.path.join(runtime, "windows", "notices", pws.PROVENANCE), json.dumps(receipt))
        return runtime

    def test_the_zig_runtime_receipt_and_a_missing_target_are_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "not the source-built C runtime"):
            pwc.baseReceipt(self.runtime(dict(BASE_RECEIPT, kind="zig-built-windows-runtime")), TARGETS)
        with self.assertRaisesRegex(pe.EngineError, "has no aarch64-windows-gnu"):
            pwc.baseReceipt(self.runtime(dict(BASE_RECEIPT, targets=[pw.TARGET])), TARGETS)

    def test_a_link_or_a_missing_receipt_is_refused_before_it_is_read(self):
        with self.assertRaisesRegex(pe.EngineError, "is missing"):
            pwc.baseReceipt(self.path("nowhere"), TARGETS)
        runtime = self.path("linked")
        os.makedirs(os.path.join(runtime, "windows", "notices"))
        write(self.path("real.json"), json.dumps(BASE_RECEIPT))
        self.symlink(self.path("real.json"), os.path.join(runtime, "windows", "notices", pws.PROVENANCE))
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            pwc.baseReceipt(runtime, TARGETS)

    def test_the_c_receipt_must_describe_the_files_under_windows(self):
        runtime = self.runtime(BASE_RECEIPT)
        with mock.patch.object(pws, "receiptProblem", return_value="x does not match the receipt"):
            with self.assertRaisesRegex(pe.EngineError, "does not match the receipt"):
                pwc.baseReceipt(runtime, TARGETS)
        with mock.patch.object(pws, "receiptProblem", return_value=None) as checked:
            self.assertEqual(pwc.baseReceipt(runtime, TARGETS)[0], BASE_RECEIPT)
        checked.assert_called_once_with(BASE_RECEIPT, os.path.join(runtime, "windows"))


class SelectionTest(unittest.TestCase):
    RUNTIME = os.path.normpath("/w/stage/runtime")

    def plan(self, target=pw.TARGET, variant="exe", kind="cxx", pthread=False, drop=(), add=(), startup=None,
             payload=None, builtins=None):
        directory = "%s/windows/%s" % (self.RUNTIME, pws.variantDirectory(target, variant))
        arch = pws.SOURCE_TARGETS[target]["builtins"]
        words = ["/w/stage/bin/ld.lld", "-L", payload or "%s/windows/%s.cxx" % (self.RUNTIME, target),
                 "%s/%s" % (directory, startup or pws.SOURCE_VARIANTS[variant]["startup"]),
                 directory + "/crtbegin.o", "x.o", "-lc++"] + (["-lc++"] if kind == "cxx" else []) + [
                     "-lmingw32", builtins or "/w/stage/lib/clang/23/lib/windows/libclang_rt.builtins-%s.a" % arch,
                     "-lunwind", "-lmoldname", "-lmingwex", "-lmsvcrt", "-ladvapi32", "-lshell32", "-luser32",
                     "-lkernel32"] + (["-lpthread"] if pthread else []) + [directory + "/crtend.o"]
        words = [w for w in words if w not in drop] + list(add)
        return "clang version 23.1.0\nTarget: x\n" + " ".join('"%s"' % w for w in words) + "\n"

    def check(self, plan, target=pw.TARGET, variant="exe", kind="cxx"):
        return pwc.selectionProblem(plan, self.RUNTIME, target, variant, kind)

    def test_a_driver_plan_of_each_target_variant_and_kind_is_accepted(self):
        for target in TARGETS:
            for variant in ("exe", "dll"):
                self.assertIsNone(self.check(self.plan(target, variant), target, variant), (target, variant))
            self.assertIsNone(self.check(self.plan(target, kind="client"), target, kind="client"))

    def test_the_unwinder_must_be_linked_once_and_after_libcxx(self):
        self.assertIn("0 -lunwind", self.check(self.plan(drop=["-lunwind"])))
        self.assertIn("2 -lunwind", self.check(self.plan(add=["-lunwind"])))
        reordered = self.plan().replace('"-lc++" "-lc++" "-lmingw32"', '"-lmingw32"').replace(
            '"-lkernel32"', '"-lkernel32" "-lc++"')
        self.assertIn("before -lc++", self.check(reordered))

    def test_a_c_client_link_has_exactly_one_libcxx_and_a_cxx_link_at_least_one(self):
        self.assertIn("2 -lc++", self.check(self.plan(kind="cxx"), kind="client"))
        self.assertIn("0 -lc++", self.check(self.plan(drop=["-lc++"])))

    def test_libgcc_and_libstdcxx_are_refused(self):
        for library in ("-lgcc", "-lgcc_eh", "-lgcc_s", "-lstdc++", "-lsupc++"):
            self.assertIn(library, self.check(self.plan(add=[library])))

    def test_the_startup_object_the_payload_search_path_and_the_builtins_must_be_the_runtimes(self):
        self.assertIn("startup objects", self.check(self.plan(startup="dllcrt2.o")))
        self.assertIn("does not search the payload", self.check(self.plan(payload="/usr/lib/x")))
        self.assertIn("builtins", self.check(self.plan(builtins="/usr/lib/clang/23/lib/windows/libclang_rt.builtins-x86_64.a")))
        self.assertIn("lacks", self.check(self.plan(drop=["-lmingwex"])))

    def test_pthread_is_never_linked_because_the_thread_api_is_win32(self):
        for target in TARGETS:
            for kind in ("cxx", "client"):
                self.assertIn("-lpthread", self.check(self.plan(target, kind=kind, pthread=True), target, kind=kind))

    def test_a_plan_without_exactly_one_linker_line_or_a_compiler_version_is_refused(self):
        self.assertIn("0 ld.lld", self.check("clang version 23.1.0\n"))
        self.assertIn("2 ld.lld", self.check(self.plan() + self.plan()))
        self.assertIn("no compiler version", self.check(self.plan().replace("clang version 23.1.0\n", "")))


class HeadersTest(unittest.TestCase):
    ROOT = os.path.normpath("/w/stage")

    def listing(self, *paths):
        return "".join(". %s\n" % p for p in paths) + "Multiple include guards may be useful for:\n"

    def test_staged_libcxx_and_mingw_headers_are_accepted(self):
        text = self.listing("/w/stage/runtime/windows/x86_64-windows-gnu.cxx/include/c++/v1/vector",
                            "/w/stage/runtime/windows/../../lib/clang/23/include/stddef.h",
                            "/w/stage/runtime/include/libc/mingw-w64/stdio.h")
        self.assertIsNone(pwc.headersProblem(text, self.ROOT))

    def test_a_header_outside_the_staged_tree_or_from_the_zig_cohort_is_refused(self):
        base = "/w/stage/runtime/windows/x.cxx/include/c++/v1/vector"
        self.assertIn("outside", pwc.headersProblem(self.listing(base, "/usr/include/stdio.h"), self.ROOT))
        self.assertIn("include/cxx", pwc.headersProblem(self.listing(base, "/w/stage/runtime/include/cxx/libcxx/vector"), self.ROOT))

    def test_an_empty_listing_and_one_without_a_libcxx_header_are_refused(self):
        self.assertIn("no header", pwc.headersProblem("", self.ROOT))
        self.assertIn("c++/v1", pwc.headersProblem(self.listing("/w/stage/runtime/include/libc/mingw-w64/stdio.h"), self.ROOT))

    def entries(self, target, public=True):
        root = "$ROOT/runtime/windows/%s.cxx/include" % target
        return [root + "/c++/v1", "$ROOT/lib/clang/23/include", "$ROOT/runtime/include/libc/mingw-w64"] + (
            [root] if public else [])

    def test_cpp_include_queries_use_the_hosts_null_device(self):
        flags = '"-cc1" ' + " ".join('"%s"' % flag for flag in pwc.EXCEPTION_DEFAULTS)
        with mock.patch.object(pc, "step", return_value=mock.Mock(stderr=flags)) as step, \
                mock.patch.object(pc, "searchList", return_value=[]), \
                mock.patch.object(pwc, "includeOrderProblem", return_value=None), \
                mock.patch.object(pwc, "publicHeadersProblem", return_value=None), \
                mock.patch.object(pwc, "headersProblem", return_value=None), \
                mock.patch.object(os, "devnull", "host-empty-input"):
            for target in TARGETS:
                pwc.checkCompile(None, "/stage", "/work", target)
        queries = [call.args[2] for call in step.call_args_list if "-E" in call.args[2]]
        self.assertEqual(len(queries), 2 * len(TARGETS))
        self.assertTrue(all(command[-1] == "host-empty-input" for command in queries))

    def test_the_include_order_has_libcxx_first_and_the_install_include_root_last_once_for_each_target(self):
        for target in TARGETS:
            self.assertIsNone(pwc.includeOrderProblem(self.entries(target), target))
            self.assertIn("does not end with the public header directory",
                          pwc.includeOrderProblem(self.entries(target, public=False), target))
            early = self.entries(target)
            early.insert(1, early.pop())
            self.assertIn("does not end with", pwc.includeOrderProblem(early, target))
            self.assertIn("once", pwc.includeOrderProblem(self.entries(target) + self.entries(target)[-1:], target))
            self.assertIn("first", pwc.includeOrderProblem(self.entries(target)[1:], target))
        other = self.entries(pw.ARM64_TARGET)
        self.assertIn("does not put", pwc.includeOrderProblem(other, pw.TARGET))
        zig = self.entries(pw.TARGET)
        zig.insert(1, "/usr/include")
        self.assertIn("only staged paths", pwc.includeOrderProblem(zig, pw.TARGET))

    def test_the_public_unwind_listing_must_name_the_install_libunwind_h_inside_the_staged_tree_and_no_include_cxx(self):
        install = "/w/stage/runtime/windows/x86_64-windows-gnu.cxx/include"
        base = [install + "/c++/v1/cstdio", install + "/libunwind.h"]
        self.assertIsNone(pwc.publicHeadersProblem(self.listing(*base), self.ROOT, pw.TARGET))
        self.assertIn("libunwind.h did not come from", pwc.publicHeadersProblem(self.listing(base[0]), self.ROOT, pw.TARGET))
        self.assertIn("libunwind.h did not come from", pwc.publicHeadersProblem(
            self.listing(base[0], "/w/stage/runtime/windows/aarch64-windows-gnu.cxx/include/libunwind.h"), self.ROOT, pw.TARGET))
        self.assertIn("include/cxx", pwc.publicHeadersProblem(
            self.listing(*base, "/w/stage/runtime/include/cxx/libunwind/libunwind.h"), self.ROOT, pw.TARGET))
        self.assertIn("outside", pwc.publicHeadersProblem(self.listing(*base, "/usr/include/unwind.h"), self.ROOT, pw.TARGET))


class PeTest(unittest.TestCase):
    def info(self, machine=0x8664, dll=False, imports=None, exports=None):
        return {"machine": machine, "subsystem": 3, "characteristics": 0x2000 if dll else 0,
                "imports": {n: [] for n in imports or ["kernel32.dll", "api-ms-win-crt-stdio-l1-1-0.dll"]},
                "exports": exports or []}

    def test_a_static_ucrt_executable_and_dll_of_each_machine_are_accepted(self):
        self.assertIsNone(pwc.peProblem("exe", self.info(), pw.TARGET, 24))
        self.assertIsNone(pwc.peProblem("exe", self.info(0xaa64), pw.ARM64_TARGET, 24))
        self.assertIsNone(pwc.peProblem("dll", self.info(dll=True, exports=["cppProbe"]), pw.TARGET, 24))
        self.assertIsNone(pwc.peProblem("exe", self.info(imports=["kernel32.dll", "ntdll.dll", "API-MS-WIN-CRT-MATH-L1-1-0.DLL",
                                                                   "api-ms-win-core-synch-l1-2-0.dll"]), pw.TARGET, 24))

    def test_a_cxx_runtime_dll_the_old_msvcrt_or_winpthreads_import_is_refused(self):
        for name in ("libc++.dll", "libunwind.dll", "libwinpthread-1.dll", "msvcrt.dll", "libstdc++-6.dll"):
            problem = pwc.peProblem("exe", self.info(imports=["kernel32.dll", "api-ms-win-crt-stdio-l1-1-0.dll", name]),
                                    pw.TARGET, 24)
            self.assertIn(name, problem)

    def test_a_missing_ucrt_wrong_machine_missing_export_or_exception_table_is_refused(self):
        self.assertIn("UCRT", pwc.peProblem("exe", self.info(imports=["kernel32.dll"]), pw.TARGET, 24))
        self.assertIn("machine", pwc.peProblem("exe", self.info(0xaa64), pw.TARGET, 24))
        self.assertIn("machine", pwc.peProblem("exe", self.info(), pw.ARM64_TARGET, 24))
        self.assertIn("cppProbe", pwc.peProblem("dll", self.info(dll=True), pw.TARGET, 24))
        self.assertIn("characteristics", pwc.peProblem("dll", self.info(), pw.TARGET, 24))
        self.assertIn("exception table", pwc.peProblem("exe", self.info(), pw.TARGET, 0))

    def test_the_exception_directory_size_is_read_from_the_third_data_directory(self):
        base = 0x80
        data = bytearray(0x400)
        struct.pack_into("<I", data, 0x3c, base)
        struct.pack_into("<II", data, base + 24 + 112 + 24, 0x2000, 0x30)
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "x.exe")
            write(path, bytes(data))
            self.assertEqual(pwc.exceptionTableSize(path), 0x30)


class StepsTest(unittest.TestCase):
    def steps(self, target):
        return pwc.cxxSteps("/w/stage", "/w/work", target)

    def test_every_proof_links_plain_thin_and_full_through_the_pair_with_the_cxx_config_first(self):
        for target in TARGETS:
            steps, outputs, bitcode, plans = self.steps(target)
            self.assertEqual(len(steps), 2 * 3 * len(pwc.PROOFS))
            self.assertEqual(sorted(outputs), sorted((n, m) for n in pwc.PROOFS for m in ("plain", "thin", "full")))
            self.assertEqual(len(bitcode), 2 * len(pwc.PROOFS))
            for name, command in steps:
                configs = [w for w in command if w.startswith("--config=")]
                self.assertEqual([os.path.basename(c) for c in configs],
                                 [os.path.basename(pwc.configPath(target, pwc.PROOFS[name.split()[0]]["variant"])),
                                  os.path.basename(pwc.baseConfigPath(target, pwc.PROOFS[name.split()[0]]["variant"]))])
                self.assertEqual(command[0], os.path.join("/w/stage", "bin", "clang++"))
                self.assertEqual(command[1], "--no-default-config")

    def test_lto_flags_go_on_both_compile_and_link_and_shared_only_on_the_dll_link_and_plan(self):
        steps, _, _, plans = self.steps(pw.TARGET)
        commands = dict(steps)
        for mode, flag in (("thin", "-flto=thin"), ("full", "-flto=full")):
            self.assertIn(flag, commands["exe %s compile" % mode])
            self.assertIn(flag, commands["exe %s link" % mode])
        self.assertNotIn("-flto=thin", commands["exe plain link"])
        self.assertIn("-shared", commands["dll plain link"])
        self.assertNotIn("-shared", commands["dll plain compile"])
        self.assertNotIn("-shared", commands["exe plain link"])
        self.assertEqual([p[0] for p in plans], ["exe plan", "dll plan", "unwind plan"])
        self.assertIn("-shared", dict((n, c) for n, c, _ in plans)["dll plan"])
        self.assertTrue(all("-###" in c for _, c, _ in plans))

    def test_no_proof_step_or_plan_names_an_include_directory_so_the_pair_alone_reaches_every_public_header(self):
        for target in TARGETS:
            steps, _, _, plans = self.steps(target)
            for name, command in steps + [(n, c) for n, c, _ in plans]:
                for word in command:
                    self.assertFalse(word in ("-I", "-isystem", "-idirafter", "-iquote", "-include", "--sysroot")
                                     or word.startswith(("-I", "-isystem", "-idirafter", "-iquote")), (name, word))

    def test_the_unwind_fixture_includes_the_public_libunwind_and_unwind_headers_by_name_only(self):
        with open(os.path.join(pr.FIXTURES, pwc.PROOFS["unwind"]["fixture"]), encoding="utf-8") as f:
            text = f.read()
        for needle in ("#include <libunwind.h>", "#include <unwind.h>", "unw_getcontext", "_Unwind_Backtrace"):
            self.assertIn(needle, text)
        self.assertNotIn("..", text)

    def test_every_fixture_the_proofs_name_exists_and_states_what_it_proves(self):
        names = [p["fixture"] for p in pwc.PROOFS.values()] + [
            "windowsSourceCppAbi.cpp", "windowsSourceCppArchive.cpp", "windowsSourceCppClient.c",
            "windowsSourceCppControl.c"]
        for name in names:
            self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, name)), name)
        with open(os.path.join(pr.FIXTURES, "windowsSourceCppMain.cpp"), encoding="utf-8") as f:
            main = f.read()
        for needle in ("std::thread", "throw ", "~Tracker", "%Le", "long double", "std::vector"):
            self.assertIn(needle, main)
        for target in TARGETS:
            self.assertIn("long double size=", pwc.EXPECTED_MAIN[target])
        self.assertNotEqual(pwc.EXPECTED_MAIN[pw.TARGET], pwc.EXPECTED_MAIN[pw.ARM64_TARGET])


class ControlTreeTest(TempCase):
    def test_c_control_queries_use_the_hosts_null_device_for_both_variants_and_cpus(self):
        commands = []

        def step(run, name, command, stderr=False):
            commands.append(command)
            if "-o" in command:
                write(command[command.index("-o") + 1], "output\n")
            return mock.Mock(stderr="")

        with mock.patch.object(pc, "step", side_effect=step), \
                mock.patch.object(pc, "searchList", return_value=[]), \
                mock.patch.object(os, "devnull", "host-empty-input"):
            for target in TARGETS:
                for variant in pws.SOURCE_VARIANTS:
                    pwc.controlResults(None, self.path("stage"), self.dir, target, variant)
        queries = [command for command in commands if "-E" in command]
        self.assertEqual(len(queries), len(TARGETS) * len(pws.SOURCE_VARIANTS))
        self.assertTrue(all(command[-1] == "host-empty-input" for command in queries))

    def test_the_control_tree_has_the_runtime_without_the_overlay_and_the_engine_entries_as_links(self):
        stage = self.path("stage")
        write(os.path.join(stage, "bin", "clang"))
        write(os.path.join(stage, "lib", "clang", "23", "include", "stddef.h"))
        write(os.path.join(stage, "runtime", "windows", "x86_64-windows-gnu.cfg"))
        write(os.path.join(stage, "runtime", "windows", "x86_64-windows-gnu.cxx.cfg"))
        write(os.path.join(stage, "runtime", "windows", "x86_64-windows-gnu.cxx", "libc++.a"))
        write(os.path.join(stage, "runtime", "windows", "x86_64-windows-gnu.cxx", "libunwind.a"))
        try:
            control = pwc.makeControl(stage, self.dir, ["windows/x86_64-windows-gnu.cxx.cfg",
                                                       "windows/x86_64-windows-gnu.cxx/libc++.a", "windows/nothing.cfg"])
        except OSError:
            self.skipTest("this host cannot create a symlink")
        runtime = os.path.join(control, "runtime", "windows")
        self.assertTrue(os.path.isfile(os.path.join(runtime, "x86_64-windows-gnu.cfg")))
        self.assertFalse(os.path.lexists(os.path.join(runtime, "x86_64-windows-gnu.cxx.cfg")))
        self.assertFalse(os.path.lexists(os.path.join(runtime, "x86_64-windows-gnu.cxx", "libc++.a")))
        self.assertTrue(os.path.isfile(os.path.join(runtime, "x86_64-windows-gnu.cxx", "libunwind.a")))
        self.assertTrue(os.path.isfile(os.path.join(control, "bin", "clang")))
        self.assertTrue(os.path.isfile(os.path.join(stage, "runtime", "windows", "x86_64-windows-gnu.cxx.cfg")))


class PrepareTest(TempCase):
    def setUp(self):
        super().setUp()
        self.runtime = self.path("runtime")
        self.output = self.path("out", "overlay")
        write(os.path.join(self.runtime, "windows", "notices", pws.PROVENANCE), json.dumps(BASE_RECEIPT))
        self.stageRoots = []

        def stageTree(engine, windows, root, major):
            self.stageRoots.append(root)
            os.makedirs(os.path.join(root, "runtime"))

        patches = [mock.patch.object(pr, "engineMajor", return_value=("linux", "23.1.0", "23")),
                   mock.patch.object(pws, "engineTool", side_effect=lambda e, n: "/e/bin/" + n),
                   mock.patch.object(pws, "checkSourceRoot", return_value=self.path("llvm")),
                   mock.patch.object(pws, "checkLlvmVersion"),
                   mock.patch.object(pws, "checkPlainPath", side_effect=lambda path, what: path),
                   mock.patch.object(pwc, "baseReceipt", return_value=(BASE_RECEIPT, "digest")),
                   mock.patch.object(pws, "stageTree", side_effect=stageTree)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def run_(self, **options):
        return pwc.prepareWindowsSourceCppRuntime(self.path("engine"), self.runtime, self.output, self.path("llvm"), REV,
                                                  {"cmake": "/t/cmake", "make": "/t/make"}, ("/py", "Python 3.11"), **options)

    def leftovers(self):
        parent = os.path.dirname(self.output)
        return os.listdir(parent) if os.path.isdir(parent) else []

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

    def test_an_existing_output_is_never_replaced_and_nothing_is_staged(self):
        write(self.output + "/keep")
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            self.run_()
        self.assertEqual(read(self.output + "/keep"), b"x\n")
        self.assertEqual(self.stageRoots, [])

    def test_the_zig_windows_cohort_and_an_earlier_overlay_are_refused_before_any_work(self):
        for relative in ("windows/x86_64-windows-gnu.cxx.cfg", "windows/x86_64-windows-gnu.cxx/libc++.a",
                         "windows/aarch64-windows-gnu.dll.cxx.cfg", pwc.PROVENANCE):
            write(os.path.join(self.runtime, *relative.split("/")))
            with self.assertRaisesRegex(pe.EngineError, "exclude each other"):
                self.run_()
            os.remove(os.path.join(self.runtime, *relative.split("/")))
        self.assertEqual((self.stageRoots, self.leftovers()), ([], []))

    def test_a_c_runtime_built_from_another_llvm_commit_is_refused(self):
        other = json.loads(json.dumps(BASE_RECEIPT))
        other["sources"]["llvm-project"]["rev"] = "1" * 40
        with mock.patch.object(pwc, "baseReceipt", return_value=(other, "digest")):
            with self.assertRaisesRegex(pe.EngineError, "built from llvm-project"):
                self.run_()
        self.assertEqual(self.stageRoots, [])

    def test_a_failed_build_leaves_no_output_no_partial_directory_and_no_work_directory(self):
        with mock.patch.object(pwc, "buildRuntimes", side_effect=pe.EngineError("boom")):
            with self.assertRaisesRegex(pe.EngineError, "boom"):
                self.run_()
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(self.leftovers(), [])
        self.assertFalse(os.path.lexists(os.path.dirname(self.stageRoots[0])))

    def test_an_input_runtime_that_changed_during_the_build_is_refused_and_nothing_is_published(self):
        def mutate(*arguments, **options):
            write(os.path.join(self.runtime, "stray"))

        def stagePayload(prefix, target, llvm, engine, output):
            os.makedirs(os.path.join(output, "windows"), exist_ok=True)
            return {"threadApi": "WIN32"}

        with mock.patch.object(pwc, "buildRuntimes", return_value="/p"), \
                mock.patch.object(pwc, "stagePayload", side_effect=stagePayload), \
                mock.patch.object(pwc, "copyNotices", return_value=[]), \
                mock.patch.object(pwc, "writeProvenance", return_value={"targets": TARGETS}), \
                mock.patch.object(pwc, "makeControl", return_value="/c"), \
                mock.patch.object(pc, "mergeOverlay"), \
                mock.patch.object(pwc, "checkRuntime", side_effect=mutate):
            with self.assertRaisesRegex(pe.EngineError, "changed during the build"):
                self.run_()
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(self.leftovers(), [])

    def runFinished(self, checked):
        def stagePayload(prefix, target, llvm, engine, output):
            os.makedirs(os.path.join(output, "windows"), exist_ok=True)
            return {"threadApi": "WIN32"}

        with mock.patch.object(pwc, "buildRuntimes", return_value="/p"), \
                mock.patch.object(pwc, "stagePayload", side_effect=stagePayload), \
                mock.patch.object(pwc, "copyNotices", return_value=[]), \
                mock.patch.object(pwc, "writeProvenance", return_value={"targets": TARGETS}), \
                mock.patch.object(pwc, "makeControl", return_value="/c"), \
                mock.patch.object(pc, "mergeOverlay"), \
                mock.patch.object(pwc, "checkRuntime", side_effect=lambda *a, **k: checked.append(a)):
            return self.run_()

    def test_a_runtime_with_the_zig_other_platforms_shared_headers_and_common_receipt_is_built_on_and_left_byte_identical(self):
        for relative, data in FOREIGN.items():
            write(os.path.join(self.runtime, *relative.split("/")), data)
        before = pc.treeDigest(self.runtime)
        checked = []
        output, receipt = self.runFinished(checked)
        self.assertEqual(output, self.output)
        self.assertEqual(len(checked), 1)
        self.assertEqual(snapshot(self.runtime), FOREIGN)
        self.assertEqual(pc.treeDigest(self.runtime), before)
        self.assertEqual([p for p in pc.overlayFiles(self.output) if p in FOREIGN], [])

    def test_a_finished_run_publishes_the_configs_of_every_target_variant_in_one_rename(self):
        checked = []
        output, receipt = self.runFinished(checked)
        self.assertEqual(output, self.output)
        self.assertEqual(self.leftovers(), ["overlay"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.output, "windows"))), sorted(
            os.path.basename(pwc.configPath(t, v)) for t in TARGETS for v in pws.SOURCE_VARIANTS))
        self.assertEqual(read(os.path.join(self.output, "windows", "x86_64-windows-gnu.dll.cxx.cfg")).decode(),
                         pwc.renderCxxConfig(pw.TARGET))
        self.assertEqual(len(checked), 1)


class CommandLineTest(unittest.TestCase):
    def main(self, *argv):
        error = io.StringIO()
        with contextlib.redirect_stderr(error), contextlib.redirect_stdout(io.StringIO()):
            try:
                code = pwc.main(["--engine", "/e", "--runtime", "/r"] + list(argv))
            except SystemExit as exit_:
                code = exit_.code
        return code, error.getvalue()

    def test_build_only_options_are_refused_with_prove(self):
        for option in (["--output", "/o"], ["--llvm-project", "/l"], ["--llvm-project-rev", REV], ["--cmake", "/c"],
                       ["--ninja", "/n"], ["--make", "/m"], ["--python3", "/p"], ["--jobs", "2"],
                       ["--target", pw.TARGET]):
            code, text = self.main("--prove", *option)
            self.assertEqual(code, 2, option)
            self.assertIn("go with the build, not --prove", text)

    def test_prove_only_options_are_refused_without_prove(self):
        for option in (["--execute"], ["--deny", "/d"]):
            code, text = self.main("--output", "/o", "--llvm-project", "/l", *option)
            self.assertEqual(code, 2, option)
            self.assertIn("only go with --prove", text)

    def test_a_build_needs_an_output_and_a_checkout(self):
        code, text = self.main("--output", "/o")
        self.assertEqual(code, 2)
        self.assertIn("--llvm-project required", text)
        self.assertEqual(self.main("--llvm-project", "/l")[0], 2)

    def test_deny_is_refused_where_no_sandbox_enforces_it(self):
        with mock.patch.object(sys, "platform", "linux"):
            code, text = self.main("--prove", "--deny", "/d")
        self.assertEqual(code, 1)
        self.assertIn("--deny is enforced by the macOS sandbox only", text)

    def test_execute_needs_a_target_this_host_can_run(self):
        runtimeReceipt = {"targets": TARGETS, "sources": {"llvm-project": {"major": "23"}}}
        with mock.patch.object(pwc, "readJson", return_value=(runtimeReceipt, "d")), \
                mock.patch.object(pwc, "receiptProblem", return_value=None), \
                mock.patch.object(pwc, "baseReceipt", return_value=({"sources": {"llvm-project": {"major": "23"}}}, "d")), \
                mock.patch.object(pe, "verifyEngine"), \
                mock.patch.object(pr, "engineMajor", return_value=("linux", "23.1.0", "23")), \
                mock.patch.object(pws, "canExecute", return_value=False):
            code, text = self.main("--prove", "--execute")
        self.assertEqual(code, 1)
        self.assertIn("cannot run any target", text)


@unittest.skipUnless(os.environ.get("MSC_WINDOWS_SOURCE_CPP_ENGINE") and os.environ.get("MSC_WINDOWS_SOURCE_CPP_RUNTIME")
                     and os.environ.get("MSC_WINDOWS_SOURCE_CPP_LLVM"),
                     "needs MSC_WINDOWS_SOURCE_CPP_ENGINE, _RUNTIME (a source-built C runtime) and _LLVM (the pinned checkout)")
class RealBuildTest(TempCase):
    def test_both_targets_build_prove_and_publish_on_the_staged_engine(self):
        output = self.path("overlay")
        self.assertEqual(pwc.main(["--engine", os.environ["MSC_WINDOWS_SOURCE_CPP_ENGINE"], "--runtime",
                                   os.environ["MSC_WINDOWS_SOURCE_CPP_RUNTIME"], "--output", output,
                                   "--llvm-project", os.environ["MSC_WINDOWS_SOURCE_CPP_LLVM"]]), 0)
        with open(os.path.join(output, *pwc.PROVENANCE.split("/")), encoding="utf-8") as f:
            receipt = json.load(f)
        self.assertEqual(sorted(receipt["targets"]), sorted(TARGETS))
        merged = self.path("merged")
        shutil.copytree(os.environ["MSC_WINDOWS_SOURCE_CPP_RUNTIME"], merged, symlinks=True)
        for relative, data in FOREIGN.items():
            write(os.path.join(merged, *relative.split("/")), data)
        pc.mergeOverlay(output, merged)
        self.assertIsNone(pwc.receiptProblem(receipt, merged))
        self.assertEqual(pwc.main(["--prove", "--engine", os.environ["MSC_WINDOWS_SOURCE_CPP_ENGINE"], "--runtime", merged]), 0)
        self.assertEqual(snapshot(merged), FOREIGN)


if __name__ == "__main__":
    unittest.main()
