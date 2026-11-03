import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareRuntime as pr
import prepareSanitizerRuntime as ps

SHA = "a" * 64


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareSanitizerRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def source(self, version=("22", "1", "8")):
        text = "".join("set(LLVM_VERSION_%s %s)\n" % (n, v) for n, v in zip(("MAJOR", "MINOR", "PATCH"), version))
        write(self.path("src", "cmake", "Modules", "LLVMVersion.cmake"), text)
        write(self.path("src", "compiler-rt", "LICENSE.TXT"), "license\n")
        return self.path("src")


class TargetTest(unittest.TestCase):
    def test_glibc_gets_every_sanitizer_musl_both_ubsans_and_windows_only_the_standalone_one(self):
        self.assertEqual(ps.TARGETS["aarch64-linux-gnu.2.31"]["triple"], "aarch64-unknown-linux-gnu")
        self.assertEqual([c[0] for c in ps.casesOf("aarch64-linux-gnu.2.31")],
                         ["address", "undefined", "undefined-abort", "thread", "undefined-minimal"])
        for target in ("x86_64-linux-musl", "aarch64-linux-musl"):
            self.assertEqual([c[0] for c in ps.casesOf(target)], ["undefined", "undefined-abort", "undefined-minimal"], msg=target)
        for target in ("x86_64-windows-gnu", "aarch64-windows-gnu"):
            self.assertEqual([c[0] for c in ps.casesOf(target)], ["undefined", "undefined-abort"], msg=target)
        self.assertNotIn("ubsan_minimal", ps.TARGETS["x86_64-windows-gnu"]["runtimes"])

    def test_a_target_outside_the_table_or_twice_is_refused(self):
        self.assertEqual(ps.selectTargets([]), list(ps.TARGETS))
        for bad in (["wasm32-wasi"], ["x86_64-linux-gnu"], ["x86_64-linux-musl", "x86_64-linux-musl"]):
            with self.assertRaises(pe.EngineError):
                ps.selectTargets(bad)

    def test_linux_runtimes_go_where_the_driver_looks_and_windows_ones_beside_the_config_directory(self):
        self.assertEqual(ps.overlayDirectory(ps.TARGETS["x86_64-linux-gnu.2.31"], "x86_64-linux-gnu.2.31", "22"),
                         "lib/clang/22/lib/x86_64-unknown-linux-gnu")
        self.assertEqual(ps.overlayDirectory(ps.TARGETS["aarch64-linux-musl"], "aarch64-linux-musl", "23"),
                         "lib/clang/23/lib/aarch64-unknown-linux-musl")
        self.assertEqual(ps.overlayDirectory(ps.TARGETS["aarch64-windows-gnu"], "aarch64-windows-gnu", "22"),
                         "runtime/windows/aarch64-windows-gnu")


class ConfigureTest(unittest.TestCase):
    def test_the_build_uses_the_engine_clang_through_the_config_and_builds_no_other_component(self):
        arguments = ps.cmakeArguments(ps.TARGETS["x86_64-windows-gnu"], "/s", "/e", "/r/c.cfg", "/b", "/n")
        self.assertIn("-DCMAKE_C_COMPILER=/e/bin/clang", arguments)
        self.assertIn("-DCMAKE_C_FLAGS=--no-default-config --config=/r/c.cfg", arguments)
        self.assertIn("-DCMAKE_SYSTEM_NAME=Windows", arguments)
        self.assertIn("-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu", arguments)
        for name in ps.DISABLED_COMPONENTS:
            self.assertIn("-DCOMPILER_RT_BUILD_%s=OFF" % name, arguments)
        self.assertEqual(arguments[:2], ["-S", "/s/runtimes"])


class SourceTest(TempCase):
    def test_the_version_comes_from_the_tree_and_a_missing_or_unreadable_one_is_refused(self):
        self.assertEqual(ps.sourceVersion(self.source()), "22.1.8")
        with self.assertRaisesRegex(pe.EngineError, "not an extracted llvm-project"):
            ps.sourceVersion(self.path("nothing"))
        write(self.path("bad", "cmake", "Modules", "LLVMVersion.cmake"), "nothing\n")
        with self.assertRaisesRegex(pe.EngineError, "names no LLVM version"):
            ps.sourceVersion(self.path("bad"))


class ProduceTest(TempCase):
    def setUp(self):
        super().setUp()
        self.engine, self.runtime = self.path("engine"), self.path("runtime")
        for target in ps.TARGETS.values():
            write(os.path.join(self.runtime, target["config"]))
        for tool in ("cmake", "ninja"):
            write(self.path(tool), "#!/bin/sh\n")
            os.chmod(self.path(tool), 0o755)

    def fakeBuild(self, cmake, ninja, source, engine, runtime, target, work, jobs):
        built = {}
        for name in ps.TARGETS[target]["runtimes"]:
            built[name] = os.path.join(work, target + "-" + name)
            write(built[name], "archive %s %s\n" % (target, name))
        return built

    def prepare(self, **changes):
        arguments = dict(engine=self.engine, runtime=self.runtime, source=self.path("src"), sourceSha256=SHA,
                         cmake=self.path("cmake"), ninja=self.path("ninja"), output=self.path("out"), targets=None)
        arguments.update(changes)
        if not os.path.isdir(arguments["source"]):
            self.source()
        with mock.patch.object(pr, "engineMajor", return_value=("aarch64-macos", "22.1.8", "22")), \
                mock.patch.object(ps, "buildTarget", side_effect=self.fakeBuild), \
                mock.patch.object(ps, "archiveProblem", return_value=None), \
                mock.patch.object(ps, "importLibrary", side_effect=lambda e, s, w, out: write(out, "import\n")):
            return ps.prepareSanitizerRuntime(**arguments)

    def test_the_overlay_holds_each_target_archives_the_receipt_and_the_license(self):
        output, receipt = self.prepare()
        self.assertTrue(os.path.isfile(os.path.join(output, "lib/clang/22/lib/x86_64-unknown-linux-gnu/libclang_rt.asan.a")))
        self.assertTrue(os.path.isfile(os.path.join(output, "lib/clang/22/lib/aarch64-unknown-linux-musl/libclang_rt.ubsan_minimal.a")))
        self.assertTrue(os.path.isfile(os.path.join(output, "lib/clang/22/lib/aarch64-unknown-linux-musl/libclang_rt.ubsan_standalone.a")))
        windows = "runtime/windows/aarch64-windows-gnu/"
        self.assertTrue(os.path.isfile(os.path.join(output, windows + "libclang_rt.ubsan_standalone.a")))
        self.assertTrue(os.path.isfile(os.path.join(output, windows + "libsynchronization.a")))
        self.assertTrue(os.path.isfile(os.path.join(output, ps.LICENSE)))
        with open(os.path.join(output, ps.PROVENANCE)) as f:
            written = json.load(f)
        self.assertEqual(written, receipt)
        self.assertEqual((written["redistributionCertified"], written["source"]["archiveSha256"]), (False, SHA))
        record = next(t for t in written["targets"] if t["target"] == "x86_64-linux-gnu.2.31")
        self.assertEqual(sorted(f["name"] for f in record["files"]), sorted("libclang_rt.%s.a" % n for n in ps.GLIBC_RUNTIMES))

    def test_a_source_of_another_version_a_bad_digest_a_missing_config_or_an_existing_output_is_refused(self):
        for changes, message in (({"source": self.source(("23", "1", "4"))}, "is LLVM 23.1.4"), ({"sourceSha256": "xyz"}, "sha256"),
                                 ({"targets": ["wasm32-wasi"]}, "no sanitizer runtime")):
            with self.assertRaisesRegex(pe.EngineError, message):
                self.prepare(**changes)
        os.remove(os.path.join(self.runtime, "x86_64-linux-musl.cfg"))
        with self.assertRaisesRegex(pe.EngineError, "has no x86_64-linux-musl.cfg"):
            self.prepare()
        os.makedirs(self.path("taken"))
        with self.assertRaisesRegex(pe.EngineError, "exists"):
            self.prepare(output=self.path("taken"), targets=["x86_64-linux-gnu.2.31"])
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])

    def test_a_failing_build_leaves_no_output_or_partial(self):
        with mock.patch.object(pr, "engineMajor", return_value=("aarch64-macos", "22.1.8", "22")), \
                mock.patch.object(ps, "buildTarget", side_effect=pe.EngineError("ninja failed")):
            with self.assertRaisesRegex(pe.EngineError, "ninja failed"):
                ps.prepareSanitizerRuntime(self.engine, self.runtime, self.source(), SHA, self.path("cmake"),
                                           self.path("ninja"), self.path("out"), ["x86_64-linux-gnu.2.31"])
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("out")], [])


class ImportLibraryTest(TempCase):
    def test_the_definition_names_the_three_calls_and_the_machine_follows_the_target(self):
        with mock.patch.object(pe, "run") as run:
            ps.importLibrary("/e", ps.TARGETS["aarch64-windows-gnu"], self.dir, self.path("lib.a"))
        command = run.call_args[0][0]
        self.assertEqual((command[0], command[1:3]), ("/e/bin/llvm-dlltool", ["-m", "arm64"]))
        with open(self.path("synchronization.def")) as f:
            self.assertIn("WaitOnAddress", f.read())


class ProveTest(unittest.TestCase):
    def test_a_host_runs_only_the_machine_and_system_of_the_target(self):
        with mock.patch.object(sys, "platform", "linux"), mock.patch.object(ps.platform, "machine", return_value="aarch64"):
            self.assertEqual([t for t in ps.TARGETS if ps.hostRuns(t)], ["aarch64-linux-gnu.2.31", "aarch64-linux-musl"])
        with mock.patch.object(sys, "platform", "darwin"):
            self.assertEqual([t for t in ps.TARGETS if ps.hostRuns(t)], [])
        with mock.patch.object(sys, "platform", "win32"):
            self.assertEqual([t for t in ps.TARGETS if ps.hostRuns(t)], ["x86_64-windows-gnu"])

    def test_the_c_config_pair_puts_the_cxx_config_first_only_for_linux_targets_that_have_one(self):
        with tempfile.TemporaryDirectory() as bundle:
            write(os.path.join(bundle, "runtime", "x86_64-linux-gnu.2.31.cxx.cfg"))
            write(os.path.join(bundle, "runtime", "windows", "x86_64-windows-gnu.cxx.cfg"))
            linux = ps.configPair(bundle, "x86_64-linux-gnu.2.31")
            self.assertEqual((len(linux), linux[0], linux[-1]), (4, "--no-default-config", "--target=x86_64-unknown-linux-gnu"))
            self.assertTrue(linux[1].endswith(".cxx.cfg") and linux[2].endswith("x86_64-linux-gnu.2.31.cfg"))
            self.assertEqual(len(ps.configPair(bundle, "x86_64-windows-gnu")), 2)
            self.assertEqual(len(ps.configPair(bundle, "aarch64-linux-gnu.2.31")), 3)


if __name__ == "__main__":
    unittest.main()
