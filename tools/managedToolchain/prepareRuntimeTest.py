import json
import os
import shutil
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
        linker, items = pr.parseLinkArgv(line, "/out/a", "fixture.o", cache)
        self.assertEqual(linker, "ld.lld")
        self.assertEqual(items, [("arg", "-z"), ("arg", "stack-size=1"), ("input", cache + "/crt1.o"),
                                 ("arg", "--dynamic-linker"), ("arg", "/lib64/ld.so"), ("user", None),
                                 ("input", cache + "/libc.a")])

    def test_link_input_outside_the_private_cache_is_refused(self):
        cache = self.cacheWith("fixture.o")
        outside = self.path("elsewhere", "libc.a")
        write(outside)
        with self.assertRaises(pe.EngineError):
            pr.parseLinkArgv("ld.lld -o /o %s %s/fixture.o" % (outside, cache), "/o", "fixture.o", cache)

    def test_missing_relative_or_duplicate_fixture_inputs_are_refused(self):
        cache = self.cacheWith("fixture.o")
        for line in ("ld.lld -o /o %s/gone.a %s/fixture.o" % (cache, cache),
                     "ld.lld -o /o libc.a %s/fixture.o" % cache,
                     "ld.lld -o /o",
                     "ld.lld -o /o %s/fixture.o %s/fixture.o" % (cache, cache),
                     "ld.lld -o /other %s/fixture.o" % cache):
            with self.assertRaises(pe.EngineError, msg=line):
                pr.parseLinkArgv(line, "/o", "fixture.o", cache)

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
    def test_allowlist_is_exactly_the_two_existing_targets(self):
        self.assertEqual(pr.selectTargets([]), ["wasm32-wasi", "x86_64-linux-gnu.2.31"])
        self.assertEqual(pr.selectTargets(["wasm32-wasi"]), ["wasm32-wasi"])
        for bad in (["aarch64-linux-gnu.2.31"], ["x86_64-linux-gnu"], ["wasm32-wasi", "wasm32-wasi"]):
            with self.assertRaises(pe.EngineError):
                pr.selectTargets(bad)

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
            "# generated by prepareRuntime.py for wasm32-wasi; do not edit",
            "-target wasm32-wasip1",
            "-Xclang -target-cpu -Xclang lime1",
            "-fno-PIE -fno-PIC",
            "-nostdinc",
            "-isystem <CFGDIR>/../engine/lib/clang/22/include",
            "-isystem <CFGDIR>/include/libc/wasm-wasi-musl",
            "-isystem <CFGDIR>/include/libc/generic-musl",
            "-nostdlib",
            "--ld-path=<CFGDIR>/../engine/bin/wasm-ld",
            "-Xlinker --entry",
            "-Xlinker _start",
            "-Xlinker <CFGDIR>/wasm32-wasi/crt1-command.o",
            "-Xlinker <CFGDIR>/wasm32-wasi/libc.a"])

    def test_linux_config_keeps_no_pie_and_the_glibc_define(self):
        compile_ = pr.parseCompileArgv(LINUX_COMPILE)
        text = pr.renderConfig("x86_64-linux-gnu.2.31", pr.TARGETS["x86_64-linux-gnu.2.31"], compile_, [],
                               ["x86-linux-gnu"], "../engine", "22")
        self.assertIn("-D__GLIBC_MINOR__=31\n", text)
        self.assertIn("-no-pie\n", text)
        self.assertIn("--ld-path=<CFGDIR>/../engine/bin/ld.lld\n", text)


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
else:
    for d in ("x86-linux-gnu", "generic-glibc"):
        isystem += " -isystem %%s/libc/include/%%s" %% (lib, d)
    triple, flags, cpu = "x86_64-unknown-linux5.10.0-gnu2.31.0", "-fno-PIE -fPIC -D__GLIBC_MINOR__=31", "x86-64"
    link = "ld.lld -z stack-size=1 -o %%s %%s --dynamic-linker /lib64/ld.so %%s --as-needed %%s %%s" %% (
        out, make("crt1.o"), make(stem + ".o"), make("libc.so.6"), make("libc_nonshared.a"))
sys.stderr.write("ar rcs %%s/x.a\\n" %% cache)
sys.stderr.write("%%s clang %%s -target %%s %%s %%s -Xclang -target-cpu -Xclang %%s -c -o /t/o.o\\n" %% (
    sys.argv[0], fixture, triple, flags, isystem, cpu))
sys.stderr.write(link + "\\n")
"""


class PipelineTest(TempCase):
    def setUp(self):
        super().setUp()
        self.lib = self.path("zig", "lib")
        for name in ("wasm-wasi-musl", "generic-musl", "x86-linux-gnu", "generic-glibc"):
            write(os.path.join(self.lib, "libc", "include", name, "h.h"))
        for rel in ("../LICENSE", "libc/musl/COPYRIGHT", "libc/glibc/LICENSES") + tuple(
                "libc/wasi/" + n for n in pr.WASI_LICENSES):
            write(os.path.normpath(os.path.join(self.lib, rel)), "license " + rel)
        self.zig = self.path("zig", "zigfake")
        write(self.zig, FAKE_ZIG % {"python": sys.executable, "lib": self.lib})
        os.chmod(self.zig, 0o755)
        self.engine = self.path("engine")
        os.makedirs(self.engine)
        for patcher in (mock.patch.object(pe, "verifyEngine", return_value=("aarch64-macos", "22.1.1", 0)),
                        mock.patch.object(pr, "normalizeInput")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_both_targets_produce_a_relocatable_payload(self):
        out = self.path("rt")
        pr.prepareRuntime(self.zig, self.engine, out, [])
        self.assertEqual(sorted(os.listdir(out)), ["include", "notices", "wasm32-wasi",
                                                    "wasm32-wasi.cfg", "x86_64-linux-gnu.2.31",
                                                    "x86_64-linux-gnu.2.31.cfg"])
        self.assertEqual(sorted(os.listdir(self.path("rt", "wasm32-wasi"))),
                         ["crt1-command.o", "libc.a", "libcompiler_rt.a"])
        self.assertEqual(read(self.path("rt", "x86_64-linux-gnu.2.31", "libc.so.6")), "artifact libc.so.6")
        self.assertEqual(sorted(os.listdir(self.path("rt", "include", "libc"))),
                         ["generic-glibc", "generic-musl", "wasm-wasi-musl", "x86-linux-gnu"])
        config = read(self.path("rt", "wasm32-wasi.cfg"))
        self.assertIn("-Xlinker <CFGDIR>/wasm32-wasi/libc.a\n", config)
        self.assertNotIn(self.dir, config)
        self.assertEqual(read(self.path("rt", "notices", "glibc", "LICENSES")), "license libc/glibc/LICENSES")
        self.assertEqual(read(self.path("rt", "notices", "zig", "LICENSE")), "license ../LICENSE")
        receipt = json.loads(read(self.path("rt", "notices", "runtime-provenance.json")))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual([t["target"] for t in receipt["targets"]], ["wasm32-wasi", "x86_64-linux-gnu.2.31"])
        self.assertEqual(receipt["targets"][0]["linkArgs"][2:],
                         ["$RT/wasm32-wasi/crt1-command.o", "$RT/wasm32-wasi/libc.a", "$OBJECT",
                          "$RT/wasm32-wasi/libcompiler_rt.a"])
        self.assertEqual(receipt["zig"]["version"], "0.16.0")
        self.assertEqual(os.listdir(self.dir).count("rt"), 1)

    def test_existing_output_is_never_replaced(self):
        os.makedirs(self.path("rt"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pr.prepareRuntime(self.zig, self.engine, self.path("rt"), [])

    def test_unsupported_target_is_refused_before_zig_runs(self):
        with self.assertRaises(pe.EngineError):
            pr.prepareRuntime(self.path("no-such-zig"), self.engine, self.path("rt"), ["aarch64-linux-gnu.2.31"])
        self.assertFalse(os.path.exists(self.path("rt")))

    def test_engine_relative_path_must_be_plain(self):
        for bad in ("/abs/engine", "a//b", "a b", "../en gine", ""):
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


class ArchiveTest(unittest.TestCase):
    def test_members_come_back_in_order_with_long_names_and_without_the_symbol_table(self):
        long = b"/private/tmp/cache/abc/closedir.o/\n"
        data = (b"!<arch>\n" + arMember("/", b"\0\0\0\0") + arMember("//", long)
                + arMember("/0", b"odd") + arMember("short.o/", b"even"))
        self.assertEqual(pr.parseArchive(data), [("/private/tmp/cache/abc/closedir.o", b"odd"),
                                                 ("short.o", b"even")])

    def test_unsupported_archives_are_refused(self):
        for data in (b"not an archive", b"!<arch>\n" + arMember("#1/20", b"x" * 20),
                     b"!<arch>\n" + arMember("a.o/", b"abc")[:-2]):
            with self.assertRaises(pe.EngineError):
                pr.parseArchive(data)


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

    def test_glibc_version_limit(self):
        with mock.patch.object(pe, "run", return_value="  U printf@GLIBC_2.2.5\n  U memcpy@GLIBC_2.14\n"):
            self.assertIsNone(pr.glibcSymbolProblem("nm", "elf"))
        with mock.patch.object(pe, "run", return_value="  U printf@GLIBC_2.2.5\n  U x@GLIBC_2.34\n"):
            self.assertIn("newer", pr.glibcSymbolProblem("nm", "elf"))
        with mock.patch.object(pe, "run", return_value="  U puts@GLIBC_2.2.5\n"):
            self.assertIn("printf", pr.glibcSymbolProblem("nm", "elf"))


if __name__ == "__main__":
    unittest.main()
