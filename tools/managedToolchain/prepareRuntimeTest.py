import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareRuntime as pr

WASI_COMPILE = ("/z/zig clang /fx/runtimeWasi.c --no-default-config -target wasm32-unknown-wasi0.1.0-unknown "
                "-fno-PIE -fno-PIC -MD -nostdinc -DNDEBUG -isystem /z/lib/include "
                "-isystem /z/lib/libc/include/wasm-wasi-musl -isystem /z/lib/libc/include/generic-musl "
                "-isystem /z/lib/libc/include/any-wasi-any -O2 -Xclang -target-cpu -Xclang lime1 "
                "-Xclang -target-feature -Xclang -atomics -Xclang -target-feature -Xclang +sign-ext "
                "-c -o /tmp/x.o")
LINUX_COMPILE = WASI_COMPILE.replace("wasm32-unknown-wasi0.1.0-unknown", "x86_64-unknown-linux5.10.0-gnu2.31.0") \
    .replace("-fno-PIC", "-fPIC").replace("-DNDEBUG", "-DNDEBUG -D__GLIBC_MINOR__=31") \
    .replace("lime1", "x86-64")


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


class CaptureParsingTest(TempCase):
    def test_compile_line_yields_ordered_headers_and_codegen_flags(self):
        found = pr.parseCompileArgv(WASI_COMPILE)
        self.assertEqual(found["target"], "wasm32-unknown-wasi0.1.0-unknown")
        self.assertEqual(found["cpu"], "lime1")
        self.assertEqual(found["features"], ["-atomics", "+sign-ext"])
        self.assertEqual(found["pic"], ["-fno-PIE", "-fno-PIC"])
        self.assertEqual(found["defines"], [])
        self.assertEqual(found["isystem"], ["/z/lib/include", "/z/lib/libc/include/wasm-wasi-musl",
                                            "/z/lib/libc/include/generic-musl",
                                            "/z/lib/libc/include/any-wasi-any"])

    def test_glibc_define_is_carried_and_ndebug_is_not(self):
        found = pr.parseCompileArgv(LINUX_COMPILE)
        self.assertEqual(found["defines"], ["-D__GLIBC_MINOR__=31"])
        self.assertEqual(found["pic"], ["-fno-PIE", "-fPIC"])
        self.assertEqual(found["cpu"], "x86-64")

    def test_compile_line_without_target_or_headers_is_refused(self):
        with self.assertRaises(pe.EngineError):
            pr.parseCompileArgv("zig clang a.c -isystem /a")
        with self.assertRaises(pe.EngineError):
            pr.parseCompileArgv("zig clang a.c -target x -Xclang -target-cpu -Xclang y")

    def test_link_line_keeps_order_and_drops_only_the_output(self):
        cache = self.cacheWith("crt1.o", "libc.a", "fixture.o")
        line = "ld.lld -z stack-size=1 -o /out/a %s/crt1.o --dynamic-linker /lib64/ld.so %s/fixture.o %s/libc.a" % (
            cache, cache, cache)
        linker, items = pr.parseLinkArgv(line, "/out/a", "fixture.o", cache, self.dir)
        self.assertEqual(linker, "ld.lld")
        self.assertEqual(items, [("arg", "-z"), ("arg", "stack-size=1"), ("input", cache + "/crt1.o"),
                                 ("arg", "--dynamic-linker"), ("arg", "/lib64/ld.so"), ("user", None),
                                 ("input", cache + "/libc.a")])

    def test_link_input_printed_relative_to_the_zig_directory_resolves_there(self):
        cache = self.cacheWith("crt1.o", "fixture.o")
        relative = os.path.relpath(cache, self.dir)
        line = "ld.lld -o /out/a %s/crt1.o %s/fixture.o" % (relative, relative)
        _, items = pr.parseLinkArgv(line, "/out/a", "fixture.o", cache, self.dir)
        self.assertEqual(items, [("input", cache + "/crt1.o"), ("user", None)])
        with self.assertRaises(pe.EngineError):
            pr.parseLinkArgv(line, "/out/a", "fixture.o", cache, self.path("elsewhere"))

    def test_link_input_outside_the_private_cache_is_refused(self):
        cache = self.cacheWith("fixture.o")
        outside = self.path("elsewhere", "libc.a")
        write(outside)
        with self.assertRaises(pe.EngineError):
            pr.parseLinkArgv("ld.lld -o /o %s %s/fixture.o" % (outside, cache), "/o", "fixture.o", cache, self.dir)

    def test_missing_relative_or_duplicate_fixture_inputs_are_refused(self):
        cache = self.cacheWith("fixture.o")
        for line in ("ld.lld -o /o %s/gone.a %s/fixture.o" % (cache, cache),
                     "ld.lld -o /o libc.a %s/fixture.o" % cache,
                     "ld.lld -o /o",
                     "ld.lld -o /o %s/fixture.o %s/fixture.o" % (cache, cache),
                     "ld.lld -o /other %s/fixture.o" % cache):
            with self.assertRaises(pe.EngineError, msg=line):
                pr.parseLinkArgv(line, "/o", "fixture.o", cache, self.dir)

    def test_select_lines_ignores_library_builds(self):
        stderr = "\n".join(["ar rcs /c/libc.a /c/a.o", "zig clang /other.c -c -o /t/o.o",
                            WASI_COMPILE, "wasm-ld -o /c/stub.so /c/s.o",
                            "wasm-ld -o /out/fixture.out /c/crt1.o"]) + "\n"
        compile_, link = pr.selectLines(stderr, "/fx/runtimeWasi.c", "/out/fixture.out")
        self.assertEqual(compile_, WASI_COMPILE)
        self.assertEqual(link, "wasm-ld -o /out/fixture.out /c/crt1.o")
        with self.assertRaises(pe.EngineError):
            pr.selectLines("", "/fx/runtimeWasi.c", "/out/fixture.out")

    def cacheWith(self, *names):
        root = self.path("cache")
        for name in names:
            write(os.path.join(root, "o", "h", name))
        return os.path.realpath(os.path.join(root, "o", "h"))


class TargetAndConfigTest(unittest.TestCase):
    def test_allowlist_is_exactly_the_wasi_and_the_two_glibc_targets(self):
        self.assertEqual(pr.selectTargets([]), ["wasm32-wasi", "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        self.assertEqual(pr.selectTargets(["wasm32-wasi"]), ["wasm32-wasi"])
        self.assertEqual(pr.selectTargets(["aarch64-linux-gnu.2.31"]), ["aarch64-linux-gnu.2.31"])
        for bad in (["aarch64-linux-gnu"], ["aarch64-linux-gnu.2.30"], ["aarch64-linux-musl.1.2"], ["x86_64-linux-gnu"],
                    ["x86_64-linux-muslx32"], ["riscv64-linux-musl"], ["wasm32-wasi", "wasm32-wasi"],
                    ["x86_64-freebsd"], ["x86_64-freebsd.14"], ["x86_64-freebsd.15.0"], ["aarch64-freebsd.13.0"],
                    ["x86_64-freebsd-gnu.14.0"], ["i386-freebsd.14.0"], ["riscv64-freebsd.14.0"],
                    ["x86_64-freebsd.14.0", "x86_64-freebsd.14.0"]):
            with self.assertRaises(pe.EngineError):
                pr.selectTargets(bad)

    def test_musl_targets_are_named_explicitly_and_never_part_of_a_default_run(self):
        self.assertEqual(pr.selectTargets(["x86_64-linux-musl"]), ["x86_64-linux-musl"])
        self.assertEqual(pr.selectTargets(["aarch64-linux-musl", "wasm32-wasi"]), ["aarch64-linux-musl", "wasm32-wasi"])
        self.assertEqual(sorted(pr.MUSL_TARGETS), ["aarch64-linux-musl", "x86_64-linux-musl"])
        self.assertEqual(sorted(pr.PRODUCIBLE_TARGETS),
                         sorted(list(pr.TARGETS) + list(pr.MUSL_TARGETS) + list(pr.FREEBSD_TARGETS)))
        self.assertEqual([t for t in pr.TARGETS if "musl" in t], [])
        with self.assertRaises(pe.EngineError):
            pr.selectTargets(["x86_64-linux-musl", "x86_64-linux-musl"])

    def test_musl_has_no_shared_object_profile_and_the_glibc_shared_targets_are_unchanged(self):
        self.assertEqual(sorted(pr.SHARED_TARGETS), sorted(pr.ELF_TARGETS))
        for target in pr.MUSL_TARGETS:
            with self.assertRaisesRegex(pe.EngineError, "not supported"):
                pr.selectTargets([target], pr.SHARED_TARGETS)

    def test_musl_empty_archives_are_exactly_the_libraries_zig_drops_and_musl_installs_empty(self):
        self.assertEqual(sorted(pr.MUSL_EMPTY_ARCHIVES), sorted("lib%s.a" % n for n in (
            "m", "rt", "pthread", "util", "resolv", "dl", "crypt", "xnet")))
        for spec in pr.MUSL_TARGETS.values():
            self.assertEqual(spec["emptyArchives"], pr.MUSL_EMPTY_ARCHIVES)
            self.assertEqual(spec["driverFlags"], ["-nostdlib", "-static"])
            self.assertEqual(spec["fixture"], "runtimeMusl.c")
            self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, spec["fixture"])))

    def test_musl_config_is_static_with_the_prepared_directory_as_sysroot_and_no_glibc_define(self):
        for target, triple in (("x86_64-linux-musl", "x86_64-unknown-linux5.10.0-musl"),
                               ("aarch64-linux-musl", "aarch64-unknown-linux5.10.0-musl")):
            compile_ = pr.parseCompileArgv(LINUX_COMPILE.replace("x86_64-unknown-linux5.10.0-gnu2.31.0", triple)
                                           .replace(" -D__GLIBC_MINOR__=31", ""))
            items = [("input", "/c/crt1.o"), ("user", None), ("input", "/c/libc.a"), ("input", "/c/libcompiler_rt.a")]
            text = pr.renderConfig(target, pr.MUSL_TARGETS[target], compile_, items, ["%s" % target, "generic-musl"],
                                   "../engine", "22")
            lines = text.splitlines()
            self.assertIn("-target " + triple, lines)
            self.assertIn("--sysroot=<CFGDIR>/%s" % target, lines)
            self.assertIn("-static", lines)
            self.assertNotIn("-no-pie", lines)
            self.assertEqual([l for l in lines if "GLIBC" in l or "dynamic-linker" in l or "-pie" in l], [])
            self.assertEqual(lines[-3:], ["-Xlinker <CFGDIR>/%s/crt1.o" % target, "-Xlinker <CFGDIR>/%s/libc.a" % target,
                                           "-Xlinker <CFGDIR>/%s/libcompiler_rt.a" % target])
            self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/%s" % target, lines)
            self.assertIn("--ld-path=<CFGDIR>/../engine/bin/ld.lld", lines)

    def test_freebsd_targets_are_named_explicitly_and_never_part_of_a_default_run(self):
        x64, arm = "x86_64-freebsd.14.0", "aarch64-freebsd.14.0"
        self.assertEqual(sorted(pr.FREEBSD_TARGETS), [arm, x64])
        self.assertEqual(pr.selectTargets([x64]), [x64])
        self.assertEqual(pr.selectTargets([arm, "x86_64-linux-musl", "wasm32-wasi"]), [arm, "x86_64-linux-musl", "wasm32-wasi"])
        self.assertEqual([t for t in pr.TARGETS if "freebsd" in t], [])
        self.assertEqual(pr.selectTargets([]), list(pr.TARGETS))
        with self.assertRaises(pe.EngineError):
            pr.selectTargets([x64, x64])

    def test_freebsd_extends_no_gnu_table_so_the_gnu_shared_recipe_never_builds_it(self):
        self.assertEqual(sorted(pr.ELF_TARGETS), ["aarch64-linux-gnu.2.31", "x86_64-linux-gnu.2.31"])
        self.assertEqual(sorted(pr.SHARED_TARGETS), sorted(pr.ELF_TARGETS))
        for target in pr.FREEBSD_TARGETS:
            with self.assertRaisesRegex(pe.EngineError, "not supported"):
                pr.selectTargets([target], pr.SHARED_TARGETS)
            self.assertNotIn(target, pr.MUSL_ELF_TARGETS)
            with self.assertRaisesRegex(pe.EngineError, "no loader to check"):
                pr.elfInterpreterProblem("unread", target)

    def test_the_freebsd_profile_is_dynamic_non_pie_with_this_targets_triple_and_emulation(self):
        for target, triple, emulation, machine in (
                ("x86_64-freebsd.14.0", "x86_64-unknown-freebsd14.0.0-unknown", "elf_x86_64", 62),
                ("aarch64-freebsd.14.0", "aarch64-unknown-freebsd14.0.0-unknown", "aarch64elf", 183)):
            spec = pr.FREEBSD_TARGETS[target]
            self.assertEqual((spec["zigTriple"], spec["emulation"], spec["fixture"], spec["linker"]),
                             (triple, emulation, "runtimeFreebsd.c", "ld.lld"))
            self.assertEqual(spec["driverFlags"], ["-nostdlib", "-no-pie"])
            self.assertEqual(spec["requiredInputs"], ["crt1.o", "libc.so.7", "libm.so.5", "libthr.so.3"])
            self.assertEqual(spec["extraLibraryAliases"], {"libpthread.so": "libthr.so.3"})
            self.assertEqual(spec["zigLinkArgs"], ["-lm"])
            self.assertEqual(spec["receipt"]["linkage"], "dynamic")
            self.assertEqual(pr.FREEBSD_ELF_TARGETS[target]["machine"], machine)
            self.assertNotIn("emptyArchives", spec)
            self.assertNotIn("loader", spec["driverFlags"])
            self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, spec["fixture"])))
        self.assertEqual((pr.FREEBSD_VERSION, pr.FREEBSD_LOADER), (1400500, "/libexec/ld-elf.so.1"))

    def test_freebsd_config_names_the_versioned_triple_version_and_sysroot_and_stays_non_pie_without_glibc(self):
        for target, arch, emulation in (("x86_64-freebsd.14.0", "x86_64", "elf_x86_64"),
                                        ("aarch64-freebsd.14.0", "aarch64", "aarch64elf")):
            triple = arch + "-unknown-freebsd14.0.0-unknown"
            compile_ = pr.parseCompileArgv(LINUX_COMPILE.replace("x86_64-unknown-linux5.10.0-gnu2.31.0", triple)
                                           .replace("-D__GLIBC_MINOR__=31", "-D__FreeBSD_version=1400500"))
            items = [("arg", "-m"), ("arg", emulation), ("arg", "--dynamic-linker"), ("arg", "/libexec/ld-elf.so.1"),
                     ("input", "/c/crt1.o"), ("user", None), ("arg", "--as-needed"), ("input", "/c/libm.so.5"),
                     ("input", "/c/libthr.so.3"), ("input", "/c/libc.so.7"), ("input", "/c/libcompiler_rt.a")]
            text = pr.renderConfig(target, pr.FREEBSD_TARGETS[target], compile_, items,
                                   [arch + "-freebsd-none", "generic-freebsd"], "../engine", "22")
            lines = text.splitlines()
            self.assertIn("-target " + triple, lines)
            self.assertIn("-D__FreeBSD_version=1400500", lines)
            self.assertIn("--sysroot=<CFGDIR>/%s" % target, lines)
            self.assertEqual((lines.count("-nostdlib"), lines.count("-no-pie")), (1, 1))
            self.assertEqual([l for l in lines if "GLIBC" in l or l in ("-pie", "-static", "-shared")], [])
            self.assertIn("-isystem <CFGDIR>/include/libc/%s-freebsd-none" % arch, lines)
            self.assertIn("--ld-path=<CFGDIR>/../engine/bin/ld.lld", lines)
            self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/%s" % target, lines)
            start = lines.index("-Xlinker -m")
            self.assertEqual(lines[start:start + 4], ["-Xlinker -m", "-Xlinker " + emulation, "-Xlinker --dynamic-linker",
                                                       "-Xlinker /libexec/ld-elf.so.1"])
            self.assertEqual(lines[-6:], ["-Xlinker <CFGDIR>/%s/crt1.o" % target, "-Xlinker --as-needed",
                                           "-Xlinker <CFGDIR>/%s/libm.so.5" % target,
                                           "-Xlinker <CFGDIR>/%s/libthr.so.3" % target,
                                           "-Xlinker <CFGDIR>/%s/libc.so.7" % target,
                                           "-Xlinker <CFGDIR>/%s/libcompiler_rt.a" % target])

    def test_freebsd_translated_features_are_the_gnu_and_windows_entries_for_the_same_cpu(self):
        for target, source in (("x86_64-freebsd.14.0", "x86_64-linux-gnu.2.31"), ("aarch64-freebsd.14.0", "aarch64-windows-gnu")):
            entries = [e for e in pr.REMOVED_DISABLED_FEATURES_FREEBSD if e["target"] == target]
            expected = [dict(e, target=target) for e in pr.REMOVED_DISABLED_FEATURES if e["target"] == source]
            self.assertTrue(entries)
            self.assertEqual(entries, expected)
        carried, left = pr.translateFeatures(["-amx-transpose", "+sse4.2"], "x86_64-freebsd.14.0", "x86-64", "0.16.0", "22")
        self.assertEqual((carried, [e["feature"] for e in left]), (["+sse4.2"], ["-amx-transpose"]))
        self.assertEqual(pr.translateFeatures(["-tme"], "aarch64-freebsd.14.0", "x86-64", "0.16.0", "22")[0], ["-tme"])

    def test_config_refuses_tokens_that_would_need_quoting(self):
        for bad in ("a b", 'a"b', "a'b", "a\\b", "a;b", "$HOME", ""):
            with self.assertRaises(pe.EngineError, msg=repr(bad)):
                pr.configLine([bad])
        self.assertEqual(pr.configLine(["-Xlinker", "<CFGDIR>/t/libc.a"]), "-Xlinker <CFGDIR>/t/libc.a")

    def test_rendered_config_orders_headers_and_wraps_linker_arguments(self):
        compile_ = pr.parseCompileArgv(WASI_COMPILE)
        items = [("arg", "--entry"), ("arg", "_start"), ("input", "/c/crt1-command.o"), ("user", None),
                 ("input", "/c/libc.a")]
        text = pr.renderConfig("wasm32-wasi", pr.TARGETS["wasm32-wasi"], compile_, items,
                               ["wasm-wasi-musl", "generic-musl"], "../engine", "22")
        self.assertEqual(text.splitlines(), [
            "-target wasm32-wasip1",
            "-Xclang -target-cpu -Xclang lime1",
            "-Xclang -target-feature -Xclang -atomics",
            "-Xclang -target-feature -Xclang +sign-ext",
            "-fno-PIE -fno-PIC",
            "-nostdinc",
            "-isystem <CFGDIR>/../engine/lib/clang/22/include",
            "-isystem <CFGDIR>/include/libc/wasm-wasi-musl",
            "-isystem <CFGDIR>/include/libc/generic-musl",
            "-nostdlib",
            "--ld-path=<CFGDIR>/../engine/bin/wasm-ld",
            "-Xlinker -L -Xlinker <CFGDIR>/wasm32-wasi",
            "-Xlinker --entry",
            "-Xlinker _start",
            "-Xlinker <CFGDIR>/wasm32-wasi/crt1-command.o",
            "-Xlinker <CFGDIR>/wasm32-wasi/libc.a"])

    def test_gnu_configs_confine_driver_library_search_to_the_prepared_target(self):
        compile_ = pr.parseCompileArgv(LINUX_COMPILE)
        for target in pr.ELF_TARGETS:
            text = pr.renderConfig(target, pr.TARGETS[target], compile_, [], [], "..", "22")
            self.assertIn("--sysroot=<CFGDIR>/%s\n" % target, text)

    def test_linux_config_keeps_no_pie_and_the_glibc_define(self):
        compile_ = pr.parseCompileArgv(LINUX_COMPILE)
        text = pr.renderConfig("x86_64-linux-gnu.2.31", pr.TARGETS["x86_64-linux-gnu.2.31"], compile_, [],
                               ["x86-linux-gnu"], "../engine", "22")
        self.assertIn("-D__GLIBC_MINOR__=31\n", text)
        self.assertIn("-no-pie\n", text)
        self.assertIn("--ld-path=<CFGDIR>/../engine/bin/ld.lld\n", text)
        self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/x86_64-linux-gnu.2.31\n", text)


class FeatureTranslationTest(unittest.TestCase):
    def split(self, features, target="x86_64-linux-gnu.2.31", cpu="x86-64", zig="0.16.0", major="22"):
        carried, notCarried = pr.translateFeatures(features, target, cpu, zig, major)
        return carried, [e["feature"] for e in notCarried]

    def test_only_the_removed_disabled_amx_feature_is_left_out(self):
        self.assertEqual(self.split(["+64bit", "-amx-transpose", "-amx-tile", "+sse2"]),
                         (["+64bit", "-amx-tile", "+sse2"], ["-amx-transpose"]))

    def test_neighbours_of_the_removed_feature_are_carried_and_left_to_the_engine(self):
        for features, kwargs in ((["+amx-transpose"], {}),
                                 (["-amx-transposeX"], {}),
                                 (["-amx-transpose"], {"cpu": "sapphirerapids"}),
                                 (["-amx-transpose"], {"zig": "0.16.1"}),
                                 (["-amx-transpose"], {"major": "21"}),
                                 (["-amx-transpose"], {"major": "24"}),
                                 (["-amx-transpose"], {"target": "wasm32-wasi"})):
            self.assertEqual(self.split(features, **kwargs), (features, []), msg=(features, kwargs))

    def test_the_aarch64_linux_features_are_left_out_for_exactly_the_zig_engine_target_and_cpu(self):
        arm = "aarch64-linux-gnu.2.31"
        for feature in ("-no-zcz-fp", "-tme", "-zcz", "-zcz-gp"):
            carried, notCarried = pr.translateFeatures([feature, "+neon"], arm, "generic", "0.16.0", "22")
            self.assertEqual((carried, [e["feature"] for e in notCarried]), (["+neon"], [feature]))
            self.assertEqual(notCarried[0]["target"], arm)
            for other in ((arm, "apple-m1", "0.16.0", "22"), (arm, "generic", "0.17.0", "22"),
                          (arm, "generic", "0.16.0", "21"), (arm, "generic", "0.16.0", "24"),
                          ("aarch64-linux-gnu", "generic", "0.16.0", "22"),
                          ("aarch64-linux-muslx32", "generic", "0.16.0", "22"),
                          ("x86_64-linux-gnu.2.31", "generic", "0.16.0", "22")):
                self.assertEqual(pr.translateFeatures([feature], *other)[0], [feature], msg=(feature, other))
        self.assertEqual(pr.translateFeatures(["+tme", "-sve", "-bogus"], arm, "generic", "0.16.0", "22")[0],
                         ["+tme", "-sve", "-bogus"])

    def test_an_engine_23_leaves_out_what_it_no_longer_defines_and_keeps_the_rest(self):
        self.assertEqual(self.split(["-amx-tf32", "-amx-transpose", "-false-deps-lzcnt-tzcnt", "-amx-tile", "+sse2"],
                                    major="23"), (["-amx-tile", "+sse2"],
                                                  ["-amx-tf32", "-amx-transpose", "-false-deps-lzcnt-tzcnt"]))
        self.assertEqual(self.split(["-amx-tf32", "-false-deps-lzcnt-tzcnt"], major="22"),
                         (["-amx-tf32", "-false-deps-lzcnt-tzcnt"], []))
        arm = ["-hcx", "-pcdphint", "-tme", "-zcz", "-zcz-gp", "-no-zcz-fp", "-sve", "+neon"]
        for target in ("aarch64-linux-gnu.2.31", "aarch64-windows-gnu"):
            self.assertEqual(pr.translateFeatures(arm, target, "generic", "0.16.0", "23")[0], ["-sve", "+neon"])
        self.assertEqual(pr.translateFeatures(["-hcx", "-pcdphint"], "aarch64-windows-gnu", "generic", "0.16.0", "22")[0],
                         ["-hcx", "-pcdphint"])

    def test_the_aarch64_linux_entries_are_the_windows_ones_for_the_same_cpu(self):
        windows = [e for e in pr.REMOVED_DISABLED_FEATURES if e["target"] == "aarch64-windows-gnu"]
        self.assertEqual([dict(e, target="aarch64-windows-gnu") for e in pr.REMOVED_DISABLED_FEATURES_AARCH64_LINUX],
                         windows)
        self.assertEqual({e["target"] for e in pr.REMOVED_DISABLED_FEATURES_AARCH64_LINUX}, {"aarch64-linux-gnu.2.31"})

    def test_every_translation_names_its_sources_and_the_macro_that_must_stay_absent(self):
        for entry in pr.REMOVED_DISABLED_FEATURES + pr.REMOVED_DISABLED_FEATURES_AARCH64_LINUX:
            self.assertTrue(entry["feature"].startswith("-"))
            self.assertTrue(entry["absentMacroPrefix"] or entry["target"].startswith("aarch64-"))
            self.assertGreaterEqual(len(entry["sources"]), 2)
            for source in entry["sources"]:
                self.assertRegex(source, r"^https://(raw\.githubusercontent|github)\.com/llvm/llvm-project/(blob/)?llvmorg-2[123]\.\d+\.\d+/")


class ConfigCheckTest(TempCase):
    def runner(self, stderr="", stdout="", code=0):
        calls = []

        def run(command):
            calls.append(command)
            return subprocess_result(code, stdout, stderr)
        run.calls = calls
        return run

    def test_a_clean_compile_link_and_macro_dump_passes(self):
        run = self.runner(stdout="#define __x86_64__ 1\n")
        self.assertEqual(pr.checkConfig(run, "clang", ["--config", "c"], "x86_64-linux-gnu.2.31", self.dir, ["__AMX_"]),
                         os.path.join(self.dir, "x86_64-linux-gnu.2.31.bin"))
        self.assertEqual([c[-1] for c in run.calls][-1], "/dev/null")
        self.assertEqual(len(run.calls), 3)

    def test_an_unhonored_feature_warning_is_an_error_not_a_pass(self):
        run = self.runner(stderr="'-amx-transpose' is not a recognized feature for this target (ignoring feature)")
        with self.assertRaisesRegex(pe.EngineError, "compile warned: .*not a recognized feature"):
            pr.checkConfig(run, "clang", [], "x86_64-linux-gnu.2.31", self.dir, [])

    def test_a_failing_step_is_an_error(self):
        with self.assertRaisesRegex(pe.EngineError, "compile failed"):
            pr.checkConfig(self.runner(code=1, stderr="boom"), "clang", [], "wasm32-wasi", self.dir, [])

    def test_a_macro_of_a_left_out_feature_is_an_error(self):
        run = self.runner(stdout="#define __AMX_TILE__ 1\n#define __x86_64__ 1\n")
        with self.assertRaisesRegex(pe.EngineError, "__AMX_"):
            pr.checkConfig(run, "clang", [], "x86_64-linux-gnu.2.31", self.dir, ["__AMX_"])


def subprocess_result(code, stdout, stderr):
    return mock.Mock(returncode=code, stdout=stdout, stderr=stderr)


class PublicationTest(TempCase):
    def test_an_existing_empty_directory_is_not_replaced(self):
        source, destination = self.path("partial"), self.path("out")
        write(os.path.join(source, "payload"))
        os.makedirs(destination)
        inode = os.stat(destination).st_ino
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pr.renameNoReplace(source, destination)
        self.assertEqual((os.listdir(destination), os.stat(destination).st_ino), ([], inode))
        self.assertTrue(os.path.isfile(os.path.join(source, "payload")))

    def test_an_existing_file_is_not_replaced(self):
        write(self.path("partial", "payload"))
        write(self.path("out"), "keep")
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pr.renameNoReplace(self.path("partial"), self.path("out"))
        self.assertEqual(read(self.path("out")), "keep")

    def test_a_free_destination_receives_the_directory(self):
        write(self.path("partial", "payload"))
        pr.renameNoReplace(self.path("partial"), self.path("out"))
        self.assertEqual(os.listdir(self.path("out")), ["payload"])
        self.assertFalse(os.path.exists(self.path("partial")))

    def test_a_missing_source_is_an_os_error_not_a_claim(self):
        with self.assertRaises(FileNotFoundError):
            pr.renameNoReplace(self.path("gone"), self.path("out"))

    def onWindows(self, rename):
        """renameNoReplace as win32 runs it: os.rename is the answer and libc is never loaded."""
        patches = (mock.patch.object(pr.sys, "platform", "win32"), mock.patch.object(pr.os, "rename", side_effect=rename),
                   mock.patch.object(pr.ctypes, "CDLL", side_effect=AssertionError("libc loaded on win32")))
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        return pr.os.rename

    def test_windows_publishes_with_os_rename_and_never_loads_libc(self):
        rename = self.onWindows(lambda source, destination: None)
        pr.renameNoReplace(self.path("partial"), self.path("out"))
        rename.assert_called_once_with(self.path("partial"), self.path("out"))

    def test_windows_passes_spaces_and_unicode_paths_through_unchanged(self):
        source, destination = self.path("a partial dir"), self.path("bundle \u00e9\u4e2d", "out put")
        rename = self.onWindows(lambda source, destination: None)
        pr.renameNoReplace(source, destination)
        rename.assert_called_once_with(source, destination)

    def test_windows_refuses_an_existing_destination_by_the_platform_error_naming_it(self):
        def exists(source, destination):
            raise FileExistsError(183, "Cannot create a file when that file already exists", destination)
        self.onWindows(exists)
        for destination in (self.path("out"), self.path("a dir", "out")):
            with self.subTest(destination=destination):
                with self.assertRaisesRegex(pe.EngineError, "output %s exists; it is never replaced" % destination.replace("\\", "\\\\")):
                    pr.renameNoReplace(self.path("partial"), destination)

    def test_windows_keeps_every_other_failure_loud_and_unchanged(self):
        failures = (PermissionError(13, "Access is denied"), FileNotFoundError(2, "gone"), OSError(5, "I/O error"),
                    OSError(32, "sharing violation"))
        for failure in failures:
            self.onWindows(mock.Mock(side_effect=failure))
            with self.subTest(failure=failure):
                with self.assertRaises(type(failure)) as caught:
                    pr.renameNoReplace(self.path("partial"), self.path("out"))
                self.assertIs(caught.exception, failure)

    def test_windows_never_checks_first_or_overwrites(self):
        source, destination = self.path("partial"), self.path("out")
        write(os.path.join(source, "payload"))
        write(destination, "keep")
        self.onWindows(mock.Mock(side_effect=FileExistsError(183, "exists", destination)))
        with mock.patch.object(pr.os, "replace", side_effect=AssertionError("os.replace")), \
                mock.patch.object(pr.shutil, "move", side_effect=AssertionError("shutil.move")), \
                mock.patch.object(pr.os.path, "lexists", side_effect=AssertionError("precheck")), \
                mock.patch.object(pr.os.path, "exists", side_effect=AssertionError("precheck")):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pr.renameNoReplace(source, destination)
        self.assertEqual(read(destination), "keep")
        self.assertTrue(os.path.isfile(os.path.join(source, "payload")))

    def test_a_platform_with_no_known_no_replace_rename_is_still_refused_and_not_renamed(self):
        for platform in ("freebsd14", "cygwin", "sunos5"):
            with self.subTest(platform=platform), mock.patch.object(pr.sys, "platform", platform), \
                    mock.patch.object(pr.os, "rename", side_effect=AssertionError("os.rename")):
                with self.assertRaisesRegex(pe.EngineError, "no atomic no-replace rename is known for %s" % platform):
                    pr.renameNoReplace(self.path("partial"), self.path("out"))


class CopyTest(TempCase):
    def test_missing_artifact_is_refused(self):
        with self.assertRaises(pe.EngineError):
            pr.copyInputs([("input", self.path("gone.a"))], self.path("out"), "t", self.dir)
        with self.assertRaises(pe.EngineError):
            pr.copyInputs([("arg", "-x")], self.path("out2"), "t", self.dir)

    def test_two_inputs_with_one_name_are_refused(self):
        write(self.path("a", "libc.a"))
        write(self.path("b", "libc.a"))
        with self.assertRaises(pe.EngineError):
            pr.copyInputs([("input", self.path("a", "libc.a")), ("input", self.path("b", "libc.a"))],
                          self.path("out"), "t", self.dir)

    def test_headers_keep_order_skip_builtin_dir_and_record_absent(self):
        lib = self.path("lib")
        for name in ("one", "two"):
            write(os.path.join(lib, "libc", "include", name, "a.h"))
        isystem = [lib + "/include"] + [lib + "/libc/include/" + n for n in ("two", "gone", "one")]
        copied, absent = pr.copyHeaders(isystem, self.path("out"), lib)
        self.assertEqual((copied, absent), (["two", "one"], ["gone"]))
        self.assertTrue(os.path.isfile(self.path("out", "include", "libc", "one", "a.h")))

    def test_headers_outside_the_libc_include_root_or_with_symlinks_are_refused(self):
        lib = self.path("lib")
        write(os.path.join(lib, "libc", "include", "one", "a.h"))
        os.symlink("a.h", os.path.join(lib, "libc", "include", "one", "b.h"))
        with self.assertRaises(pe.EngineError):
            pr.copyHeaders([lib + "/include", lib + "/libc/include/one"], self.path("out"), lib)
        with self.assertRaises(pe.EngineError):
            pr.copyHeaders([lib + "/include", lib + "/elsewhere/one"], self.path("out2"), lib)
        with self.assertRaises(pe.EngineError):
            pr.copyHeaders([lib + "/other/include"], self.path("out3"), lib)

    def test_a_directory_two_targets_share_is_copied_once(self):
        lib = self.path("zig", "lib")
        for name in ("one", "shared", "two"):
            write(os.path.join(lib, "libc", "include", name, "h.h"), name)
        root = lib + "/libc/include/"
        copied = {}
        first = pr.copyTargetHeaders([lib + "/include", root + "one", root + "shared"], self.path("out"), lib, copied)
        second = pr.copyTargetHeaders([lib + "/include", root + "two", root + "shared", root + "gone"],
                                      self.path("out"), lib, copied)
        self.assertEqual((first, second), ((["one", "shared"], []), (["two", "shared"], ["gone"])))
        self.assertEqual(sorted(os.listdir(self.path("out", "include", "libc"))), ["one", "shared", "two"])
        self.assertEqual(read(self.path("out", "include", "libc", "shared", "h.h")), "shared")

    def test_a_shared_name_from_another_zig_directory_is_refused(self):
        lib = self.path("zig", "lib")
        write(os.path.join(lib, "libc", "include", "shared", "h.h"))
        with self.assertRaisesRegex(pe.EngineError, "is also"):
            pr.copyTargetHeaders([lib + "/include", lib + "/libc/include/shared"], self.path("out"), lib,
                                 {"shared": lib + "/elsewhere/shared"})

    def test_missing_notice_is_an_explicit_error(self):
        lib = self.path("zig", "lib")
        write(self.path("zig", "LICENSE"))
        spec = {"notices": {"zig": ["../LICENSE"], "musl": ["libc/musl/COPYRIGHT"]}}
        with self.assertRaisesRegex(pe.EngineError, "COPYRIGHT is missing"):
            pr.copyNotices(self.path("out"), lib, spec)

    def test_notice_leaving_the_zig_tree_is_refused(self):
        lib = self.path("zig", "lib")
        write(self.path("outside"))
        with self.assertRaises(pe.EngineError):
            pr.copyNotices(self.path("out"), lib, {"notices": {"x": ["../../outside"]}})


FAKE_ZIG = """#!%(python)s
import os, sys
lib = %(lib)r
if sys.argv[1] == "version":
    print("0.16.0")
    sys.exit(0)
target = sys.argv[sys.argv.index("-target") + 1]
out = sys.argv[sys.argv.index("-o") + 1]
fixture = [a for a in sys.argv if a.endswith(".c")][0]
stem = os.path.splitext(os.path.basename(fixture))[0]
cache = os.path.join(os.environ["ZIG_GLOBAL_CACHE_DIR"], "o", "abc")
os.makedirs(cache)
def make(name):
    with open(os.path.join(cache, name), "w") as f:
        f.write("artifact " + name)
    return os.path.join(cache, name)
isystem = "-isystem %%s/include" %% lib
if target == "wasm32-wasi":
    for d in ("wasm-wasi-musl", "generic-musl"):
        isystem += " -isystem %%s/libc/include/%%s" %% (lib, d)
    triple, flags, cpu = "wasm32-unknown-wasi0.1.0-unknown", "-fno-PIE -fno-PIC", "lime1"
    link = "wasm-ld --entry _start -o %%s %%s %%s %%s %%s" %% (out, make("crt1-command.o"), make("libc.a"),
        make(stem + ".o"), make("libcompiler_rt.a"))
elif "-freebsd." in target:
    arm = target.startswith("aarch64")
    arch = "aarch64" if arm else "x86_64"
    for d in (arch + "-freebsd-none", "generic-freebsd", arch + "-freebsd-any", "any-freebsd-any"):
        isystem += " -isystem %%s/libc/include/%%s" %% (lib, d)
    triple = arch + "-unknown-freebsd14.0.0-unknown"
    flags, cpu = "-fno-PIE -fno-PIC -D__FreeBSD_version=1400500", "generic" if arm else "x86-64"
    link = "ld.lld -m %%s %(extra)s--dynamic-linker /libexec/ld-elf.so.1 -o %%s %%s %%s --as-needed %%s %%s %%s %%s %%s %%s" %% (
        "aarch64elf" if arm else "elf_x86_64", out, make("crt1.o"), make(stem + ".o"), make("libm.so.5"),
        make("libthr.so.3"), make("libc.so.7"), make("libld.so.1"), make("libutil.so.9"), make("libcompiler_rt.a"))
elif target.endswith("-musl"):
    arm = target.startswith("aarch64")
    for d in (target, "generic-musl", "any-linux-any"):
        isystem += " -isystem %%s/libc/include/%%s" %% (lib, d)
    triple = target.replace("-linux-", "-unknown-linux5.10.0-")
    flags, cpu = "-fno-PIE -fno-PIC", "generic" if arm else "x86-64"
    link = "ld.lld %(extra)s-o %%s %%s %%s %%s %%s" %% (
        out, make("crt1.o"), make(stem + ".o"), make("libc.a"), make("libcompiler_rt.a"))
else:
    arm = target.startswith("aarch64")
    for d in ("aarch64-linux-gnu" if arm else "x86-linux-gnu", "generic-glibc"):
        isystem += " -isystem %%s/libc/include/%%s" %% (lib, d)
    triple = "aarch64-unknown-linux5.10.0-gnu2.31.0" if arm else "x86_64-unknown-linux5.10.0-gnu2.31.0"
    flags, cpu = "-fno-PIE -fPIC -D__GLIBC_MINOR__=31", "generic" if arm else "x86-64"
    if "-shared" in sys.argv:
        link = "ld.lld -shared %(extra)s-o %%s %%s %%s --as-needed %%s %%s" %% (
            out, make("crti.o"), make(stem + ".o"), make("libc.so.6"), make("libc_nonshared.a"))
    else:
        link = "ld.lld -z stack-size=1 -o %%s %%s --dynamic-linker /lib64/ld.so %%s --as-needed %%s %%s" %% (
            out, make("crt1.o"), make(stem + ".o"), make("libc.so.6"), make("libc_nonshared.a"))
sys.stderr.write("ar rcs %%s/x.a\\n" %% cache)
features = {"x86-64": "-Xclang -target-feature -Xclang -amx-transpose",
            "generic": "-Xclang -target-feature -Xclang -tme -Xclang -target-feature -Xclang +neon"}.get(
    cpu, "-Xclang -target-feature -Xclang +sign-ext")
sys.stderr.write("%%s clang %%s -target %%s %%s %%s -Xclang -target-cpu -Xclang %%s %%s -c -o /t/o.o\\n" %% (
    sys.argv[0], fixture, triple, flags, isystem, cpu, features))
sys.stderr.write(link + "\\n")
"""


FAKE_LLVM_AR = """#!%(python)s
import sys
if sys.argv[1:3] != ["--format=gnu", "crs"] or len(sys.argv) != 4:
    sys.exit("unexpected llvm-ar arguments %%r" %% sys.argv[1:])
with open(sys.argv[3], "wb") as f:
    f.write(b"!<arch>\\n")
"""


class ZigFixtureCase(TempCase):
    """A fake Zig and engine with the unit-test patches of the checks that need a real engine."""
    def setUp(self):
        super().setUp()
        self.lib = self.path("zig", "lib")
        for name in ("wasm-wasi-musl", "generic-musl", "x86-linux-gnu", "aarch64-linux-gnu", "generic-glibc",
                     "x86_64-linux-musl", "aarch64-linux-musl", "any-linux-any", "x86_64-freebsd-none",
                     "aarch64-freebsd-none", "generic-freebsd"):
            write(os.path.join(self.lib, "libc", "include", name, "h.h"))
        for rel in ("../LICENSE", "libc/musl/COPYRIGHT", "libc/glibc/LICENSES", "libc/freebsd/COPYRIGHT") + tuple(
                "libc/wasi/" + n for n in pr.WASI_LICENSES):
            write(os.path.normpath(os.path.join(self.lib, rel)), "license " + rel)
        self.zig = self.path("zig", "zigfake")
        self.writeZig()
        self.engine = self.path("engine")
        write(os.path.join(self.engine, "bin", "llvm-ar"), FAKE_LLVM_AR % {"python": sys.executable})
        os.chmod(os.path.join(self.engine, "bin", "llvm-ar"), 0o755)
        for patcher in (mock.patch.object(pe, "verifyEngine", return_value=("aarch64-macos", "22.1.1", 0)),
                        mock.patch.object(pr, "normalizeInput"),
                        mock.patch.object(pr, "verifyConfigs")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def writeZig(self, extra=""):
        write(self.zig, FAKE_ZIG % {"python": sys.executable, "lib": self.lib, "extra": extra})
        os.chmod(self.zig, 0o755)


class PipelineTest(ZigFixtureCase):
    def test_all_targets_produce_a_relocatable_payload(self):
        out = self.path("rt")
        pr.prepareRuntime(self.zig, self.engine, out, [])
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-linux-gnu.2.31", "aarch64-linux-gnu.2.31.cfg", "include",
                                                    "notices", "wasm32-wasi", "wasm32-wasi.cfg",
                                                    "x86_64-linux-gnu.2.31", "x86_64-linux-gnu.2.31.cfg"])
        self.assertEqual(sorted(os.listdir(self.path("rt", "wasm32-wasi"))),
                         ["crt1-command.o", "libc.a", "libcompiler_rt.a", "libm.a"])
        self.assertEqual(read(self.path("rt", "wasm32-wasi", "libm.a")), "!<arch>\n")
        self.assertEqual(sorted(os.listdir(self.path("rt", "x86_64-linux-gnu.2.31"))),
                         ["crt1.o", "libc.so", "libc.so.6", "libc_nonshared.a"])
        self.assertEqual(read(self.path("rt", "x86_64-linux-gnu.2.31", "libc.so.6")), "artifact libc.so.6")
        self.assertEqual(os.readlink(self.path("rt", "x86_64-linux-gnu.2.31", "libc.so")), "libc.so.6")
        self.assertEqual(read(self.path("rt", "x86_64-linux-gnu.2.31", "libc.so")), "artifact libc.so.6")
        self.assertEqual([n for n in os.listdir(self.path("rt", "wasm32-wasi")) if os.path.islink(self.path("rt", "wasm32-wasi", n))], [])
        self.assertEqual(sorted(os.listdir(self.path("rt", "include", "libc"))),
                         ["aarch64-linux-gnu", "generic-glibc", "generic-musl", "wasm-wasi-musl", "x86-linux-gnu"])
        config = read(self.path("rt", "wasm32-wasi.cfg"))
        self.assertIn("-Xlinker <CFGDIR>/wasm32-wasi/libc.a\n", config)
        self.assertNotIn(self.dir, config)
        self.assertEqual(read(self.path("rt", "notices", "glibc", "LICENSES")), "license libc/glibc/LICENSES")
        self.assertEqual(read(self.path("rt", "notices", "zig", "LICENSE")), "license ../LICENSE")
        receipt = json.loads(read(self.path("rt", "notices", "runtime-provenance.json")))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual([t["target"] for t in receipt["targets"]],
                         ["wasm32-wasi", "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        self.assertEqual(receipt["targets"][0]["linkArgs"][2:],
                         ["$RT/wasm32-wasi/crt1-command.o", "$RT/wasm32-wasi/libc.a", "$OBJECT",
                          "$RT/wasm32-wasi/libcompiler_rt.a"])
        self.assertEqual(receipt["zig"]["version"], "0.16.0")
        wasm, linux, arm = receipt["targets"]
        self.assertEqual(wasm["cpuFeaturesNotCarried"], [])
        self.assertEqual((wasm["libraryAliases"], linux["libraryAliases"], arm["libraryAliases"]),
                         ([], [{"alias": "libc.so", "target": "libc.so.6"}],
                          [{"alias": "libc.so", "target": "libc.so.6"}]))
        self.assertEqual((wasm["emptyArchives"], linux["emptyArchives"], arm["emptyArchives"]), (
            [{"name": "libm.a", "sha256": hashlib.sha256(b"!<arch>\n").hexdigest(), "bytes": 8}], [], []))
        self.assertEqual(pr.libraryNames(wasm["libraryAliases"], wasm["emptyArchives"]), ["m"])
        self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/x86_64-linux-gnu.2.31\n", read(self.path("rt", "x86_64-linux-gnu.2.31.cfg")))
        self.assertEqual(linux["cpuFeatures"], ["-amx-transpose"])
        self.assertEqual([e["feature"] for e in linux["cpuFeaturesNotCarried"]], ["-amx-transpose"])
        self.assertEqual(len(linux["cpuFeaturesNotCarried"][0]["sources"]), 2)
        self.assertIn("-Xclang -target-feature -Xclang +sign-ext\n", config)
        self.assertNotIn("amx-transpose", read(self.path("rt", "x86_64-linux-gnu.2.31.cfg")))
        self.assertEqual((arm["zigTarget"], arm["clangTarget"], arm["cpu"]),
                         ("aarch64-unknown-linux5.10.0-gnu2.31.0",) * 2 + ("generic",))
        self.assertEqual(arm["cpuFeatures"], ["-tme", "+neon"])
        self.assertEqual([e["feature"] for e in arm["cpuFeaturesNotCarried"]], ["-tme"])
        self.assertEqual([e["target"] for e in arm["cpuFeaturesNotCarried"]], ["aarch64-linux-gnu.2.31"])
        armConfig = read(self.path("rt", "aarch64-linux-gnu.2.31.cfg"))
        self.assertIn("-target aarch64-unknown-linux5.10.0-gnu2.31.0\n", armConfig)
        self.assertIn("-Xclang -target-feature -Xclang +neon\n", armConfig)
        self.assertNotIn("-tme", armConfig)
        self.assertIn("-isystem <CFGDIR>/include/libc/aarch64-linux-gnu\n", armConfig)
        self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/aarch64-linux-gnu.2.31\n", armConfig)
        self.assertEqual(read(self.path("rt", "aarch64-linux-gnu.2.31", "libc.so.6")), "artifact libc.so.6")
        self.assertNotIn("generated by", config)
        self.assertEqual(os.listdir(self.dir).count("rt"), 1)

    def test_existing_output_is_never_replaced(self):
        os.makedirs(self.path("rt"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [])

    def test_output_claimed_while_producing_is_never_replaced(self):
        out = self.path("rt")
        original = pr.writeProvenance

        def claimWhileProducing(*args):
            os.makedirs(out)
            original(*args)

        with mock.patch.object(pr, "writeProvenance", side_effect=claimWhileProducing):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pr.prepareRuntime(self.zig, self.engine, out, [])
        self.assertEqual(os.listdir(out), [])
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("rt.partial")], [])

    def test_unsupported_target_is_refused_before_zig_runs(self):
        with self.assertRaises(pe.EngineError):
            pr.prepareRuntime(self.path("no-such-zig"), self.engine, self.path("rt"), ["aarch64-linux-musl"])
        self.assertFalse(os.path.exists(self.path("rt")))

    def test_engine_relative_path_must_be_plain(self):
        for bad in ("/abs/engine", "a//b", "a b", "../en gine", "", "engine", "./engine", "../engine/..",
                    "../../.", "../a/../b", "../runtime/"):
            with self.assertRaises(pe.EngineError, msg=repr(bad)):
                pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [], bad)

    def test_failure_leaves_no_output_or_partial_directory(self):
        os.remove(os.path.join(self.lib, "libc", "glibc", "LICENSES"))
        with self.assertRaisesRegex(pe.EngineError, "LICENSES is missing"):
            pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [])
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("rt")], [])


def arMember(name, body):
    header = "%-16s%-12s%-6s%-6s%-8s%-10d`\n" % (name, "0", "0", "0", "644", len(body))
    return header.encode("ascii") + body + (b"\n" if len(body) % 2 else b"")


class MuslPipelineTest(ZigFixtureCase):
    def test_a_named_musl_target_produces_a_static_payload_that_the_default_run_does_not(self):
        out = self.path("rt")
        _, records = pr.prepareRuntime(self.zig, self.engine, out, ["x86_64-linux-musl", "aarch64-linux-musl"])
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-linux-musl", "aarch64-linux-musl.cfg", "include", "notices",
                                                    "x86_64-linux-musl", "x86_64-linux-musl.cfg"])
        for target in ("x86_64-linux-musl", "aarch64-linux-musl"):
            self.assertEqual(sorted(os.listdir(self.path("rt", target))), sorted(
                ["crt1.o", "libc.a", "libcompiler_rt.a"] + pr.MUSL_EMPTY_ARCHIVES))
            self.assertEqual([n for n in os.listdir(self.path("rt", target)) if os.path.islink(self.path("rt", target, n))], [])
            config = read(self.path("rt", target + ".cfg"))
            self.assertIn("--sysroot=<CFGDIR>/%s\n" % target, config)
            self.assertIn("-static\n", config)
            self.assertIn("-isystem <CFGDIR>/include/libc/%s\n" % target, config)
            self.assertNotIn(self.dir, config)
            self.assertNotIn("dynamic-linker", config)
        self.assertEqual(sorted(os.listdir(self.path("rt", "include", "libc"))),
                         ["aarch64-linux-musl", "any-linux-any", "generic-musl", "x86_64-linux-musl"])
        self.assertEqual(read(self.path("rt", "notices", "musl", "COPYRIGHT")), "license libc/musl/COPYRIGHT")
        self.assertFalse(os.path.exists(self.path("rt", "notices", "glibc")))
        x64, arm = records
        self.assertEqual((x64["zigTarget"], x64["linkage"], x64["libraryAliases"]),
                         ("x86_64-unknown-linux5.10.0-musl", "static", []))
        self.assertEqual((arm["zigTarget"], arm["cpu"]), ("aarch64-unknown-linux5.10.0-musl", "generic"))
        self.assertEqual([a["name"] for a in x64["emptyArchives"]], pr.MUSL_EMPTY_ARCHIVES)
        self.assertEqual(pr.libraryNames(x64["libraryAliases"], x64["emptyArchives"]),
                         ["m", "rt", "pthread", "util", "resolv", "dl", "crypt", "xnet"])
        self.assertEqual(x64["linkArgs"], ["$RT/x86_64-linux-musl/crt1.o", "$OBJECT",
                         "$RT/x86_64-linux-musl/libc.a", "$RT/x86_64-linux-musl/libcompiler_rt.a"])
        self.assertEqual([e["target"] for e in x64["cpuFeaturesNotCarried"]], ["x86_64-linux-musl"])
        self.assertEqual([e["target"] for e in arm["cpuFeaturesNotCarried"]], ["aarch64-linux-musl"])
        self.assertNotIn("-amx-transpose", read(self.path("rt", "x86_64-linux-musl.cfg")))
        self.assertIn("-Xclang -target-feature -Xclang +neon\n", read(self.path("rt", "aarch64-linux-musl.cfg")))

    def test_glibc_and_wasi_payloads_keep_their_files_beside_a_musl_target(self):
        out = self.path("rt")
        pr.prepareRuntime(self.zig, self.engine, out, ["wasm32-wasi", "x86_64-linux-gnu.2.31", "x86_64-linux-musl"])
        self.assertEqual(sorted(os.listdir(out)), ["include", "notices", "wasm32-wasi", "wasm32-wasi.cfg",
                                                    "x86_64-linux-gnu.2.31", "x86_64-linux-gnu.2.31.cfg",
                                                    "x86_64-linux-musl", "x86_64-linux-musl.cfg"])
        self.assertEqual(read(self.path("rt", "notices", "musl", "COPYRIGHT")), "license libc/musl/COPYRIGHT")
        self.assertEqual(read(self.path("rt", "notices", "glibc", "LICENSES")), "license libc/glibc/LICENSES")
        self.assertIn("-D__GLIBC_MINOR__=31\n", read(self.path("rt", "x86_64-linux-gnu.2.31.cfg")))
        self.assertNotIn("GLIBC", read(self.path("rt", "x86_64-linux-musl.cfg")))

    def test_a_zig_run_that_links_a_loader_or_pie_or_shared_object_is_refused_and_leaves_nothing(self):
        for extra in ("--dynamic-linker /lib/ld-musl-x86_64.so.1 ", "-pie ", "-shared "):
            self.writeZig(extra)
            with self.assertRaisesRegex(pe.EngineError, "static link line carries"):
                pr.prepareRuntime(self.zig, self.engine, self.path("rt"), ["x86_64-linux-musl"])
            self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("rt")], [])

    def test_a_zig_run_for_another_triple_or_without_the_startup_file_or_libc_is_refused(self):
        compile_ = {"target": "x86_64-unknown-linux5.10.0-musl"}
        spec = pr.MUSL_TARGETS["x86_64-linux-musl"]
        items = [("input", "/c/crt1.o"), ("user", None), ("input", "/c/libc.a")]
        pr.checkLinkage("x86_64-linux-musl", spec, compile_, items)
        for target in ("aarch64-unknown-linux5.10.0-musl", "x86_64-unknown-linux5.10.0-gnu2.31.0",
                       "x86_64-unknown-linux5.10.0-muslx32", "x86_64-unknown-windows-gnu"):
            with self.assertRaisesRegex(pe.EngineError, "not a x86_64 musl target"):
                pr.checkLinkage("x86_64-linux-musl", spec, {"target": target}, items)
        for missing, kept in ("crt1.o", items[1:]), ("libc.a", items[:2]):
            with self.assertRaisesRegex(pe.EngineError, "no %s" % missing.replace(".", "[.]")):
                pr.checkLinkage("x86_64-linux-musl", spec, compile_, kept)



class MuslVerificationTest(TempCase):
    X64, ARM = "x86_64-linux-musl", "aarch64-linux-musl"

    def elf(self, name, kind=2, machine=62, types=(1,), data=1):
        """An ELF64 with one program header per type, as ld writes a static or dynamic executable."""
        body = bytearray(64 + 56 * len(types))
        body[:16] = b"\x7fELF\x02" + bytes([data]) + b"\x01" + b"\0" * 9
        body[16:20] = kind.to_bytes(2, "little") + machine.to_bytes(2, "little")
        body[32:40] = (64).to_bytes(8, "little")
        body[54:58] = (56).to_bytes(2, "little") + len(types).to_bytes(2, "little")
        for index, kindOfHeader in enumerate(types):
            body[64 + 56 * index:64 + 56 * index + 4] = kindOfHeader.to_bytes(4, "little")
        with open(self.path(name), "wb") as f:
            f.write(body)
        return self.path(name)

    def test_a_static_executable_of_the_targets_machine_is_accepted(self):
        self.assertIsNone(pr.elfStaticProblem(self.elf("x", machine=62, types=(1, 1, 7)), self.X64))
        self.assertIsNone(pr.elfStaticProblem(self.elf("a", machine=183, types=(1,)), self.ARM))

    def test_the_other_machine_a_big_endian_file_or_a_non_elf_is_refused(self):
        self.assertIn("aarch64", pr.elfStaticProblem(self.elf("x", machine=62), self.ARM))
        self.assertIn("x86_64", pr.elfStaticProblem(self.elf("a", machine=183), self.X64))
        self.assertIn("x86_64", pr.elfStaticProblem(self.elf("big", machine=62, data=2), self.X64))
        write(self.path("text"), "#!/bin/sh\n")
        self.assertIn("x86_64", pr.elfStaticProblem(self.path("text"), self.X64))

    def test_any_loader_dynamic_section_or_position_independent_type_is_refused(self):
        for name, kind, types in (("glibcLoader", 2, (1, 3)), ("muslLoader", 2, (3, 1)), ("dynamic", 2, (1, 2)),
                                  ("pie", 3, (1,)), ("staticPie", 3, (1, 2))):
            problem = pr.elfStaticProblem(self.elf(name, kind=kind, types=types), self.X64)
            self.assertIsNotNone(problem, msg=name)
            self.assertRegex(problem, "not static|not a fixed-address", msg=name)

    def test_truncated_or_invalid_program_header_tables_are_not_accepted_as_static_executables(self):
        path = self.elf("truncated")
        with open(path, "r+b") as f:
            f.truncate(63)
        self.assertIn("header", pr.elfStaticProblem(path, self.X64))
        for offset, width, value in ((32, 8, 0), (32, 8, 4096), (54, 2, 0), (54, 2, 55), (54, 2, 57),
                                      (56, 2, 0), (56, 2, 10)):
            path = self.elf("table")
            with open(path, "r+b") as f:
                f.seek(offset)
                f.write(value.to_bytes(width, "little"))
            self.assertIn("header", pr.elfStaticProblem(path, self.X64), (offset, width, value))
        self.assertIn("loadable", pr.elfStaticProblem(self.elf("noLoad", types=(4,)), self.X64))

    def test_the_loader_check_is_for_glibc_targets_only(self):
        for target in (self.X64, self.ARM):
            with self.assertRaisesRegex(pe.EngineError, "no loader to check"):
                pr.elfInterpreterProblem(self.elf("x"), target)
        self.assertIsNone(pr.elfProblem(self.elf("x", machine=62), self.X64))
        self.assertIsNone(pr.elfProblem(self.elf("a", machine=183), self.ARM))

    def test_the_binary_runs_only_where_the_host_executes_its_machine_and_must_print_the_fixture_line(self):
        for system, machine, target, runs in (("linux", "x86_64", self.X64, True), ("linux", "AMD64", self.X64, True),
                                              ("linux", "aarch64", self.ARM, True), ("linux", "arm64", self.ARM, True),
                                              ("linux", "aarch64", self.X64, False), ("linux", "x86_64", self.ARM, False),
                                              ("darwin", "arm64", self.ARM, False), ("win32", "AMD64", self.X64, False)):
            with mock.patch.object(sys, "platform", system), mock.patch.object(pr.platform, "machine", return_value=machine), \
                    mock.patch.object(subprocess, "run", return_value=subprocess_result(0, pr.MUSL_OUTPUT, "")) as run:
                self.assertEqual(pr.runProblem("bin", target, self.dir), (None, runs), msg=(system, machine, target))
                self.assertEqual(run.called, runs)
        with mock.patch.object(sys, "platform", "linux"), mock.patch.object(pr.platform, "machine", return_value="x86_64"):
            for code, out, err in ((1, pr.MUSL_OUTPUT, ""), (0, "ok\n", ""), (0, "", ""),
                                   (0, pr.MUSL_OUTPUT, "unexpected diagnostic")):
                with mock.patch.object(subprocess, "run", return_value=subprocess_result(code, out, err)):
                    problem, ran = pr.runProblem("bin", self.X64, self.dir)
                    self.assertTrue(ran)
                    self.assertIn("run gave", problem)

    def test_verification_checks_the_static_elf_and_records_whether_the_producer_ran_it(self):
        records = [{"target": t, "cpuFeaturesNotCarried": [], "libraryAliases": [], "emptyArchives": []}
                   for t in (self.X64, self.ARM)]
        with mock.patch.object(pr, "placeEngine", return_value=(self.dir, self.dir)), \
                mock.patch.object(pr, "checkConfig", return_value="bin"), \
                mock.patch.object(pr, "elfStaticProblem", return_value=None) as elf, \
                mock.patch.object(pr, "runProblem", side_effect=[(None, True), (None, False)]) as ran:
            pr.verifyConfigs(self.dir, self.dir, "../engine", records, self.dir)
        self.assertEqual([c.args for c in elf.call_args_list], [("bin", self.X64), ("bin", self.ARM)])
        self.assertEqual([c.args for c in ran.call_args_list], [("bin", self.X64, self.dir), ("bin", self.ARM, self.dir)])
        self.assertEqual([r["ranOnProducer"] for r in records], [True, False])

    def test_verification_refuses_a_file_that_is_not_static_and_a_run_that_fails_and_runs_nothing_after_the_first(self):
        record = {"target": self.X64, "cpuFeaturesNotCarried": [], "libraryAliases": [], "emptyArchives": []}
        with mock.patch.object(pr, "placeEngine", return_value=(self.dir, self.dir)), \
                mock.patch.object(pr, "checkConfig", return_value="bin"):
            with mock.patch.object(pr, "elfStaticProblem", return_value="has an interpreter"), \
                    mock.patch.object(pr, "runProblem") as ran:
                with self.assertRaisesRegex(pe.EngineError, "x86_64-linux-musl: has an interpreter"):
                    pr.verifyConfigs(self.dir, self.dir, "../engine", [record], self.dir)
                ran.assert_not_called()
            with mock.patch.object(pr, "elfStaticProblem", return_value=None), \
                    mock.patch.object(pr, "runProblem", return_value=("run gave 1", True)):
                with self.assertRaisesRegex(pe.EngineError, "x86_64-linux-musl: run gave 1"):
                    pr.verifyConfigs(self.dir, self.dir, "../engine", [record], self.dir)

    def test_the_fixture_reads_musl_headers_only_and_prints_the_checked_line(self):
        source = read(os.path.join(pr.FIXTURES, "runtimeMusl.c"))
        for needle in ("#ifdef __GLIBC__", "#error", "_Thread_local", "pthread_create", "pow(", "sqrt(", "malloc(", "printf("):
            self.assertIn(needle, source)
        self.assertEqual(pr.MUSL_OUTPUT.split()[0:2], ["ok", "sum=9"])


class FreeBsdPipelineTest(ZigFixtureCase):
    X64, ARM = "x86_64-freebsd.14.0", "aarch64-freebsd.14.0"

    def writeZigReplacing(self, old, new):
        self.writeZig()
        text = read(self.zig)
        self.assertIn(old, text)
        write(self.zig, text.replace(old, new))
        os.chmod(self.zig, 0o755)

    def test_a_named_freebsd_target_produces_a_dynamic_stub_payload_that_the_default_run_does_not(self):
        out = self.path("rt")
        _, records = pr.prepareRuntime(self.zig, self.engine, out, [self.X64, self.ARM])
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-freebsd.14.0", "aarch64-freebsd.14.0.cfg", "include", "notices",
                                                    "x86_64-freebsd.14.0", "x86_64-freebsd.14.0.cfg"])
        for target in (self.X64, self.ARM):
            self.assertEqual(sorted(os.listdir(self.path("rt", target))), [
                "crt1.o", "libc.so", "libc.so.7", "libcompiler_rt.a", "libld.so.1", "libm.so", "libm.so.5", "libpthread.so",
                "libthr.so", "libthr.so.3", "libutil.so", "libutil.so.9"])
            self.assertEqual(sorted(n for n in os.listdir(self.path("rt", target)) if os.path.islink(self.path("rt", target, n))),
                             ["libc.so", "libm.so", "libpthread.so", "libthr.so", "libutil.so"])
            self.assertEqual(os.readlink(self.path("rt", target, "libpthread.so")), "libthr.so.3")
            self.assertEqual(read(self.path("rt", target, "libpthread.so")), "artifact libthr.so.3")
            self.assertFalse(os.path.lexists(self.path("rt", target, "libld.so")))
            config = read(self.path("rt", target + ".cfg"))
            self.assertIn("--sysroot=<CFGDIR>/%s\n" % target, config)
            self.assertIn("-D__FreeBSD_version=1400500\n", config)
            self.assertIn("-Xlinker /libexec/ld-elf.so.1\n", config)
            self.assertIn("-Xlinker <CFGDIR>/%s/libthr.so.3\n" % target, config)
            self.assertIn("-no-pie\n", config)
            self.assertNotIn(self.dir, config)
            self.assertNotIn("GLIBC", config)
        self.assertEqual(sorted(os.listdir(self.path("rt", "include", "libc"))),
                         ["aarch64-freebsd-none", "generic-freebsd", "x86_64-freebsd-none"])
        self.assertEqual(read(self.path("rt", "notices", "freebsd", "COPYRIGHT")), "license libc/freebsd/COPYRIGHT")
        self.assertEqual(read(self.path("rt", "notices", "zig", "LICENSE")), "license ../LICENSE")
        self.assertEqual(sorted(os.listdir(self.path("rt", "notices"))), ["freebsd", "runtime-provenance.json", "zig"])
        x64, arm = records
        self.assertEqual((x64["zigTarget"], x64["clangTarget"], x64["cpu"]), ("x86_64-unknown-freebsd14.0.0-unknown",) * 2 + ("x86-64",))
        self.assertEqual((arm["zigTarget"], arm["clangTarget"], arm["cpu"]), ("aarch64-unknown-freebsd14.0.0-unknown",) * 2 + ("generic",))
        self.assertEqual(x64["defines"], ["-D__FreeBSD_version=1400500"])
        self.assertEqual(x64["libraryAliases"], [
            {"alias": "libm.so", "target": "libm.so.5"}, {"alias": "libthr.so", "target": "libthr.so.3"},
            {"alias": "libc.so", "target": "libc.so.7"}, {"alias": "libutil.so", "target": "libutil.so.9"},
            {"alias": "libpthread.so", "target": "libthr.so.3"}])
        self.assertEqual(pr.libraryNames(x64["libraryAliases"], x64["emptyArchives"]), ["m", "thr", "c", "util", "pthread"])
        self.assertEqual(x64["emptyArchives"], [])
        self.assertEqual(x64["linkArgs"], [
            "-m", "elf_x86_64", "--dynamic-linker", "/libexec/ld-elf.so.1", "$RT/x86_64-freebsd.14.0/crt1.o", "$OBJECT",
            "--as-needed"] + ["$RT/x86_64-freebsd.14.0/" + n for n in (
                "libm.so.5", "libthr.so.3", "libc.so.7", "libld.so.1", "libutil.so.9", "libcompiler_rt.a")])
        self.assertEqual(arm["linkArgs"][:2], ["-m", "aarch64elf"])
        self.assertEqual((x64["includeDirectories"], x64["includeDirectoriesAbsentInZig"]),
                         (["x86_64-freebsd-none", "generic-freebsd"], ["x86_64-freebsd-any", "any-freebsd-any"]))
        self.assertEqual((arm["includeDirectories"], arm["includeDirectoriesAbsentInZig"]),
                         (["aarch64-freebsd-none", "generic-freebsd"], ["aarch64-freebsd-any", "any-freebsd-any"]))
        self.assertEqual([e["target"] for e in x64["cpuFeaturesNotCarried"]], ["x86_64-freebsd.14.0"])
        self.assertEqual([e["target"] for e in arm["cpuFeaturesNotCarried"]], ["aarch64-freebsd.14.0"])
        self.assertNotIn("-amx-transpose", read(self.path("rt", self.X64 + ".cfg")))
        self.assertIn("-Xclang -target-feature -Xclang +neon\n", read(self.path("rt", self.ARM + ".cfg")))
        for record in records:
            self.assertEqual(record["linkage"], "dynamic")
            self.assertTrue(record["executionProof"].startswith("none:"))
            self.assertIn("1400500", record["abi"])
            self.assertIn("no claim for 15.x", record["abi"])
            self.assertIn("libutil.so.9", record["abi"])
            self.assertEqual(len(record["noticeGaps"]), 1)
            self.assertEqual([i["name"] for i in record["inputs"]], [
                "crt1.o", "libm.so.5", "libthr.so.3", "libc.so.7", "libld.so.1", "libutil.so.9", "libcompiler_rt.a"])

    def test_glibc_musl_and_wasi_payloads_keep_their_files_beside_a_freebsd_target(self):
        out = self.path("rt")
        pr.prepareRuntime(self.zig, self.engine, out, ["wasm32-wasi", "x86_64-linux-gnu.2.31", "x86_64-linux-musl", self.X64])
        self.assertEqual(sorted(os.listdir(out)), ["include", "notices", "wasm32-wasi", "wasm32-wasi.cfg",
                                                    "x86_64-freebsd.14.0", "x86_64-freebsd.14.0.cfg",
                                                    "x86_64-linux-gnu.2.31", "x86_64-linux-gnu.2.31.cfg",
                                                    "x86_64-linux-musl", "x86_64-linux-musl.cfg"])
        self.assertEqual(read(self.path("rt", "notices", "freebsd", "COPYRIGHT")), "license libc/freebsd/COPYRIGHT")
        self.assertEqual(read(self.path("rt", "notices", "glibc", "LICENSES")), "license libc/glibc/LICENSES")
        self.assertIn("-D__GLIBC_MINOR__=31\n", read(self.path("rt", "x86_64-linux-gnu.2.31.cfg")))
        self.assertNotIn("FreeBSD", read(self.path("rt", "x86_64-linux-gnu.2.31.cfg")))
        self.assertNotIn("freebsd", read(self.path("rt", "x86_64-linux-musl.cfg")))
        self.assertEqual(sorted(os.listdir(self.path("rt", "x86_64-linux-gnu.2.31"))),
                         ["crt1.o", "libc.so", "libc.so.6", "libc_nonshared.a"])

    def test_a_zig_run_with_a_pie_shared_static_or_foreign_argument_is_refused_and_leaves_nothing(self):
        for extra in ("-pie ", "--pie ", "-shared ", "-static ", "-Bstatic ", "--no-dynamic-linker "):
            self.writeZig(extra)
            with self.assertRaisesRegex(pe.EngineError, "FreeBSD link line carries"):
                pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [self.X64])
            self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("rt")], [])

    def test_a_zig_run_for_another_version_loader_emulation_or_without_a_required_stub_is_refused_and_leaves_nothing(self):
        for old, new, message in (
                ("-unknown-freebsd14.0.0-unknown", "-unknown-freebsd15.0.0-unknown", "Zig compiled for"),
                ("-D__FreeBSD_version=1400500", "-D__FreeBSD_version=1500500", "does not define __FreeBSD_version=1400500"),
                ("/libexec/ld-elf.so.1", "/lib/ld-musl-x86_64.so.1", "--dynamic-linker \\['/lib/ld-musl-x86_64.so.1'\\]"),
                ("\"elf_x86_64\"", "\"elf_x86_64_fbsd\"", "-m \\['elf_x86_64_fbsd'\\]"),
                ("make(\"libthr.so.3\")", "make(\"libthr.so.4\")", "no libthr.so.3"),
                ("make(\"libc.so.7\")", "make(\"libc.so.8\")", "no libc.so.7"),
                ("make(\"crt1.o\")", "make(\"Scrt1.o\")", "no crt1.o")):
            self.writeZigReplacing(old, new)
            with self.assertRaisesRegex(pe.EngineError, message):
                pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [self.X64])
            self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("rt")], [], msg=old)

    def test_a_second_loader_or_emulation_argument_is_not_exactly_one(self):
        for extra, message in (("--dynamic-linker /libexec/ld-elf.so.1 ", "--dynamic-linker \\[.*, .*\\]"),
                               ("-m elf_x86_64 ", "-m \\['elf_x86_64', 'elf_x86_64'\\]")):
            self.writeZig(extra)
            with self.assertRaisesRegex(pe.EngineError, message):
                pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [self.X64])

    def test_the_zig_run_for_a_freebsd_target_compiles_the_fixture_with_the_math_library_and_no_other_library(self):
        work = self.path("work")
        with mock.patch.object(subprocess, "run", wraps=subprocess.run) as run:
            pr.runZig(self.zig, self.ARM, work)
        self.assertEqual(run.call_args.args[0], [self.zig, "cc", "-target", self.ARM, "-O2",
                                                 os.path.join(pr.FIXTURES, "runtimeFreebsd.c"), "-lm", "-o",
                                                 os.path.join(work, self.ARM, "fixture.out")])


class FreeBsdLinkCheckTest(TempCase):
    X64 = "x86_64-freebsd.14.0"

    def parts(self, **changes):
        parts = dict(compile_={"target": "x86_64-unknown-freebsd14.0.0-unknown", "defines": ["-D__FreeBSD_version=1400500"]},
                     items=[("arg", "-m"), ("arg", "elf_x86_64"), ("arg", "--dynamic-linker"), ("arg", "/libexec/ld-elf.so.1"),
                            ("input", "/c/crt1.o"), ("user", None), ("arg", "--as-needed"), ("input", "/c/libm.so.5"),
                            ("input", "/c/libthr.so.3"), ("input", "/c/libc.so.7")])
        parts.update(changes)
        return parts

    def check(self, **changes):
        parts = self.parts(**changes)
        pr.checkFreebsdLink(self.X64, pr.FREEBSD_TARGETS[self.X64], parts["compile_"], parts["items"])

    def test_the_exact_versioned_triple_with_its_version_and_loader_passes(self):
        self.check()

    def test_another_triple_arch_version_or_abi_is_refused(self):
        for triple in ("aarch64-unknown-freebsd14.0.0-unknown", "x86_64-unknown-freebsd15.0.0-unknown",
                       "x86_64-unknown-freebsd14.0.0-gnu", "x86_64-unknown-freebsd-unknown",
                       "x86_64-unknown-linux5.10.0-gnu2.31.0", "x86_64-unknown-freebsd14.0.0"):
            with self.assertRaisesRegex(pe.EngineError, "Zig compiled for", msg=triple):
                self.check(compile_={"target": triple, "defines": ["-D__FreeBSD_version=1400500"]})

    def test_the_version_define_is_required_exactly(self):
        for defines in ([], ["-D__FreeBSD_version=1500500"], ["-D__FreeBSD_version=14005000"], ["-D__GLIBC_MINOR__=31"]):
            with self.assertRaisesRegex(pe.EngineError, "does not define __FreeBSD_version=1400500", msg=defines):
                self.check(compile_={"target": "x86_64-unknown-freebsd14.0.0-unknown", "defines": defines})

    def test_the_loader_and_the_emulation_must_each_be_present_once_and_exact(self):
        base = self.parts()["items"]
        loader = base[2:4]
        emulation = base[0:2]
        for items, message in (
                ([i for i in base if i not in loader], "--dynamic-linker \\[\\]"),
                ([i for i in base if i not in emulation], "-m \\[\\]"),
                (base[:3] + [("arg", "/lib64/ld-linux-x86-64.so.2")] + base[4:], "--dynamic-linker"),
                (base[:3] + [("arg", "/libexec/ld-elf.so.1x")] + base[4:], "--dynamic-linker"),
                (base + loader, "--dynamic-linker"),
                ([("arg", "-m"), ("arg", "aarch64elf")] + base[2:], "-m \\['aarch64elf'\\]"),
                ([("arg", "-m"), ("arg", "elf_x86_64_fbsd")] + base[2:], "-m \\['elf_x86_64_fbsd'\\]")):
            with self.assertRaisesRegex(pe.EngineError, message):
                self.check(items=items)

    def test_each_required_input_is_needed_by_name(self):
        items = self.parts()["items"]
        for name in ("crt1.o", "libm.so.5", "libthr.so.3", "libc.so.7"):
            kept = [i for i in items if i != ("input", "/c/" + name)]
            with self.assertRaisesRegex(pe.EngineError, "no %s" % name.replace(".", "[.]")):
                self.check(items=kept)
        with self.assertRaisesRegex(pe.EngineError, "no libthr[.]so[.]3"):
            self.check(items=[("input", "/c/libthr.so.4") if i == ("input", "/c/libthr.so.3") else i for i in items])

    def test_position_independent_shared_static_and_loaderless_arguments_are_refused(self):
        items = self.parts()["items"]
        for flag in ("-pie", "--pie", "-shared", "-static", "-Bstatic", "--no-dynamic-linker"):
            with self.assertRaisesRegex(pe.EngineError, "FreeBSD link line carries %s" % flag):
                self.check(items=items + [("arg", flag)])


class FreeBsdLibraryAliasTest(TempCase):
    def stubs(self, *names):
        directory = self.path("rt dir", "target")
        for name in names:
            write(os.path.join(directory, name))
        return directory

    def test_pthread_is_an_alias_of_the_thr_stub_beside_the_generic_ones_and_ld_gets_none(self):
        names = ("crt1.o", "libm.so.5", "libthr.so.3", "libc.so.7", "libld.so.1", "libutil.so.9", "libcompiler_rt.a")
        directory = self.stubs(*names)
        records = pr.linkLibraryAliases(directory, list(names), {"libpthread.so": "libthr.so.3"})
        self.assertEqual(records, [{"alias": "libm.so", "target": "libm.so.5"}, {"alias": "libthr.so", "target": "libthr.so.3"},
                                   {"alias": "libc.so", "target": "libc.so.7"}, {"alias": "libutil.so", "target": "libutil.so.9"},
                                   {"alias": "libpthread.so", "target": "libthr.so.3"}])
        self.assertEqual(os.readlink(os.path.join(directory, "libpthread.so")), "libthr.so.3")
        self.assertFalse(os.path.lexists(os.path.join(directory, "libld.so")))
        self.assertEqual(pr.libraryNames(records), ["m", "thr", "c", "util", "pthread"])

    def test_an_extra_alias_for_a_stub_the_runtime_does_not_ship_is_refused_and_made_nowhere(self):
        directory = self.stubs("libc.so.7")
        with self.assertRaisesRegex(pe.EngineError, "libpthread.so names libthr.so.3, which the runtime does not ship"):
            pr.linkLibraryAliases(directory, ["libc.so.7"], {"libpthread.so": "libthr.so.3"})
        self.assertEqual([n for n in os.listdir(directory) if os.path.islink(os.path.join(directory, n))], [])

    def test_an_extra_alias_that_would_replace_a_file_is_refused(self):
        directory = self.stubs("libthr.so.3", "libpthread.so")
        with self.assertRaisesRegex(pe.EngineError, "libpthread.so for libthr.so.3 collides"):
            pr.linkLibraryAliases(directory, ["libthr.so.3"], {"libpthread.so": "libthr.so.3"})

    def test_without_extra_the_aliases_are_exactly_the_generic_ones(self):
        directory = self.stubs("libthr.so.3")
        self.assertEqual(pr.linkLibraryAliases(directory, ["libthr.so.3"]), [{"alias": "libthr.so", "target": "libthr.so.3"}])


class FreeBsdVerificationTest(TempCase):
    X64, ARM = "x86_64-freebsd.14.0", "aarch64-freebsd.14.0"
    BASE = 0x400000
    NEEDED = ["libc.so.7", "libthr.so.3"]

    def note(self, kind=1, value=1400500, name=b"FreeBSD\0"):
        pad = lambda body: body + b"\0" * (-len(body) % 4)
        desc = value.to_bytes(4, "little")
        return b"".join([len(name).to_bytes(4, "little"), len(desc).to_bytes(4, "little"), kind.to_bytes(4, "little"),
                          pad(name), pad(desc)])

    def elf(self, name, machine=62, kind=2, osabi=0, data=1, loaders=(b"/libexec/ld-elf.so.1\0",), notes=None,
            needed=None, dynamic=True, strtab=None, strsz=None, load=True):
        """A dynamic ELF64 of one file-sized PT_LOAD, a PT_INTERP per loader, one PT_NOTE of the notes and a PT_DYNAMIC
        whose DT_NEEDED names are read through DT_STRTAB, as ld writes a dynamic executable."""
        notes = [self.note()] if notes is None else notes
        names = [n.encode("ascii") + b"\0" for n in (self.NEEDED if needed is None else needed)]
        strings, starts = b"\0" + b"".join(names), []
        for index in range(len(names)):
            starts.append(1 + sum(len(n) for n in names[:index]))
        count = (1 if load else 0) + len(loaders) + 1 + (1 if dynamic else 0)
        body, offsets = bytearray(64 + 56 * count), []
        for blob in list(loaders) + [b"".join(notes), strings]:
            offsets.append(len(body))
            body += blob
        entries = [(1, s) for s in starts] + [
            (5, self.BASE + offsets[-1] if strtab is None else strtab), (10, len(strings) if strsz is None else strsz), (0, 0)]
        table = b"".join(tag.to_bytes(8, "little") + value.to_bytes(8, "little") for tag, value in entries)
        tableOffset = len(body)
        body += table
        headers = ([(1, 0, len(body))] if load else []) + [(3, o, len(l)) for o, l in zip(offsets, loaders)] + [
            (4, offsets[len(loaders)], len(b"".join(notes)))] + ([(2, tableOffset, len(table))] if dynamic else [])
        body[:16] = b"\x7fELF\x02" + bytes([data]) + b"\x01" + bytes([osabi]) + b"\0" * 8
        body[16:20] = kind.to_bytes(2, "little") + machine.to_bytes(2, "little")
        body[32:40] = (64).to_bytes(8, "little")
        body[54:58] = (56).to_bytes(2, "little") + len(headers).to_bytes(2, "little")
        for index, (type_, offset, size) in enumerate(headers):
            at = 64 + 56 * index
            body[at:at + 4] = type_.to_bytes(4, "little")
            body[at + 8:at + 16] = offset.to_bytes(8, "little")
            body[at + 16:at + 24] = (self.BASE + offset).to_bytes(8, "little")
            body[at + 32:at + 40] = size.to_bytes(8, "little")
        with open(self.path(name), "wb") as f:
            f.write(body)
        return self.path(name)

    def patch(self, path, offset, width, value):
        with open(path, "r+b") as f:
            f.seek(offset)
            f.write(value.to_bytes(width, "little"))

    def problem(self, path, target=None):
        problem, facts = pr.elfFreebsdProblem(path, target or self.X64)
        self.assertIsNotNone(problem)
        self.assertIsNone(facts)
        return problem

    def test_a_dynamic_executable_of_the_targets_machine_with_the_loader_tag_and_libc_is_accepted_with_its_facts(self):
        facts = {"abiTag": 1400500, "needed": ["libc.so.7", "libthr.so.3"], "osabi": 0}
        self.assertEqual(pr.elfFreebsdProblem(self.elf("x", machine=62), self.X64), (None, facts))
        self.assertEqual(pr.elfFreebsdProblem(self.elf("a", machine=183), self.ARM), (None, facts))

    def test_ei_osabi_is_recorded_as_found_and_never_required(self):
        for osabi in (0, 9, 3):
            problem, facts = pr.elfFreebsdProblem(self.elf("o%d" % osabi, osabi=osabi), self.X64)
            self.assertEqual((problem, facts["osabi"]), (None, osabi))

    def test_the_needed_names_are_read_in_order_and_other_libraries_are_recorded(self):
        needed = ["libm.so.5", "libthr.so.3", "libc.so.7", "libutil.so.9", "ld-elf.so.1"]
        problem, facts = pr.elfFreebsdProblem(self.elf("n", needed=needed), self.X64)
        self.assertEqual((problem, facts["needed"]), (None, needed))

    def test_the_other_machine_endianness_or_a_non_elf_is_refused(self):
        self.assertIn("aarch64", self.problem(self.elf("x", machine=62), self.ARM))
        self.assertIn("x86_64", self.problem(self.elf("a", machine=183), self.X64))
        self.assertIn("x86_64", self.problem(self.elf("big", data=2), self.X64))
        write(self.path("text"), "#!/bin/sh\n")
        self.assertIn("x86_64", self.problem(self.path("text")))

    def test_a_position_independent_or_shared_object_type_is_refused(self):
        for kind in (3, 1, 0):
            self.assertIn("not a fixed-address executable", self.problem(self.elf("k%d" % kind, kind=kind)))

    def test_a_file_with_no_loadable_segment_is_refused(self):
        self.assertIn("loadable", self.problem(self.elf("noLoad", load=False)))

    def test_any_loader_but_the_one_freebsd_loader_is_refused(self):
        for name, loaders in (("none", ()), ("glibc", (b"/lib64/ld-linux-x86-64.so.2\0",)),
                              ("musl", (b"/lib/ld-musl-x86_64.so.1\0",)), ("longer", (b"/libexec/ld-elf.so.1x\0",)),
                              ("noNul", (b"/libexec/ld-elf.so.1",)), ("twice", (b"/libexec/ld-elf.so.1\0",) * 2),
                              ("embeddedNul", (b"/libexec/ld-elf.so.1\0\0",))):
            self.assertIn("interpreter is", self.problem(self.elf(name, loaders=loaders)), msg=name)

    def test_a_loader_segment_running_past_the_file_is_refused_not_read(self):
        path = self.elf("x")
        self.patch(path, 64 + 56 * 1 + 32, 8, 1 << 40)
        self.assertIn("interpreter is", self.problem(path))
        self.assertIn("None", self.problem(path))

    def test_exactly_one_freebsd_abi_tag_of_the_pinned_version_is_required(self):
        for name, notes, expect in (("none", [], "\\[\\]"), ("old", [self.note(value=1400000)], "1400000"),
                                    ("newer", [self.note(value=1500500)], "1500500"),
                                    ("twice", [self.note(), self.note()], "1400500, 1400500"),
                                    ("vendor", [self.note(name=b"NetBSD\0")], "\\[\\]"),
                                    ("kind", [self.note(kind=2)], "\\[\\]")):
            self.assertRegex(self.problem(self.elf(name, notes=notes)), "ABI tags are .*%s" % expect, msg=name)

    def test_the_tag_is_found_among_other_notes_with_padding(self):
        notes = [self.note(kind=4, value=0), self.note(name=b"GNU\0", kind=5), self.note(), self.note(kind=2)]
        problem, facts = pr.elfFreebsdProblem(self.elf("x", notes=notes), self.X64)
        self.assertEqual((problem, facts["abiTag"]), (None, 1400500))

    def test_notes_that_overrun_their_segment_or_truncate_are_refused(self):
        big = bytearray(self.note())
        big[4:8] = (1000).to_bytes(4, "little")
        huge = bytearray(self.note())
        huge[0:4] = (1 << 31).to_bytes(4, "little")
        wrongSize = bytearray(self.note())
        wrongSize[4:8] = (8).to_bytes(4, "little")
        wrongSize += b"\0" * 4
        for name, notes, expect in (("desc", [bytes(big)], "runs past its segment"),
                                    ("name", [bytes(huge)], "runs past its segment"),
                                    ("truncated", [self.note()[:8]], "truncated"),
                                    ("trailing", [self.note(), b"\0" * 4], "truncated"),
                                    ("descSize", [bytes(wrongSize)], "holds 8 bytes")):
            self.assertIn(expect, self.problem(self.elf(name, notes=notes)), msg=name)

    def test_a_note_segment_running_past_the_file_is_refused(self):
        path = self.elf("x")
        self.patch(path, 64 + 56 * 2 + 32, 8, 1 << 40)
        self.assertIn("PT_NOTE segment runs past", self.problem(path))

    def test_libc_must_be_needed_and_the_dynamic_section_and_string_table_must_lie_inside_the_file(self):
        self.assertIn("does not need libc.so.7", self.problem(self.elf("m", needed=["libm.so.5"])))
        self.assertIn("does not need libc.so.7", self.problem(self.elf("e", needed=[])))
        self.assertIn("does not need libc.so.7", self.problem(self.elf("v", needed=["libc.so.6"])))
        self.assertIn("PT_DYNAMIC", self.problem(self.elf("d", dynamic=False)))
        self.assertIn("no string table", self.problem(self.elf("s", strtab=self.BASE + 10 ** 6)))
        self.assertIn("no string table", self.problem(self.elf("below", strtab=self.BASE - 1)))
        self.assertIn("not terminated", self.problem(self.elf("z", strsz=3)))

    def test_a_dynamic_table_without_its_null_terminator_is_refused_for_both_cpus(self):
        for target, machine in ((self.X64, 62), (self.ARM, 183)):
            path = self.elf("unterminated-" + target, machine=machine)
            with open(path, "rb") as f:
                size = len(f.read())
            self.patch(path, size - 16, 8, 21)
            self.assertIn("DT_NULL", self.problem(path, target))

    def test_a_needed_name_is_not_lossily_replaced_in_the_receipt(self):
        for target, machine in ((self.X64, 62), (self.ARM, 183)):
            path = self.elf("nonascii-" + target, machine=machine)
            with open(path, "rb") as f:
                position = f.read().index(b"libthr.so.3")
            self.patch(path, position, 1, 255)
            self.assertIn("not ASCII", self.problem(path, target))

    def test_a_dynamic_segment_running_past_the_file_or_of_a_wrong_size_is_refused(self):
        path = self.elf("x")
        self.patch(path, 64 + 56 * 3 + 32, 8, 1 << 40)
        self.assertIn("PT_DYNAMIC", self.problem(path))
        path = self.elf("y")
        self.patch(path, 64 + 56 * 3 + 32, 8, 20)
        self.assertIn("PT_DYNAMIC", self.problem(path))

    def test_truncated_or_invalid_program_header_tables_are_refused(self):
        path = self.elf("truncated")
        with open(path, "r+b") as f:
            f.truncate(63)
        self.assertIn("header", self.problem(path))
        for offset, width, value in ((32, 8, 0), (32, 8, 1 << 30), (54, 2, 0), (54, 2, 55), (54, 2, 57), (56, 2, 0), (56, 2, 200)):
            path = self.elf("table")
            self.patch(path, offset, width, value)
            self.assertIn("header", self.problem(path), (offset, width, value))

    def test_verification_records_what_it_found_and_never_runs_the_binary(self):
        facts = {"abiTag": 1400500, "needed": ["libc.so.7"], "osabi": 0}
        records = [{"target": t, "cpuFeaturesNotCarried": [], "libraryAliases": [], "emptyArchives": []}
                   for t in (self.X64, self.ARM)]
        with mock.patch.object(pr, "placeEngine", return_value=(self.dir, self.dir)), \
                mock.patch.object(pr, "checkConfig", return_value="bin"), \
                mock.patch.object(pr, "elfFreebsdProblem", return_value=(None, facts)) as elf, \
                mock.patch.object(pr, "runProblem") as ran, mock.patch.object(subprocess, "run") as spawned:
            pr.verifyConfigs(self.dir, self.dir, "../engine", records, self.dir)
        self.assertEqual([c.args for c in elf.call_args_list], [("bin", self.X64), ("bin", self.ARM)])
        ran.assert_not_called()
        spawned.assert_not_called()
        self.assertEqual([r["linkedExecutable"] for r in records], [facts, facts])
        self.assertEqual([r["ranOnProducer"] for r in records], [False, False])

    def test_verification_refuses_a_file_that_is_not_the_targets_executable(self):
        record = {"target": self.X64, "cpuFeaturesNotCarried": [], "libraryAliases": [], "emptyArchives": []}
        with mock.patch.object(pr, "placeEngine", return_value=(self.dir, self.dir)), \
                mock.patch.object(pr, "checkConfig", return_value="bin"), \
                mock.patch.object(pr, "elfFreebsdProblem", return_value=("interpreter is [], not /libexec/ld-elf.so.1", None)):
            with self.assertRaisesRegex(pe.EngineError, "x86_64-freebsd.14.0: interpreter is"):
                pr.verifyConfigs(self.dir, self.dir, "../engine", [record], self.dir)
        self.assertNotIn("ranOnProducer", record)

    def test_the_fixture_pins_the_version_and_uses_libc_libm_libthr_and_tls(self):
        source = read(os.path.join(pr.FIXTURES, "runtimeFreebsd.c"))
        for needle in ("__FreeBSD__ != 14", "__FreeBSD_version != 1400500", "#error", "__GLIBC__", "__linux__", "_Thread_local",
                       "pthread_create", "pthread_join", "pow(", "sqrt(", "malloc(", "printf("):
            self.assertIn(needle, source)


class FreeBsdProveTest(TempCase):
    TARGET = "x86_64-freebsd.14.0"

    def test_prove_says_a_freebsd_target_was_linked_and_checked_and_not_run_and_runs_nothing(self):
        engine, runtime = self.path("engine"), self.path("rt")
        write(os.path.join(engine, "bin", "clang"), "clang")
        write(os.path.join(runtime, self.TARGET + ".cfg"))
        write(os.path.join(runtime, self.TARGET, "libc.so.7"))
        os.symlink("libc.so.7", os.path.join(runtime, self.TARGET, "libc.so"))
        write(os.path.join(runtime, "notices", "runtime-provenance.json"), json.dumps({"engineRelative": "../engine", "targets": [{
            "target": self.TARGET, "cpuFeaturesNotCarried": [], "emptyArchives": [],
            "libraryAliases": [{"alias": "libc.so", "target": "libc.so.7"}]}]}))
        out = self.path("fake.bin")
        write(out, "bin")
        facts = {"abiTag": 1400500, "needed": ["libc.so.7", "libthr.so.3"], "osabi": 0}
        printed = io.StringIO()
        with mock.patch.object(pe, "verifyEngine", return_value=("aarch64-macos", "22.1.1", 0)), \
                mock.patch.object(pr, "checkConfig", return_value=out) as checked, \
                mock.patch.object(pr, "sandboxed", return_value=subprocess.CompletedProcess([], 1, "", "denied")), \
                mock.patch.object(pr, "elfFreebsdProblem", return_value=(None, facts)) as elf, \
                mock.patch.object(pr, "runProblem") as ran, \
                contextlib.redirect_stdout(printed):
            pr.prove(engine, runtime, [], None, [self.TARGET])
        line = printed.getvalue().splitlines()[0]
        self.assertEqual(line, "%s: linked, FreeBSD ELF checked (loader, ABI tag 1400500, needed libc.so.7 libthr.so.3, "
                               "EI_OSABI 0); not run (no FreeBSD host)" % self.TARGET)
        self.assertNotIn("ran:", line)
        self.assertEqual(checked.call_args.args[-1], ["c"])
        elf.assert_called_once()
        ran.assert_not_called()

    def test_prove_refuses_a_freebsd_binary_the_check_does_not_accept(self):
        engine, runtime = self.path("engine"), self.path("rt")
        write(os.path.join(engine, "bin", "clang"), "clang")
        write(os.path.join(runtime, self.TARGET + ".cfg"))
        write(os.path.join(runtime, "notices", "runtime-provenance.json"), json.dumps({"engineRelative": "../engine", "targets": [{
            "target": self.TARGET, "cpuFeaturesNotCarried": [], "emptyArchives": [], "libraryAliases": []}]}))
        os.makedirs(os.path.join(runtime, self.TARGET))
        out = self.path("fake.bin")
        write(out, "bin")
        with mock.patch.object(pe, "verifyEngine", return_value=("aarch64-macos", "22.1.1", 0)), \
                mock.patch.object(pr, "checkConfig", return_value=out), \
                mock.patch.object(pr, "sandboxed", return_value=subprocess.CompletedProcess([], 1, "", "denied")), \
                mock.patch.object(pr, "elfFreebsdProblem", return_value=("FreeBSD ABI tags are [], not [1400500]", None)), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(pe.EngineError, "x86_64-freebsd.14.0: FreeBSD ABI tags are"):
                pr.prove(engine, runtime, [], None, [self.TARGET])


class LibraryAliasTest(TempCase):
    def stubs(self, *names):
        directory = self.path("rt dir", "target")
        for name in names:
            write(os.path.join(directory, name))
        return directory

    def test_each_versioned_stub_gets_a_relative_link_and_the_linker_stub_gets_none(self):
        directory = self.stubs("libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libld.so.2",
                               "libc_nonshared.a", "crt1.o", "libz.so", "libfoo.so.1.2")
        records = pr.linkLibraryAliases(directory, sorted(os.listdir(directory)))
        self.assertEqual([r["alias"] for r in records],
                         ["libdl.so", "libm.so", "libpthread.so", "librt.so"])
        for record in records:
            self.assertEqual(os.readlink(os.path.join(directory, record["alias"])), record["target"])
            self.assertEqual(os.path.realpath(os.path.join(directory, record["alias"])),
                             os.path.join(os.path.realpath(directory), record["target"]))
        self.assertEqual(sorted(n for n in os.listdir(directory) if os.path.islink(os.path.join(directory, n))),
                         ["libdl.so", "libm.so", "libpthread.so", "librt.so"])
        self.assertEqual(pr.libraryNames(records), ["dl", "m", "pthread", "rt"])

    def test_an_alias_that_would_replace_a_file_is_refused(self):
        directory = self.stubs("libm.so.6", "libm.so")
        with self.assertRaisesRegex(pe.EngineError, "libm.so for libm.so.6 collides"):
            pr.linkLibraryAliases(directory, ["libm.so.6"])
        self.assertFalse(os.path.islink(os.path.join(directory, "libm.so")))

    def test_two_stubs_claiming_one_alias_are_refused(self):
        directory = self.stubs("libm.so.6", "libm.so.7")
        with self.assertRaisesRegex(pe.EngineError, "collides"):
            pr.linkLibraryAliases(directory, ["libm.so.6", "libm.so.7"])

    def test_a_stub_that_is_not_shipped_would_dangle_and_is_refused(self):
        directory = self.stubs("libc.so.6")
        with self.assertRaisesRegex(pe.EngineError, "not a regular file"):
            pr.linkLibraryAliases(directory, ["libm.so.6"])

    def test_verification_refuses_an_absolute_external_dangling_or_chained_link(self):
        directory = self.stubs("libm.so.6")
        record = [{"alias": "libm.so", "target": "libm.so.6"}]
        outside = self.path("outside")
        write(outside)
        for target in (os.path.join(directory, "libm.so.6"), "../../outside", "sub/../libm.so.6"):
            link = os.path.join(directory, "libm.so")
            os.symlink(target, link)
            with self.assertRaisesRegex(pe.EngineError, "not a relative link"):
                pr.verifyLibraryAliases(directory, record)
            os.remove(link)
        os.symlink("libm.so.6", os.path.join(directory, "libm.so"))
        pr.verifyLibraryAliases(directory, record)
        os.remove(os.path.join(directory, "libm.so.6"))
        with self.assertRaisesRegex(pe.EngineError, "not a regular file"):
            pr.verifyLibraryAliases(directory, record)
        os.symlink("../../outside", os.path.join(directory, "libm.so.6"))
        with self.assertRaisesRegex(pe.EngineError, "not the recorded aliases"):
            pr.verifyLibraryAliases(directory, record)


class EmptyArchiveTest(TempCase):
    def setUp(self):
        super().setUp()
        self.engine = self.path("an engine")
        self.directory = self.path("rt dir", "target")
        os.makedirs(self.directory)

    def archive(self, data=b"!<arch>\n"):
        path = os.path.join(self.directory, "libm.a")
        with open(path, "wb") as f:
            f.write(data)
        return [{"name": "libm.a", "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}]

    def test_the_archive_is_made_by_the_engine_in_gnu_format_and_parses_with_no_member(self):
        def ar(command):
            self.assertEqual(command, [os.path.join(self.engine, "bin", "llvm-ar"), "--format=gnu", "crs",
                                       os.path.join(self.directory, "libm.a")])
            self.archive()
            return ""

        with mock.patch.object(pe, "run", side_effect=ar) as run:
            records = pr.createEmptyArchives(self.engine, self.directory, ["libm.a"])
        run.assert_called_once()
        self.assertEqual(records, [{"name": "libm.a", "sha256": hashlib.sha256(b"!<arch>\n").hexdigest(), "bytes": 8}])
        with open(os.path.join(self.directory, "libm.a"), "rb") as f:
            self.assertEqual(pr.parseArchive(f.read()), [])
        if os.name != "nt":
            self.assertEqual(oct(os.stat(os.path.join(self.directory, "libm.a")).st_mode & 0o777), "0o644")

    def test_no_names_make_no_archive(self):
        self.assertEqual(pr.createEmptyArchives(self.engine, self.directory, []), [])
        self.assertEqual(os.listdir(self.directory), [])

    def test_an_archive_that_would_replace_a_file_or_leave_the_directory_is_refused(self):
        write(os.path.join(self.directory, "libm.a"), "real\n")
        with self.assertRaisesRegex(pe.EngineError, "libm.a collides"):
            pr.createEmptyArchives(self.engine, self.directory, ["libm.a"])
        self.assertEqual(read(os.path.join(self.directory, "libm.a")), "real\n")
        with self.assertRaisesRegex(pe.EngineError, "unsupported file name"):
            pr.createEmptyArchives(self.engine, self.directory, ["../libm.a"])

    def test_the_wasi_target_names_exactly_libm_and_the_glibc_target_none(self):
        self.assertEqual(pr.TARGETS["wasm32-wasi"]["emptyArchives"], ["libm.a"])
        self.assertNotIn("emptyArchives", pr.TARGETS["x86_64-linux-gnu.2.31"])

    def test_verification_accepts_the_recorded_empty_archive(self):
        pr.verifyEmptyArchives(self.directory, self.archive())

    def test_verification_refuses_an_archive_that_counterfeits_math_symbols_or_the_host_format(self):
        member = arMember("sqrt.o/", b"\x00asm\x01\x00\x00\x00")
        darwinEmpty = b"!<arch>\n" + arMember("#1/12", b"__.SYMDEF\x00\x00\x00\x00\x00")
        for data in (b"!<arch>\n" + member, darwinEmpty, b"", b"!<arch>", b"not an archive\n"):
            records = self.archive(data)
            with self.assertRaisesRegex(pe.EngineError, "not an empty archive", msg=data):
                pr.verifyEmptyArchives(self.directory, records)

    def test_verification_refuses_a_link_a_missing_file_or_a_changed_record(self):
        records = self.archive()
        records[0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(pe.EngineError, "differs from its record"):
            pr.verifyEmptyArchives(self.directory, records)
        records = self.archive()
        os.rename(os.path.join(self.directory, "libm.a"), os.path.join(self.directory, "real.a"))
        with self.assertRaisesRegex(pe.EngineError, "not a regular file"):
            pr.verifyEmptyArchives(self.directory, records)
        os.symlink("real.a", os.path.join(self.directory, "libm.a"))
        with self.assertRaisesRegex(pe.EngineError, "not a regular file"):
            pr.verifyEmptyArchives(self.directory, records)


class LibrarySearchLinkTest(TempCase):
    """The consumer case: `-lm -lpthread` appended by a build line, linked through a real prepared
    bundle that is relocated to a path with a space. Needs MANAGED_TOOLCHAIN_BUNDLE=<full bundle>."""

    def setUp(self):
        super().setUp()
        source = os.environ.get("MANAGED_TOOLCHAIN_BUNDLE")
        if not (source and sys.platform == "darwin"):
            self.skipTest("needs MANAGED_TOOLCHAIN_BUNDLE=<full bundle> on the macOS producer host")
        self.bundle = self.path("a bundle")
        shutil.copytree(source, self.bundle, symlinks=True)
        self.clang = os.path.join(self.bundle, "bin", "clang")
        self.config = ["--config", os.path.join(self.bundle, "runtime", "x86_64-linux-gnu.2.31.cfg")]
        write(self.path("p.c"), "#include <math.h>\n#include <stdio.h>\n#include <dlfcn.h>\n#include <time.h>\n"
              "int main(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);dlopen(\"x\",0);"
              "printf(\"%f\\n\",sqrt(2.0));return 0;}\n")

    def invoke(self, *arguments):
        return subprocess.run([self.clang] + self.config + list(arguments), cwd=self.dir,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                              env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"})

    def test_compile_only_is_silent(self):
        done = self.invoke("-c", "p.c", "-o", "p.o")
        self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_explicit_libraries_link_without_a_warning(self):
        self.assertEqual(self.invoke("-c", "p.c", "-o", "p.o").returncode, 0)
        for libraries in (["-lm", "-lpthread"], ["-lm", "-lpthread", "-ldl", "-lrt"], ["-lc", "-lutil", "-lresolv"]):
            done = self.invoke("p.o", *libraries, "-o", "p.bin")
            self.assertEqual((done.returncode, done.stderr), (0, ""), msg=libraries)

    def test_a_library_the_runtime_does_not_ship_is_still_refused(self):
        self.assertEqual(self.invoke("-c", "p.c", "-o", "p.o").returncode, 0)
        for library in ("-lnosuch", "-lld"):
            done = self.invoke("p.o", library, "-o", "p.bin")
            self.assertNotEqual(done.returncode, 0, msg=library)
            self.assertIn("unable to find library " + library, done.stderr)


class WasiMathLinkTest(TempCase):
    """The consumer case on wasm32-wasi: the `-lm` a build line appends, through a real prepared
    bundle relocated to a path with a space. Needs MANAGED_TOOLCHAIN_BUNDLE=<full bundle>; a bundle
    prepared before the empty libm.a fails here with `unable to find library -lm`."""

    def setUp(self):
        super().setUp()
        source = os.environ.get("MANAGED_TOOLCHAIN_BUNDLE")
        if not (source and sys.platform == "darwin"):
            self.skipTest("needs MANAGED_TOOLCHAIN_BUNDLE=<full bundle> on the macOS producer host")
        self.bundle = self.path("a bundle")
        shutil.copytree(source, self.bundle, symlinks=True)
        self.clang = os.path.join(self.bundle, "bin", "clang")
        self.config = ["--config", os.path.join(self.bundle, "runtime", "wasm32-wasi.cfg")]
        write(self.path("m.c"), "#include <math.h>\n#include <stdio.h>\n"
              "int main(void){volatile double x=2.0;printf(\"%.3f\\n\",sqrt(x));return 0;}\n")

    def invoke(self, *arguments):
        return subprocess.run([self.clang] + self.config + list(arguments), cwd=self.dir,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                              env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"})

    def test_a_build_line_that_appends_lm_links_without_a_warning_and_runs(self):
        self.assertEqual(self.invoke("-c", "m.c", "-o", "m.o").returncode, 0)
        done = self.invoke("m.o", "-lm", "-o", "m.wasm")
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        wasmtime = shutil.which("wasmtime")
        if wasmtime:
            ran = subprocess.run([wasmtime, self.path("m.wasm")], stdout=subprocess.PIPE, universal_newlines=True)
            self.assertEqual((ran.returncode, ran.stdout), (0, "1.414\n"))

    def test_a_library_the_runtime_does_not_ship_is_still_refused(self):
        self.assertEqual(self.invoke("-c", "m.c", "-o", "m.o").returncode, 0)
        done = self.invoke("m.o", "-lnosuch", "-o", "m.wasm")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("unable to find library -lnosuch", done.stderr)


class ArchiveTest(unittest.TestCase):
    def test_members_come_back_in_order_with_long_names_and_without_the_symbol_table(self):
        long = b"/private/tmp/cache/abc/closedir.o/\n"
        data = (b"!<arch>\n" + arMember("/", b"\0\0\0\0") + arMember("//", long)
                + arMember("/0", b"odd") + arMember("short.o/", b"even"))
        self.assertEqual(pr.parseArchive(data), [("/private/tmp/cache/abc/closedir.o", b"odd"),
                                                 ("short.o", b"even")])

    def bsdMember(self, name, body):
        encoded = name.encode("utf-8")
        encoded += b"\0" * (-len(encoded) % 8)
        return arMember("#1/%d" % len(encoded), encoded + body)

    def test_bsd_attached_names_and_short_names_preserve_payloads_and_member_order(self):
        data = b"!<arch>\n" + self.bsdMember("long-object-name.o", b"odd") + arMember("short.o", b"even")
        self.assertEqual(pr.parseArchive(data), [("long-object-name.o", b"odd"), ("short.o", b"even")])

    def test_each_bsd_symbol_table_spelling_is_skipped_but_a_similar_object_is_not(self):
        for name in ("__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED"):
            data = b"!<arch>\n" + self.bsdMember(name, b"index") + self.bsdMember("object.o", b"object")
            self.assertEqual(pr.parseArchive(data), [("object.o", b"object")])
        data = b"!<arch>\n" + arMember("__.SYMDEF", b"index") + self.bsdMember("__.SYMDEF_extra.o", b"ordinary")
        self.assertEqual(pr.parseArchive(data), [("__.SYMDEF_extra.o", b"ordinary")])

    def test_bsd_duplicate_member_names_are_not_deduplicated(self):
        data = b"!<arch>\n" + self.bsdMember("dup.o", b"first") + self.bsdMember("dup.o", b"second")
        self.assertEqual(pr.parseArchive(data), [("dup.o", b"first"), ("dup.o", b"second")])

    def test_malformed_attached_names_and_gnu_name_references_are_refused(self):
        for member in (arMember("#1/bad", b"name"), arMember("#1/0", b"object"),
                       arMember("#1/20", b"short"), arMember("#1/4", b"\0" * 4),
                       arMember("#1/4", b"x\0y\0object"), arMember("#1/1", b"\xffobject"),
                       arMember("/0", b"object"), arMember("/unknown", b"object"),
                       arMember("//", b"unterminated") + arMember("/0", b"object"),
                       arMember("//", b"short.o/\n") + arMember("/100", b"object"),
                       arMember("odd.o/", b"odd")[:-1]):
            with self.subTest(member=member), self.assertRaises(pe.EngineError):
                pr.parseArchive(b"!<arch>\n" + member)

    def test_unsupported_archives_are_refused(self):
        for data in (b"not an archive", b"!<arch>\n" + arMember("#1/21", b"x" * 20),
                     b"!<arch>\n" + arMember("a.o/", b"abc")[:-2]):
            with self.assertRaises(pe.EngineError):
                pr.parseArchive(data)


@unittest.skipUnless(os.environ.get("MANAGED_TOOLCHAIN_ENGINE") and shutil.which("wasmtime"),
                     "needs MANAGED_TOOLCHAIN_ENGINE=<prepared engine> and wasmtime")
class LldArchiveTest(TempCase):
    """Archives the way lld reads them: members load lazily by reference, in any command-line
    order, and a nested reference (user object -> libA -> libB) is followed. libB holds two
    members both named dup.o, which normalization must keep apart."""

    def setUp(self):
        super().setUp()
        self.engine = os.environ["MANAGED_TOOLCHAIN_ENGINE"]
        self.fixture = os.path.join(pr.FIXTURES, "archiveChain.c")
        for variant in ("MEMBER_A", "MEMBER_B1", "MEMBER_B2", "MEMBER_UNUSED"):
            self.compile(variant, variant)
        self.compile("user", None)

    def tool(self, name):
        return os.path.join(self.engine, "bin", name)

    def compile(self, name, define):
        pe.run([self.tool("clang"), "--target=wasm32", "-ffreestanding", "-nostdlib", "-O2", "-c", self.fixture]
               + (["-D" + define] if define else []) + ["-o", self.path(name + ".o")])

    def build(self, name, members):
        """Archive with `q`, which appends without replacing a member of the same name."""
        out = self.path(name + ".a")
        for i, (member, base) in enumerate(members):
            directory = self.path("stage", name, str(i))
            os.makedirs(directory)
            shutil.copyfile(self.path(member + ".o"), os.path.join(directory, base))
            pe.run([self.tool("llvm-ar"), "q", out, os.path.join(directory, base)])
        return out

    def link(self, inputs, name="out", extra=()):
        output = self.path(name + ".wasm")
        pe.run([self.tool("clang"), "--target=wasm32", "-nostdlib", "-Wl,--no-entry"] + list(extra)
               + list(inputs) + ["-o", output])
        return output

    def invoke(self, module, export):
        done = subprocess.run(["wasmtime", "--invoke", export, module], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)
        return done.returncode, done.stdout.strip()

    def libraries(self):
        return (self.build("libA", [("MEMBER_A", "dup.o")]),
                self.build("libB", [("MEMBER_B1", "dup.o"), ("MEMBER_B2", "dup.o"), ("MEMBER_UNUSED", "unused.o")]))

    def test_archives_before_the_user_object_resolve_nested_references_lazily(self):
        libA, libB = self.libraries()
        user = self.path("user.o")
        for order in ((libA, libB, user), (libB, libA, user), (user, libA, libB)):
            module = self.link(order)
            self.assertEqual(self.invoke(module, "run"), (0, "13"), msg=order)
            self.assertNotEqual(self.invoke(module, "leak")[0], 0, msg="unreferenced member was loaded")
        eager = self.link([user, libA], "eager", ["-Wl,--whole-archive", libB, "-Wl,--no-whole-archive"])
        self.assertEqual(self.invoke(eager, "leak"), (0, "99"))

    def test_normalization_keeps_both_members_of_one_name(self):
        libA, libB = self.libraries()
        self.assertEqual(pe.run([self.tool("llvm-ar"), "t", libB]).split(), ["dup.o", "dup.o", "unused.o"])
        pr.normalizeInput(self.engine, libB)
        with open(libB, "rb") as f:
            names = [name for name, _ in pr.parseArchive(f.read())]
        self.assertEqual(names, ["0000-dup.o", "0001-dup.o", "0002-unused.o"])
        module = self.link([libA, libB, self.path("user.o")], "normalized")
        self.assertEqual(self.invoke(module, "run"), (0, "13"))
        self.assertNotEqual(self.invoke(module, "leak")[0], 0)

    def test_replacing_by_name_would_lose_a_member_and_fail_the_link(self):
        libA = self.build("libA", [("MEMBER_A", "dup.o")])
        for member in ("MEMBER_B1", "MEMBER_B2"):
            os.makedirs(self.path("byName", member))
            shutil.copyfile(self.path(member + ".o"), self.path("byName", member, "dup.o"))
            pe.run([self.tool("llvm-ar"), "rc", self.path("byName.a"), self.path("byName", member, "dup.o")])
        self.assertEqual(pe.run([self.tool("llvm-ar"), "t", self.path("byName.a")]).split(), ["dup.o"])
        with self.assertRaisesRegex(pe.EngineError, "undefined symbol: fromB"):
            self.link([libA, self.path("byName.a"), self.path("user.o")], "lost")


class EngineRelativeLayoutTest(TempCase):
    """verifyConfigs and prove put engine and runtime where the receipt's engineRelative says,
    including `..`, the engine root that holds the runtime as a child; every path has a space."""

    def setUp(self):
        super().setUp()
        self.engine = self.path("an engine")
        write(os.path.join(self.engine, "bin", "clang"), "clang")
        write(os.path.join(self.engine, "lib", "clang", "22", "include", "stddef.h"))
        self.runtime = self.path("a runtime")
        write(os.path.join(self.runtime, "x86_64-linux-gnu.2.31.cfg"))
        write(os.path.join(self.runtime, "x86_64-linux-gnu.2.31", "libm.so.6"))
        os.symlink("libm.so.6", os.path.join(self.runtime, "x86_64-linux-gnu.2.31", "libm.so"))
        write(os.path.join(self.runtime, "notices", "runtime-provenance.json"),
              json.dumps({"engineRelative": "..", "targets": [{
                  "target": "x86_64-linux-gnu.2.31", "cpuFeaturesNotCarried": [],
                  "libraryAliases": [{"alias": "libm.so", "target": "libm.so.6"}], "emptyArchives": []}]}))
        self.seen = []

    def records(self):
        return [{"target": "x86_64-linux-gnu.2.31", "cpuFeaturesNotCarried": [],
                 "libraryAliases": [{"alias": "libm.so", "target": "libm.so.6"}], "emptyArchives": []}]

    def recordConfig(self, run, clang, config, target, work, prefixes, libraries):
        """What a config reads: the engine file and header the config's own directory reaches."""
        base = os.path.dirname(config[1])
        relative = self.relative
        self.libraries = libraries
        self.seen.append((os.path.isfile(clang), os.path.isfile(config[1]),
                          os.path.isfile(os.path.join(base, relative, "lib", "clang", "22", "include", "stddef.h")),
                          os.path.realpath(os.path.join(base, relative, "bin", "clang"))
                          == os.path.realpath(os.path.join(self.engine, "bin", "clang")),
                          os.path.islink(os.path.join(base, "x86_64-linux-gnu.2.31", "libm.so"))))
        return None

    def verify(self, relative):
        self.relative = relative
        work = tempfile.mkdtemp(prefix="work dir ", dir=self.dir)
        with mock.patch.object(pr, "checkConfig", side_effect=self.recordConfig):
            pr.verifyConfigs(self.engine, self.runtime, relative, self.records(), work)

    def test_engine_relative_steps_up_count_and_names_are_validated(self):
        self.assertEqual(pr.checkEngineRelative("../engine"), 1)
        self.assertEqual(pr.checkEngineRelative(".."), 1)
        self.assertEqual(pr.checkEngineRelative("../.."), 2)
        self.assertEqual(pr.checkEngineRelative("../../a/b"), 2)
        for bad in ("", ".", "engine", "../a/..", "../a/.", "..//a", "../a b", "/..", "..\\a"):
            with self.assertRaises(pe.EngineError, msg=repr(bad)):
                pr.checkEngineRelative(bad)

    def test_a_sibling_engine_is_one_leaf_symlink(self):
        self.verify("../engine")
        self.assertEqual(self.seen, [(True, True, True, True, True)])
        self.assertEqual(self.libraries, ["m"])

    def test_the_engine_root_above_the_runtime_gets_per_entry_symlinks(self):
        self.verify("..")
        self.assertEqual(self.seen, [(True, True, True, True, True)])
        self.assertEqual(self.libraries, ["m"])

    def test_a_deeper_engine_root_gets_per_entry_symlinks(self):
        self.verify("../..")
        self.assertEqual(self.seen, [(True, True, True, True, True)])
        self.assertEqual(self.libraries, ["m"])

    def test_an_engine_entry_named_like_the_runtime_is_refused(self):
        write(os.path.join(self.engine, "runtime", "x"))
        for relative in ("..", "../runtime"):
            with self.assertRaises(pe.EngineError, msg=relative):
                self.verify(relative)

    def test_the_verified_engine_is_never_written_into(self):
        before = sorted(os.listdir(self.engine))
        self.verify("..")
        self.assertEqual(sorted(os.listdir(self.engine)), before)
        self.assertEqual(sorted(os.listdir(self.runtime)), ["notices", "x86_64-linux-gnu.2.31",
                                                            "x86_64-linux-gnu.2.31.cfg"])

    def prove(self, relative, embedded):
        """pr.prove on a layout, with the sandbox, the checks and the engine contract mocked
        out. Returns what the relocated tree held when the config ran, plus the deny profile."""
        receipt = os.path.join(self.runtime, "notices", "runtime-provenance.json")
        data = json.loads(read(receipt))
        data["engineRelative"] = relative
        with open(receipt, "w") as f:
            json.dump(data, f)
        if embedded:
            shutil.move(self.runtime, os.path.join(self.engine, "runtime"))
            self.runtime = os.path.join(self.engine, "runtime")
        out = self.path("fake.bin")
        write(out, "bin")
        held, profiles, copies = [], [], []
        realCopytree = shutil.copytree

        def ran(run, clang, config, target, work, prefixes, libraries):
            base = os.path.dirname(config[1])
            held.append((os.path.isfile(clang), os.path.isfile(config[1]),
                         os.path.isdir(os.path.join(base, "runtime")),
                         os.path.islink(os.path.join(base, "x86_64-linux-gnu.2.31", "libm.so")), libraries))
            return out

        def sandboxed(profile, work, command):
            profiles.append(read(profile))
            return subprocess.CompletedProcess(command, 1, "", "denied")

        with mock.patch.object(pe, "verifyEngine", return_value=("aarch64-macos", "22.1.1", 0)), \
                mock.patch.object(pr, "checkConfig", side_effect=ran), \
                mock.patch.object(pr, "sandboxed", side_effect=sandboxed), \
                mock.patch.object(pr, "elfProblem", return_value=None), \
                mock.patch.object(pr, "elfInterpreterProblem", return_value=None), \
                mock.patch.object(pr, "glibcSymbolProblem", return_value=None), \
                mock.patch.object(shutil, "copytree", side_effect=lambda *a, **k: (
                    copies.append(a[0]) if isinstance(a[0], str) else None, realCopytree(*a, **k))[1]):
            pr.prove(self.engine, self.runtime, [], None, ["x86_64-linux-gnu.2.31"])
        return held, profiles[0], copies

    def test_prove_relocates_the_sibling_layout_as_two_trees(self):
        held, profile, copies = self.prove("../engine", embedded=False)
        self.assertEqual(held, [(True, True, False, True, ["m"])])
        self.assertEqual(sorted(copies), sorted([os.path.realpath(self.engine), os.path.realpath(self.runtime)]))
        self.assertEqual(profile.count('(deny file-read* (subpath "'), 2)

    def test_prove_relocates_the_engine_root_layout_without_copying_the_runtime_twice(self):
        held, profile, copies = self.prove("..", embedded=True)
        self.assertEqual(held, [(True, True, False, True, ["m"])])
        self.assertEqual(copies, [os.path.realpath(self.engine)])
        self.assertEqual(profile.count('(deny file-read* (subpath "'), 1)
        self.assertEqual(profile.count(os.path.realpath(self.engine)), 2)

    def test_prove_refuses_a_runtime_inside_the_engine_where_the_receipt_does_not_say(self):
        with self.assertRaisesRegex(pe.EngineError, "not where engineRelative"):
            self.prove("../engine", embedded=True)

    def test_prove_refuses_aliases_the_receipt_does_not_record_or_that_leave_the_directory(self):
        directory = os.path.join(self.runtime, "x86_64-linux-gnu.2.31")
        os.symlink("libm.so.6", os.path.join(directory, "libstray.so"))
        with self.assertRaisesRegex(pe.EngineError, "not the recorded aliases"):
            self.prove("..", embedded=False)

    def test_prove_refuses_a_receipt_from_before_library_aliases(self):
        receipt = os.path.join(self.runtime, "notices", "runtime-provenance.json")
        data = json.loads(read(receipt))
        del data["targets"][0]["libraryAliases"]
        with open(receipt, "w") as f:
            json.dump(data, f)
        with self.assertRaisesRegex(pe.EngineError, "prepare the runtime again"):
            self.prove("..", embedded=False)

    def test_prove_refuses_a_receipt_from_before_empty_archives(self):
        receipt = os.path.join(self.runtime, "notices", "runtime-provenance.json")
        data = json.loads(read(receipt))
        del data["targets"][0]["emptyArchives"]
        with open(receipt, "w") as f:
            json.dump(data, f)
        with self.assertRaisesRegex(pe.EngineError, "records no emptyArchives; prepare the runtime again"):
            self.prove("..", embedded=False)

    def test_prove_refuses_an_empty_archive_that_holds_a_member(self):
        directory = os.path.join(self.runtime, "x86_64-linux-gnu.2.31")
        write(os.path.join(directory, "libm.a"), "!<arch>\n")
        receipt = os.path.join(self.runtime, "notices", "runtime-provenance.json")
        data = json.loads(read(receipt))
        data["targets"][0]["emptyArchives"] = [{"name": "libm.a", "sha256": pe.sha256File(os.path.join(directory, "libm.a")),
                                                "bytes": 8}]
        with open(receipt, "w") as f:
            json.dump(data, f)
        self.prove("..", embedded=False)
        with open(os.path.join(directory, "libm.a"), "ab") as f:
            f.write(arMember("m.o/", b"\x00asm"))
        with self.assertRaisesRegex(pe.EngineError, "not an empty archive"):
            self.prove("..", embedded=False)

    def test_prove_refuses_an_engine_entry_on_the_runtime_location(self):
        write(os.path.join(self.engine, "runtime", "x"))
        with self.assertRaisesRegex(pe.EngineError, "collides"):
            self.prove("..", embedded=False)


class ProofHelperTest(TempCase):
    def test_elf_check_reads_class_and_machine(self):
        good = self.path("good")
        with open(good, "wb") as f:
            f.write(b"\x7fELF\x02\x01\x01" + b"\0" * 11 + (62).to_bytes(2, "little"))
        bad = self.path("bad")
        with open(bad, "wb") as f:
            f.write(b"\x7fELF\x02\x01\x01" + b"\0" * 11 + (183).to_bytes(2, "little"))
        self.assertIsNone(pr.elfProblem(good))
        self.assertIsNotNone(pr.elfProblem(bad))

    def test_elf_check_is_per_target(self):
        def header(machine, data=1):
            return b"\x7fELF\x02" + bytes([data]) + b"\x01" + b"\0" * 11 + machine.to_bytes(2, "little")
        x64, arm, big = "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31", self.path("big")
        for name, data in (("x64", header(62)), ("arm", header(183)), ("big", header(183, data=2))):
            with open(self.path(name), "wb") as f:
                f.write(data)
        self.assertEqual((pr.elfProblem(self.path("x64"), x64), pr.elfProblem(self.path("arm"), arm)), (None, None))
        self.assertIn("aarch64", pr.elfProblem(self.path("x64"), arm))
        self.assertIn("x86_64", pr.elfProblem(self.path("arm"), x64))
        self.assertIn("aarch64", pr.elfProblem(big, arm))
        self.assertEqual(sorted(pr.ELF_TARGETS), sorted(t for t in pr.TARGETS if "linux" in t))

    def elf(self, name, interpreters, machine=183):
        """A little-endian ELF64 with a program header per interpreter string, as written by ld."""
        phoff, phsize = 64, 56
        body = bytearray(b"\0" * (phoff + phsize * len(interpreters)))
        body[:20] = b"\x7fELF\x02\x01\x01" + b"\0" * 11 + machine.to_bytes(2, "little")
        body[32:40] = phoff.to_bytes(8, "little")
        body[54:58] = phsize.to_bytes(2, "little") + len(interpreters).to_bytes(2, "little")
        for index, text in enumerate(interpreters):
            start = len(body)
            body += text
            header = phoff + index * phsize
            body[header:header + 4] = (3).to_bytes(4, "little")
            body[header + 8:header + 16] = start.to_bytes(8, "little")
            body[header + 32:header + 40] = len(text).to_bytes(8, "little")
        with open(self.path(name), "wb") as f:
            f.write(body)
        return self.path(name)

    def test_interpreter_is_the_loader_of_the_target(self):
        arm, x64 = "aarch64-linux-gnu.2.31", "x86_64-linux-gnu.2.31"
        self.assertIsNone(pr.elfInterpreterProblem(self.elf("a", [b"/lib/ld-linux-aarch64.so.1\0"]), arm))
        self.assertIsNone(pr.elfInterpreterProblem(self.elf("x", [b"/lib64/ld-linux-x86-64.so.2\0"], 62), x64))
        for name, interpreters, target in (("swap", [b"/lib64/ld-linux-x86-64.so.2\0"], arm),
                                           ("soname", [b"/lib/ld-linux-aarch64.so.2\0"], arm),
                                           ("none", [], arm),
                                           ("twice", [b"/lib/ld-linux-aarch64.so.1\0"] * 2, arm),
                                           ("noNul", [b"/lib/ld-linux-aarch64.so.1"], arm),
                                           ("longer", [b"/lib/ld-linux-aarch64.so.1x\0"], arm)):
            self.assertIn("interpreter is", pr.elfInterpreterProblem(self.elf(name, interpreters), target), msg=name)

    def test_glibc_symbol_oracle_matches_the_consumer_without_loosening_the_limit(self):
        with mock.patch.object(pe, "run", return_value=" U __libc_start_main@GLIBC_2.17\n U fputs@GLIBC_2.17\n"):
            self.assertIsNone(pr.glibcSymbolProblem("nm", "elf", requiredSymbol="__libc_start_main"))
            self.assertIn("printf", pr.glibcSymbolProblem("nm", "elf"))
        with mock.patch.object(pe, "run", return_value=" U __libc_start_main@GLIBC_2.17\n U memcpy@GLIBC_2.34\n"):
            self.assertIn("newer", pr.glibcSymbolProblem("nm", "elf", requiredSymbol="__libc_start_main"))
        with mock.patch.object(pe, "run", return_value=" U fputs@GLIBC_2.17\n"):
            self.assertIn("__libc_start_main", pr.glibcSymbolProblem("nm", "elf", requiredSymbol="__libc_start_main"))

    def test_glibc_version_limit(self):
        with mock.patch.object(pe, "run", return_value="  U printf@GLIBC_2.2.5\n  U memcpy@GLIBC_2.14\n"):
            self.assertIsNone(pr.glibcSymbolProblem("nm", "elf"))
        with mock.patch.object(pe, "run", return_value="  U printf@GLIBC_2.2.5\n  U x@GLIBC_2.34\n"):
            self.assertIn("newer", pr.glibcSymbolProblem("nm", "elf"))
        with mock.patch.object(pe, "run", return_value="  U puts@GLIBC_2.2.5\n"):
            self.assertIn("printf", pr.glibcSymbolProblem("nm", "elf"))


ET_EXEC = 2


def sharedElf(path, kind=pr.ET_DYN, interpreter=False, machine=62):
    """A little-endian ELF64 of the given e_type with one program header, a PT_INTERP or a PT_LOAD."""
    body = bytearray(b"\0" * (64 + 56))
    body[:20] = b"\x7fELF\x02\x01\x01" + b"\0" * 11 + machine.to_bytes(2, "little")
    body[16:18] = kind.to_bytes(2, "little")
    body[32:40] = (64).to_bytes(8, "little")
    body[54:58] = (56).to_bytes(2, "little") + (1).to_bytes(2, "little")
    body[64:68] = (3 if interpreter else 1).to_bytes(4, "little")
    with open(path, "wb") as f:
        f.write(body)
    return path


class SharedProfileTest(TempCase):
    def test_the_shared_targets_are_the_two_glibc_targets_and_the_executable_ones_are_unchanged(self):
        self.assertEqual(pr.selectTargets([], pr.SHARED_TARGETS), ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        self.assertEqual(pr.selectTargets(["aarch64-linux-gnu.2.31"], pr.SHARED_TARGETS), ["aarch64-linux-gnu.2.31"])
        for bad in (["wasm32-wasi"], ["x86_64-windows-gnu"], ["x86_64-linux-gnu"], ["x86_64-linux-gnu.2.31"] * 2):
            with self.assertRaises(pe.EngineError, msg=bad):
                pr.selectTargets(bad, pr.SHARED_TARGETS)
        self.assertEqual(list(pr.TARGETS), ["wasm32-wasi", "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        self.assertEqual(pr.TARGETS["x86_64-linux-gnu.2.31"]["driverFlags"], ["-nostdlib", "-no-pie"])

    def test_the_config_names_the_shared_directory_and_carries_shared_without_startup(self):
        compile_ = pr.parseCompileArgv(LINUX_COMPILE)
        items = [("arg", "-shared"), ("input", "/c/crti.o"), ("user", None), ("arg", "--as-needed"),
                 ("input", "/c/libc.so.6")]
        for target in pr.SHARED_TARGETS:
            directory = target + ".so"
            text = pr.renderConfig(target, pr.SHARED_TARGETS[target], compile_, items, ["generic-glibc"], "..", "22",
                                   directory)
            lines = text.splitlines()
            self.assertIn("--sysroot=<CFGDIR>/%s" % directory, lines)
            self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/%s" % directory, lines)
            self.assertIn("-Xlinker <CFGDIR>/%s/crti.o" % directory, lines)
            self.assertIn("-Xlinker <CFGDIR>/%s/libc.so.6" % directory, lines)
            self.assertIn("-shared", lines)
            self.assertIn("-Xlinker -shared", lines)
            self.assertIn("-isystem <CFGDIR>/include/libc/generic-glibc", lines)
            self.assertNotIn("-no-pie", lines)
            self.assertFalse([l for l in lines if "dynamic-linker" in l or "--entry" in l or "-pie" in l or "crt1" in l], text)
            self.assertNotIn("<CFGDIR>/%s/" % target, text)

    def test_the_default_directory_is_the_target_so_executable_config_bytes_do_not_move(self):
        compile_ = pr.parseCompileArgv(LINUX_COMPILE)
        items = [("arg", "-z"), ("input", "/c/crt1.o"), ("user", None)]
        target = "x86_64-linux-gnu.2.31"
        spec = pr.TARGETS[target]
        self.assertEqual(pr.renderConfig(target, spec, compile_, items, ["x86-linux-gnu"], "..", "22"),
                         pr.renderConfig(target, spec, compile_, items, ["x86-linux-gnu"], "..", "22", target))

    def test_a_shared_link_line_names_shared_once_and_carries_no_executable_startup(self):
        pr.checkSharedLink("ld.lld -shared -o out crti.o x.o --no-undefined-version")
        for line, text in (("ld.lld -o out x.o", "-shared 0 times"),
                           ("ld.lld -shared -shared -o out", "-shared 2 times"),
                           ("ld.lld -shared --dynamic-linker /l -o out", "--dynamic-linker"),
                           ("ld.lld -shared --no-dynamic-linker -o out", "--no-dynamic-linker"),
                           ("ld.lld -shared --entry _start -o out", "--entry"),
                           ("ld.lld -shared -pie -o out", "-pie"),
                           ("ld.lld -shared -soname libfixture.so -o out", "-soname")):
            with self.assertRaisesRegex(pe.EngineError, text):
                pr.checkSharedLink(line)

    def test_headers_are_the_runtimes_when_every_file_matches(self):
        zigLib, runtime = self.path("z", "lib"), self.path("rt")
        for root in (os.path.join(zigLib, "libc", "include"), os.path.join(runtime, "include", "libc")):
            write(os.path.join(root, "generic-glibc", "a", "h.h"), "same")
            write(os.path.join(root, "x86-linux-gnu", "h.h"), "same")
        isystem = [zigLib + "/include"] + ["%s/libc/include/%s" % (zigLib, n) for n in (
            "x86-linux-gnu", "x86-linux-any", "generic-glibc")]
        self.assertEqual(pr.sharedHeaders(isystem, runtime, zigLib), (["x86-linux-gnu", "generic-glibc"], ["x86-linux-any"]))
        write(os.path.join(runtime, "include", "libc", "generic-glibc", "a", "h.h"), "other")
        with self.assertRaisesRegex(pe.EngineError, "differs from"):
            pr.sharedHeaders(isystem, runtime, zigLib)
        shutil.rmtree(os.path.join(runtime, "include", "libc", "x86-linux-gnu"))
        with self.assertRaisesRegex(pe.EngineError, "differs from"):
            pr.sharedHeaders(isystem[:2], runtime, zigLib)
        with self.assertRaisesRegex(pe.EngineError, "first include directory"):
            pr.sharedHeaders(isystem[1:], runtime, zigLib)
        with self.assertRaisesRegex(pe.EngineError, "not directly under"):
            pr.sharedHeaders([zigLib + "/include", "/elsewhere/x86-linux-gnu"], runtime, zigLib)

    def test_a_linked_library_must_be_a_shared_object_of_the_target_with_no_interpreter(self):
        x64, arm = "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"
        self.assertIsNone(pr.elfSharedProblem(sharedElf(self.path("so")), x64))
        self.assertIsNone(pr.elfSharedProblem(sharedElf(self.path("arm"), machine=183), arm))
        self.assertIn("aarch64", pr.elfSharedProblem(sharedElf(self.path("so2")), arm))
        self.assertIn("not a shared object", pr.elfSharedProblem(sharedElf(self.path("exec"), kind=ET_EXEC), x64))
        self.assertIn("interpreter", pr.elfSharedProblem(sharedElf(self.path("pie"), interpreter=True), x64))

    def test_the_fixture_export_is_found_among_defined_dynamic_symbols(self):
        with mock.patch.object(pe, "run", return_value="0000000000001350 T addNumbers\n0000000000002000 D other\n"):
            self.assertIsNone(pr.exportedSymbolProblem("nm", "lib", "addNumbers"))
            self.assertIn("does not export missing", pr.exportedSymbolProblem("nm", "lib", "missing"))
        with mock.patch.object(pe, "run", return_value="") as run:
            self.assertIn("does not export", pr.exportedSymbolProblem("nm", "lib", "addNumbers"))
            self.assertEqual(run.call_args[0][0], ["nm", "-D", "--defined-only", "lib"])


class SharedRuntimeTest(ZigFixtureCase):
    def setUp(self):
        super().setUp()
        self.runtime = self.path("rt")
        pr.prepareRuntime(self.zig, self.engine, self.runtime, [])
        patcher = mock.patch.object(pr, "verifySharedConfigs")
        self.verify = patcher.start()
        self.addCleanup(patcher.stop)

    def rewriteZig(self, extra):
        """A different fake Zig, with the base runtime's receipt naming it as its maker."""
        self.writeZig(extra)
        path = self.path("rt", "notices", "runtime-provenance.json")
        write(path, json.dumps(dict(json.loads(read(path)), zig=pr.zigIdentity(self.zig))))

    def snapshot(self):
        return {os.path.relpath(os.path.join(d, n), self.runtime): pe.sha256File(os.path.join(d, n))
                for d, _, names in os.walk(self.runtime) for n in names if not os.path.islink(os.path.join(d, n))}

    def test_the_overlay_holds_only_the_shared_directory_config_and_receipt_of_each_target(self):
        before = self.snapshot()
        out, records = pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), [])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-linux-gnu.2.31.so", "aarch64-linux-gnu.2.31.so.cfg", "notices",
                                                    "x86_64-linux-gnu.2.31.so", "x86_64-linux-gnu.2.31.so.cfg"])
        self.assertEqual(os.listdir(self.path("so", "notices")), ["runtime-shared-provenance.json"])
        self.assertEqual(sorted(os.listdir(self.path("so", "x86_64-linux-gnu.2.31.so"))),
                         ["crti.o", "libc.so", "libc.so.6", "libc_nonshared.a"])
        self.assertEqual(os.readlink(self.path("so", "x86_64-linux-gnu.2.31.so", "libc.so")), "libc.so.6")
        config = read(self.path("so", "x86_64-linux-gnu.2.31.so.cfg"))
        lines = config.splitlines()
        for expected in ("--sysroot=<CFGDIR>/x86_64-linux-gnu.2.31.so", "-shared", "-Xlinker -shared",
                         "-Xlinker -L -Xlinker <CFGDIR>/x86_64-linux-gnu.2.31.so",
                         "-Xlinker <CFGDIR>/x86_64-linux-gnu.2.31.so/crti.o",
                         "-Xlinker <CFGDIR>/x86_64-linux-gnu.2.31.so/libc.so.6",
                         "-isystem <CFGDIR>/include/libc/x86-linux-gnu", "-fno-PIE -fPIC", "--ld-path=<CFGDIR>/../engine/bin/ld.lld"):
            self.assertIn(expected, lines)
        self.assertFalse([l for l in lines if "dynamic-linker" in l or "crt1" in l or "-no-pie" in l], config)
        self.assertNotIn(self.dir, config)
        arm = read(self.path("so", "aarch64-linux-gnu.2.31.so.cfg"))
        self.assertIn("-target aarch64-unknown-linux5.10.0-gnu2.31.0\n", arm)
        self.assertIn("-isystem <CFGDIR>/include/libc/aarch64-linux-gnu\n", arm)
        self.assertNotIn("-tme", arm)
        receipt = json.loads(read(self.path("so", "notices", "runtime-shared-provenance.json")))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual(receipt["baseRuntimeProvenanceSha256"],
                         pe.sha256File(self.path("rt", "notices", "runtime-provenance.json")))
        self.assertEqual([r["target"] for r in receipt["targets"]], ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        self.assertEqual(receipt["targets"][0]["linkArgs"], [
            "-shared", "$RT/x86_64-linux-gnu.2.31.so/crti.o", "$OBJECT", "--as-needed",
            "$RT/x86_64-linux-gnu.2.31.so/libc.so.6", "$RT/x86_64-linux-gnu.2.31.so/libc_nonshared.a"])
        self.assertEqual(self.verify.call_count, 1)

    def test_one_target_makes_only_its_files(self):
        out, _ = pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), ["aarch64-linux-gnu.2.31"])
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-linux-gnu.2.31.so", "aarch64-linux-gnu.2.31.so.cfg", "notices"])

    def test_zig_runs_a_shared_link_for_the_target(self):
        with mock.patch.object(pr, "runZig", wraps=pr.runZig) as run:
            pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), ["x86_64-linux-gnu.2.31"])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args[0][3]["zigArgs"], ["-shared"])
        self.assertEqual(run.call_args[0][3]["zigLinkArgs"], ["-lm", "-lpthread"])

    def test_an_executable_startup_token_in_the_shared_link_line_is_refused_and_leaves_nothing(self):
        for extra, token in (("--dynamic-linker /lib64/ld.so ", "--dynamic-linker"), ("-soname libfixture.so ", "-soname"),
                             ("--entry _start ", "--entry"), ("-pie ", "-pie")):
            self.rewriteZig(extra)
            with self.assertRaisesRegex(pe.EngineError, token):
                pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), [])
            self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("so")], [])

    def test_a_runtime_not_prepared_for_the_target_or_by_another_zig_or_already_holding_the_profile_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.runtime, [])
        write(self.path("bare", "notices", "other"))
        with self.assertRaisesRegex(pe.EngineError, "no notices/runtime-provenance.json"):
            pr.prepareSharedRuntime(self.zig, self.engine, self.path("bare"), self.path("so"), [])
        receiptPath = self.path("rt", "notices", "runtime-provenance.json")
        receipt = json.loads(read(receiptPath))
        write(receiptPath, json.dumps(dict(receipt, targets=receipt["targets"][:2])))
        with self.assertRaisesRegex(pe.EngineError, "was not prepared for aarch64-linux-gnu.2.31"):
            pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), [])
        write(receiptPath, json.dumps(dict(receipt, zig={"version": "0.16.0", "sha256": "0" * 64})))
        with self.assertRaisesRegex(pe.EngineError, "prepared by Zig"):
            pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), [])
        write(receiptPath, json.dumps(receipt))
        os.makedirs(self.path("rt", "x86_64-linux-gnu.2.31.so"))
        with self.assertRaisesRegex(pe.EngineError, "already has x86_64-linux-gnu.2.31.so"):
            pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), [])
        self.assertFalse(os.path.exists(self.path("so")))

    def test_a_header_directory_that_differs_from_the_runtimes_is_refused(self):
        write(os.path.join(self.lib, "libc", "include", "generic-glibc", "h.h"), "changed")
        with self.assertRaisesRegex(pe.EngineError, "differs from"):
            pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, self.path("so"), [])
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("so")], [])

    def test_existing_output_is_never_replaced_even_when_claimed_while_producing(self):
        out = self.path("so")
        original = pr.writeSharedProvenance

        def claimWhileProducing(*args):
            os.makedirs(out)
            original(*args)

        with mock.patch.object(pr, "writeSharedProvenance", side_effect=claimWhileProducing):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pr.prepareSharedRuntime(self.zig, self.engine, self.runtime, out, [])
        self.assertEqual(os.listdir(out), [])
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("so.partial")], [])

    def test_the_command_line_writes_the_overlay_and_reports_each_target(self):
        argv = ["--shared", "--zig", self.zig, "--engine", self.engine, "--runtime", self.runtime,
                "--output", self.path("so"), "--target", "x86_64-linux-gnu.2.31"]
        self.assertEqual(pr.main(argv), 0)
        self.assertTrue(os.path.isfile(self.path("so", "x86_64-linux-gnu.2.31.so.cfg")))
        self.assertEqual(pr.main(argv), 1)
        with self.assertRaises(SystemExit):
            pr.main(["--shared", "--zig", self.zig, "--engine", self.engine, "--output", self.path("so2")])


if __name__ == "__main__":
    unittest.main()
