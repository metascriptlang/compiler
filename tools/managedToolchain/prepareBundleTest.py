import hashlib
import itertools
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

import prepareBundle as pb
import prepareCppRuntime as pc
import prepareDarwinRuntime as pd
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSanitizerRuntime as san
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


class BundleCase(unittest.TestCase):
    runtimeReceipt = {"kind": "runtime"}

    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareBundleTest-"))
        self.addCleanup(shutil.rmtree, self.dir)
        self.engine = self.path("engine")
        write(os.path.join(self.engine, "bin", "clang-22"), "clang")
        os.symlink("clang-22", os.path.join(self.engine, "bin", "clang"))
        write(os.path.join(self.engine, "lib", "dep.dylib"))
        write(os.path.join(self.engine, "notices", "provenance.json"), '{"kind": "engine"}\n')
        pe.writeContract(self.engine, "aarch64-macos", "22.1.1")
        self.engineIdentity = read(os.path.join(self.engine, "IDENTITY")).strip()
        self.verified = []
        self.runtimeCalls = []
        self.windowsCalls = []
        self.darwinCalls = []
        self.cppCalls = []
        self.sharedCalls = []
        for patcher in (mock.patch.object(pe, "verifyEngine", side_effect=self.verify),
                        mock.patch.object(pr, "prepareRuntime", side_effect=self.prepareRuntime),
                        mock.patch.object(pr, "prepareSharedRuntime", side_effect=self.prepareShared),
                        mock.patch.object(pw, "prepareWindowsRuntime", side_effect=self.prepareWindows),
                        mock.patch.object(pd, "prepareDarwinRuntime", side_effect=self.prepareDarwin),
                        mock.patch.object(pc, "addCppRuntime", side_effect=self.addCpp)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def verify(self, root):
        self.verified.append(root)
        return "aarch64-macos", "22.1.1", 0

    def prepareRuntime(self, zig, engine, output, targets, engineRelative):
        self.runtimeCalls.append((zig, engine, output, targets, engineRelative))
        write(os.path.join(output, "x86_64-linux-gnu.2.31.cfg"), "-target x\n")
        write(os.path.join(output, "aarch64-linux-gnu.2.31.cfg"), "-target a\n")
        write(os.path.join(output, "aarch64-linux-gnu.2.31", "libc.so.6"), "arm stub\n")
        write(os.path.join(output, "notices", "runtime-provenance.json"), json.dumps(self.runtimeReceipt) + "\n")
        write(os.path.join(output, "x86_64-linux-gnu.2.31", "libm.so.6"), "stub\n")
        os.symlink("libm.so.6", os.path.join(output, "x86_64-linux-gnu.2.31", "libm.so"))
        write(os.path.join(output, "wasm32-wasi", "libm.a"), "!<arch>\n")
        return output, []

    def prepareShared(self, zig, engine, runtime, output, targets):
        self.sharedCalls.append((zig, engine, runtime, output, targets))
        for target in targets:
            directory = pr.sharedDirectory(target)
            write(os.path.join(output, directory + ".cfg"), read(os.path.join(runtime, target + ".cfg")) + "-shared\n")
            write(os.path.join(output, directory, "libc.so.6"), "shared stub\n")
        write(os.path.join(output, pr.SHARED_PROVENANCE), json.dumps({"targets": [{"target": t} for t in targets]}))
        return output, []

    def prepareWindows(self, zig, engine, windows, targets=None):
        self.windowsCalls.append((zig, engine, windows, targets))
        write(os.path.join(windows, "x86_64-windows-gnu.cfg"), "-target w\n")
        write(os.path.join(windows, "notices", pw.PROVENANCE), '{"kind": "windows"}\n')
        return windows, []

    def prepareDarwin(self, zig, engine, darwin, targets=None):
        self.darwinCalls.append((zig, engine, darwin, targets))
        for target in targets or pd.TARGETS:
            write(os.path.join(darwin, pd.configName(target)), pd.renderDarwinConfig(target))
        write(os.path.join(darwin, "notices", pd.PROVENANCE), '{"kind": "darwin"}\n')
        return darwin, []

    def addCpp(self, zig, engine, runtime, targets=None, seed=None):
        self.cppCalls.append((zig, engine, runtime, targets, sorted(os.listdir(runtime))))
        for target in targets:
            write(os.path.join(runtime, pc.VARIANTS[(target, "exe")]["config"]), "-isystem cxx\n")
            if target in pc.LINUX_TARGETS and os.path.isfile(os.path.join(runtime, pr.sharedDirectory(target) + ".cfg")):
                write(os.path.join(runtime, pc.VARIANTS[(target, "so")]["config"]), "-isystem shared cxx\n")
        write(os.path.join(runtime, pc.PROVENANCE), '{"kind": "cpp"}\n')
        return {}


class BundleTest(BundleCase):
    def test_the_bundle_keeps_engine_contents_at_the_root_and_the_runtime_as_a_child(self):
        out = self.path("out", "bundle")
        self.assertEqual(pb.prepareBundle(self.engine, "/z/zig", out, ["t"]), out)
        self.assertEqual(sorted(os.listdir(out)), ["FILES.sha256", "HOST", "IDENTITY", "VERSION", "bin", "lib",
                                                   "notices", "runtime"])
        self.assertEqual(os.readlink(os.path.join(out, "bin", "clang")), "clang-22")
        self.assertEqual(read(os.path.join(out, "runtime", "x86_64-linux-gnu.2.31.cfg")), "-target x\n")
        zig, source, runtime, targets, engineRelative = self.runtimeCalls[0]
        self.assertEqual((zig, source, targets, engineRelative), ("/z/zig", self.engine, ["t"], ".."))
        self.assertEqual(os.path.basename(runtime), "runtime")
        self.assertTrue(os.path.dirname(runtime).startswith(out + ".partial-"))

    def test_no_target_prepares_every_runtime_and_the_windows_runtime_is_a_child_of_runtime(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        self.assertEqual(self.runtimeCalls[0][3:], ([], ".."))
        zig, source, windows, targets = self.windowsCalls[0]
        self.assertEqual((zig, source, os.path.basename(windows), os.path.basename(os.path.dirname(windows)), targets),
                         ("/z/zig", self.engine, "windows", "runtime", None))
        self.assertEqual(read(os.path.join(out, "runtime", "windows", "x86_64-windows-gnu.cfg")), "-target w\n")
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertEqual(receipt["runtimeProvenance"], "runtime/notices/runtime-provenance.json")
        self.assertEqual(receipt["windowsRuntimeProvenance"], "runtime/windows/notices/windows-provenance.json")
        for name in (receipt["runtimeProvenance"], receipt["windowsRuntimeProvenance"]):
            self.assertTrue(os.path.isfile(os.path.join(out, name)))

    def test_every_supported_runtime_gets_cpp_after_its_shared_c_bases_and_the_receipt_names_c_only_targets(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        zig, source, runtime, targets, present = self.cppCalls[0]
        self.assertEqual((zig, source, targets), ("/z/zig", self.engine,
                         ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31", "x86_64-windows-gnu", "aarch64-macos", "x86_64-macos"]))
        self.assertEqual((os.path.basename(runtime), present), ("runtime", [
            "aarch64-linux-gnu.2.31", "aarch64-linux-gnu.2.31.cfg", "aarch64-linux-gnu.2.31.so", "aarch64-linux-gnu.2.31.so.cfg",
            "darwin", "notices", "wasm32-wasi", "windows", "x86_64-linux-gnu.2.31", "x86_64-linux-gnu.2.31.cfg",
            "x86_64-linux-gnu.2.31.so", "x86_64-linux-gnu.2.31.so.cfg"]))
        self.assertEqual(self.sharedCalls[0][0:3], ("/z/zig", self.engine, runtime))
        self.assertEqual(self.sharedCalls[0][4], ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertEqual(receipt["cppRuntimeProvenance"], "runtime/notices/cpp-provenance.json")
        self.assertEqual(receipt["cppTargets"], ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31", "x86_64-windows-gnu",
                                                 "aarch64-macos", "x86_64-macos"])
        self.assertEqual(receipt["sharedTargets"], ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"])
        self.assertEqual(receipt["sharedRuntimeProvenance"], "runtime/" + pr.SHARED_PROVENANCE)
        self.assertEqual(receipt["cOnlyTargets"], ["wasm32-wasi", "aarch64-windows-gnu"])
        listed = [l.split("  ", 1)[1] for l in read(os.path.join(out, "FILES.sha256")).splitlines()]
        for rel in ("runtime/x86_64-linux-gnu.2.31.cxx.cfg", "runtime/aarch64-linux-gnu.2.31.cxx.cfg",
                    "runtime/x86_64-linux-gnu.2.31.so.cxx.cfg", "runtime/aarch64-linux-gnu.2.31.so.cxx.cfg",
                    "runtime/darwin/aarch64-macos.cxx.cfg", "runtime/darwin/x86_64-macos.cxx.cfg",
                    "runtime/" + pr.SHARED_PROVENANCE, "runtime/notices/cpp-provenance.json"):
            self.assertIn(rel, listed)

    def test_an_engine_of_another_host_than_linux_gets_no_target_runtime_directory(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        self.assertFalse(os.path.exists(os.path.join(out, "lib", "clang")))
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertNotIn("targetRuntimeDirectories", receipt)

    def test_the_cpp_overlay_follows_the_selected_targets_only(self):
        for requested, cpp, cOnly in ((["x86_64-windows-gnu"], ["x86_64-windows-gnu"], []),
                                      (["x86_64-linux-gnu.2.31", "aarch64-windows-gnu"], ["x86_64-linux-gnu.2.31"],
                                       ["aarch64-windows-gnu"]),
                                      (["aarch64-linux-gnu.2.31"], ["aarch64-linux-gnu.2.31"], []),
                                      (["aarch64-macos"], ["aarch64-macos"], []),
                                      (["x86_64-macos", "aarch64-macos"], ["aarch64-macos", "x86_64-macos"], []),
                                      (["wasm32-wasi"], None, None), (["aarch64-windows-gnu"], None, None)):
            self.cppCalls.clear()
            out = self.path("bundle-" + "-".join(requested))
            pb.prepareBundle(self.engine, "/z/zig", out, requested)
            receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
            self.assertEqual([call[3] for call in self.cppCalls], [cpp] if cpp else [], msg=requested)
            self.assertEqual(receipt.get("cppTargets"), cpp, msg=requested)
            self.assertEqual(receipt.get("cOnlyTargets"), cOnly, msg=requested)
            self.assertEqual("cppRuntimeProvenance" in receipt, bool(cpp), msg=requested)

    def test_a_failing_shared_overlay_never_calls_cpp_or_publishes_a_partial(self):
        with mock.patch.object(pr, "prepareSharedRuntime", side_effect=pe.EngineError("shared C failed")), \
                mock.patch.object(pc, "addCppRuntime") as cpp:
            with self.assertRaisesRegex(pe.EngineError, "shared C failed"):
                pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        cpp.assert_not_called()
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine"])

    def test_a_failing_cpp_overlay_leaves_no_output_or_partial(self):
        with mock.patch.object(pc, "addCppRuntime", side_effect=pe.EngineError("C++ link failed")):
            with self.assertRaisesRegex(pe.EngineError, "C\\+\\+ link failed"):
                pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine"])

    def test_the_windows_target_alone_makes_only_the_windows_runtime(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, ["x86_64-windows-gnu"])
        self.assertEqual(self.runtimeCalls, [])
        self.assertEqual(sorted(os.listdir(os.path.join(out, "runtime"))), ["notices", "windows"])
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertNotIn("runtimeProvenance", receipt)
        self.assertIn("windowsRuntimeProvenance", receipt)

    def test_each_windows_target_alone_or_both_selects_exactly_those_targets(self):
        for requested, expected in ((["aarch64-windows-gnu"], ["aarch64-windows-gnu"]),
                                    (["aarch64-windows-gnu", "x86_64-windows-gnu"], ["aarch64-windows-gnu", "x86_64-windows-gnu"]),
                                    (["x86_64-windows-gnu", "wasm32-wasi"], ["x86_64-windows-gnu"])):
            self.windowsCalls.clear()
            pb.prepareBundle(self.engine, "/z/zig", self.path("bundle-" + "-".join(requested)), requested)
            self.assertEqual([call[3] for call in self.windowsCalls], [expected], msg=requested)

    def test_an_explicit_other_target_leaves_the_windows_runtime_out(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, ["wasm32-wasi"])
        self.assertEqual(self.windowsCalls, [])
        self.assertEqual(self.runtimeCalls[0][3], ["wasm32-wasi"])
        self.assertFalse(os.path.exists(os.path.join(out, "runtime", "windows")))
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertNotIn("windowsRuntimeProvenance", receipt)

    def test_windows_and_another_target_make_both(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, ["x86_64-windows-gnu", "wasm32-wasi"])
        self.assertEqual(self.runtimeCalls[0][3], ["wasm32-wasi"])
        self.assertEqual(len(self.windowsCalls), 1)

    def test_a_failing_windows_runtime_leaves_no_output_or_partial(self):
        with mock.patch.object(pw, "prepareWindowsRuntime", side_effect=pe.EngineError("zig failed")):
            with self.assertRaisesRegex(pe.EngineError, "zig failed"):
                pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine"])

    def test_the_identity_covers_every_file_of_the_bundle_and_replaces_the_engine_identity(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        listed = [l.split("  ", 1)[1] for l in read(os.path.join(out, "FILES.sha256")).splitlines()]
        self.assertEqual(listed, pe.listFiles(out))
        for rel in ("bin/clang", "bin/clang-22", "lib/dep.dylib", "notices/provenance.json",
                    "notices/bundle-provenance.json", "runtime/x86_64-linux-gnu.2.31.cfg",
                    "runtime/notices/runtime-provenance.json", "runtime/windows/x86_64-windows-gnu.cfg",
                    "runtime/windows/notices/windows-provenance.json", "HOST", "VERSION"):
            self.assertIn(rel, listed)
        identity = read(os.path.join(out, "IDENTITY")).strip()
        self.assertEqual(identity, hashlib.sha256(read(os.path.join(out, "FILES.sha256")).encode()).hexdigest())
        self.assertNotEqual(identity, self.engineIdentity)
        self.assertEqual(self.verified[0], self.engine)
        self.assertTrue(self.verified[-1].startswith(out + ".partial-"))

    def test_a_library_alias_stays_a_relative_link_and_is_hashed_with_its_stub(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        directory = os.path.join(out, "runtime", "x86_64-linux-gnu.2.31")
        self.assertEqual(os.readlink(os.path.join(directory, "libm.so")), "libm.so.6")
        hashes = dict(reversed(l.split("  ", 1)) for l in read(os.path.join(out, "FILES.sha256")).splitlines())
        stub = hashes["runtime/x86_64-linux-gnu.2.31/libm.so.6"]
        self.assertEqual(hashes["runtime/x86_64-linux-gnu.2.31/libm.so"], stub)
        self.assertEqual(stub, pe.sha256File(os.path.join(directory, "libm.so.6")))

    def test_an_empty_archive_is_hashed_so_a_changed_one_fails_the_bundle_verification(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        hashes = dict(reversed(l.split("  ", 1)) for l in read(os.path.join(out, "FILES.sha256")).splitlines())
        self.assertEqual(hashes["runtime/wasm32-wasi/libm.a"], hashlib.sha256(b"!<arch>\n").hexdigest())

    def test_an_alias_leaving_the_bundle_is_refused_and_not_published(self):
        outside = self.path("outside")
        write(outside)

        def escaping(zig, engine, output, targets, engineRelative):
            self.prepareRuntime(zig, engine, output, targets, engineRelative)
            os.symlink(outside, os.path.join(output, "libm.so"))
            return output, []

        with mock.patch.object(pr, "prepareRuntime", side_effect=escaping):
            with self.assertRaisesRegex(pe.EngineError, "leaves the bundle"):
                pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine", "outside"])

    def test_the_source_engine_is_not_changed_and_its_receipt_is_recorded_without_certifying(self):
        before = (pe.listFiles(self.engine), read(os.path.join(self.engine, "IDENTITY")))
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        self.assertEqual((pe.listFiles(self.engine), read(os.path.join(self.engine, "IDENTITY"))), before)
        self.assertFalse(os.path.exists(os.path.join(self.engine, "runtime")))
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual(receipt["sourceEngineIdentity"], self.engineIdentity)
        self.assertEqual(receipt["engineRelative"], "..")
        self.assertEqual(receipt["engineProvenanceSha256"],
                         pe.sha256File(os.path.join(self.engine, "notices", "provenance.json")))
        self.assertEqual(read(os.path.join(out, "notices", "provenance.json")),
                         read(os.path.join(self.engine, "notices", "provenance.json")))

    def test_an_existing_output_is_never_replaced(self):
        for make in (os.makedirs, lambda p: write(p)):
            out = self.path("taken")
            make(out)
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pb.prepareBundle(self.engine, "/z/zig", out, [])
            self.assertEqual(self.runtimeCalls, [])
            shutil.rmtree(out) if os.path.isdir(out) else os.remove(out)

    def test_an_output_claimed_while_assembling_is_never_replaced_and_leaves_no_partial(self):
        out = self.path("bundle")

        original = pe.writeContract

        def claim(*args):
            os.makedirs(out)
            return original(*args)

        with mock.patch.object(pe, "writeContract", side_effect=claim):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pb.prepareBundle(self.engine, "/z/zig", out, [])
        self.assertEqual(os.listdir(out), [])
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])

    def test_a_failing_runtime_leaves_no_output_or_partial(self):
        with mock.patch.object(pr, "prepareRuntime", side_effect=pe.EngineError("zig failed")):
            with self.assertRaisesRegex(pe.EngineError, "zig failed"):
                pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine"])

    def test_an_output_reached_through_an_alias_into_the_engine_is_refused_before_any_copy(self):
        os.symlink(self.engine, self.path("alias"))
        self.assertEqual(os.path.realpath(self.path("alias", "out")), os.path.join(self.engine, "out"))
        before = (pe.listFiles(self.engine), sorted(os.listdir(self.engine)))
        for output in (self.path("alias", "out"), self.path("alias", "a", "b", "out")):
            with mock.patch.object(pb.shutil, "copytree", side_effect=AssertionError("copy reached inside the source")):
                with self.assertRaisesRegex(pe.EngineError, "inside the engine"):
                    pb.prepareBundle(self.engine, "/z/zig", output, [])
        self.assertEqual((pe.listFiles(self.engine), sorted(os.listdir(self.engine))), before)
        self.assertEqual(self.runtimeCalls, [])
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])

    def test_an_engine_that_already_has_a_runtime_is_refused_before_any_work(self):
        write(os.path.join(self.engine, "runtime", "x"))
        with self.assertRaisesRegex(pe.EngineError, "already has a runtime"):
            pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(self.runtimeCalls, [])
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine"])

    def test_an_output_inside_the_engine_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "inside the engine"):
            pb.prepareBundle(self.engine, "/z/zig", os.path.join(self.engine, "bundle"), [])
        self.assertEqual(self.runtimeCalls, [])
        self.assertEqual(sorted(os.listdir(self.engine)), ["FILES.sha256", "HOST", "IDENTITY", "VERSION", "bin",
                                                           "lib", "notices"])

    def test_a_bundle_whose_final_verification_fails_is_not_published(self):
        def refuse(root):
            if ".partial-" in root:
                raise pe.EngineError("hash mismatch")
            return "aarch64-macos", "22.1.1", 0

        with mock.patch.object(pe, "verifyEngine", side_effect=refuse):
            with self.assertRaisesRegex(pe.EngineError, "hash mismatch"):
                pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(sorted(os.listdir(self.dir)), ["engine"])


X64, ARM = "x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31"
ZIG = {"version": "0.16.0", "sha256": "a" * 64}
INCLUDES = {X64: "x86-linux-gnu", ARM: "aarch64-linux-gnu"}


class LinuxTargetRuntimeCase(BundleCase):
    triple = "x86_64-unknown-linux5.10.0-gnu2.31.0"
    flatFiles = ("libclang_rt.asan-x86_64.a", "libclang_rt.asan-x86_64.a.syms", "libclang_rt.asan-x86_64.so",
                 "libclang_rt.asan-preinit-x86_64.a", "libclang_rt.ubsan_standalone-x86_64.a",
                 "libclang_rt.tsan_cxx-x86_64.a.syms", "clang_rt.crtbegin-x86_64.o", "liborc_rt-x86_64.a",
                 "libclang_rt.asan-i386.a", "clang_rt.crtend-i386.o")
    configs = {"x86_64-linux-gnu.2.31.cfg": "-target x86_64-unknown-linux5.10.0-gnu2.31.0\n-fPIC\n",
               "aarch64-linux-gnu.2.31.cfg": "-target aarch64-unknown-linux5.10.0-gnu2.31.0\n",
               "wasm32-wasi.cfg": "-target wasm32-wasip1\n"}

    def setUp(self):
        super().setUp()
        flat = os.path.join(self.engine, "lib", "clang", "22", "lib", "linux")
        for name in self.flatFiles:
            write(os.path.join(flat, name), name + "\n")
        pe.writeContract(self.engine, pe.LINUX_X64, "22.1.8")

    def verify(self, root):
        self.verified.append(root)
        return pe.LINUX_X64, "22.1.8", 0

    def prepareRuntime(self, zig, engine, output, targets, engineRelative):
        super().prepareRuntime(zig, engine, output, targets, engineRelative)
        for name, text in self.configs.items():
            write(os.path.join(output, name), text)
        return output, []

    def lib(self, out):
        return os.path.join(out, "lib", "clang", "22", "lib")


class LinuxTargetRuntimeTest(LinuxTargetRuntimeCase):
    def test_each_x86_64_triple_a_config_names_gets_clangs_per_target_directory_with_the_arch_dropped_from_each_name(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        directory = os.path.join(self.lib(out), self.triple)
        self.assertEqual(sorted(os.listdir(directory)), [
            "clang_rt.crtbegin.o", "libclang_rt.asan-preinit.a", "libclang_rt.asan.a", "libclang_rt.asan.a.syms",
            "libclang_rt.asan.so", "libclang_rt.tsan_cxx.a.syms", "libclang_rt.ubsan_standalone.a", "liborc_rt.a"])
        self.assertEqual(read(os.path.join(directory, "libclang_rt.asan.a.syms")), "libclang_rt.asan-x86_64.a.syms\n")

    def test_the_flat_layout_stays_whole_and_only_the_target_directory_is_new(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        self.assertEqual(sorted(os.listdir(self.lib(out))), sorted(["linux", self.triple]))
        self.assertEqual(sorted(os.listdir(os.path.join(self.lib(out), "linux"))), sorted(self.flatFiles))

    def test_the_target_directory_is_hashed_into_the_contract_and_named_by_the_receipt(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        listed = [l.split("  ", 1)[1] for l in read(os.path.join(out, "FILES.sha256")).splitlines()]
        self.assertIn("lib/clang/22/lib/%s/libclang_rt.ubsan_standalone.a" % self.triple, listed)
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertEqual(receipt["targetRuntimeDirectories"], ["lib/clang/22/lib/" + self.triple])

    def test_a_runtime_without_a_linux_config_makes_no_target_directory(self):
        out = self.path("bundle")
        self.configs = {"wasm32-wasi.cfg": "-target wasm32-wasip1\n"}
        pb.prepareBundle(self.engine, "/z/zig", out, ["wasm32-wasi"])
        self.assertEqual(os.listdir(self.lib(out)), ["linux"])
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertNotIn("targetRuntimeDirectories", receipt)

    def test_musl_and_freebsd_configs_never_receive_glibc_runtime_artifacts(self):
        self.configs = dict(self.configs, **{
            "x86_64-linux-musl.cfg": "-target x86_64-unknown-linux5.10.0-musl\n",
            "aarch64-linux-musl.cfg": "-target aarch64-unknown-linux5.10.0-musl\n",
            "x86_64-freebsd.cfg": "-target x86_64-unknown-freebsd14.0\n"})
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        self.assertEqual(sorted(os.listdir(self.lib(out))), sorted(["linux", self.triple]))

    def test_an_arm64_linux_engine_copies_only_its_architecture_and_gnu_abi(self):
        flat = os.path.join(self.engine, "lib", "clang", "22", "lib", "linux")
        for name in ("libclang_rt.asan-aarch64.a", "libclang_rt.asan-aarch64.a.syms"):
            write(os.path.join(flat, name), name)
        runtime = self.path("runtime")
        triple = "aarch64-unknown-linux5.10.0-gnu2.31.0"
        for name, text in dict(self.configs, **{
                "aarch64-linux-musl.cfg": "-target aarch64-unknown-linux5.10.0-musl\n"}).items():
            write(os.path.join(runtime, name), text)
        made = pb.addTargetRuntimeDirectories(self.engine, pe.LINUX_ARM64, "22.1.8", runtime)
        self.assertEqual(made, ["lib/clang/22/lib/" + triple])
        directory = os.path.join(self.engine, made[0])
        self.assertEqual(sorted(os.listdir(directory)), ["libclang_rt.asan.a", "libclang_rt.asan.a.syms"])
        self.assertEqual(read(os.path.join(directory, "libclang_rt.asan.a")), "libclang_rt.asan-aarch64.a")
        self.assertFalse(os.path.lexists(os.path.join(os.path.dirname(directory), self.triple)))

    def test_a_linux_config_with_no_x86_64_runtime_in_the_engine_fails_and_publishes_nothing(self):
        flat = os.path.join(self.engine, "lib", "clang", "22", "lib", "linux")
        for name in self.flatFiles:
            if "x86_64" in name:
                os.remove(os.path.join(flat, name))
        pe.writeContract(self.engine, pe.LINUX_X64, "22.1.8")
        with self.assertRaisesRegex(pe.EngineError, "no x86_64 runtime files .* %s" % self.triple):
            pb.prepareBundle(self.engine, "/z/zig", self.path("bundle"), [])
        self.assertEqual(os.listdir(self.dir), ["engine"])


class AugmentCase(BundleCase):
    runtimeReceipt = {"kind": "runtime", "zig": ZIG, "engineRelative": "..",
                      "targets": [{"target": X64}, {"target": ARM}, {"target": "wasm32-wasi"}]}

    def setUp(self):
        super().setUp()
        self.bundle = self.path("base")
        with mock.patch.object(pr, "SHARED_TARGETS", {}):
            pb.prepareBundle(self.engine, "/z/zig", self.bundle, [])
        for name in INCLUDES.values():
            write(os.path.join(self.bundle, "runtime", "include", "libc", name, "h.h"))
        pe.writeContract(self.bundle, "aarch64-macos", "22.1.1")
        self.baseHashes = self.hashes(self.bundle)
        self.runtimeCalls.clear(), self.windowsCalls.clear(), self.cppCalls.clear(), self.verified.clear()
        self.baseSha = pe.sha256File(os.path.join(self.bundle, "runtime", "notices", "runtime-provenance.json"))

    def hashes(self, root):
        return {rel: pe.sha256File(os.path.join(root, rel)) for rel in pe.listFiles(root)}

    def overlay(self, name, targets=(X64,), **receiptFields):
        root, records = self.path(name), []
        for target in targets:
            directory = pr.sharedDirectory(target)
            inputs = []
            for stub in ("crti.o", "libc.so.6"):
                write(os.path.join(root, directory, stub), "%s %s\n" % (stub, target))
                inputs.append({"name": stub, "sha256": pe.sha256File(os.path.join(root, directory, stub)),
                               "bytes": os.path.getsize(os.path.join(root, directory, stub))})
            os.symlink("libc.so.6", os.path.join(root, directory, "libc.so"))
            write(os.path.join(root, directory + ".cfg"), "-shared\n-Xlinker <CFGDIR>/%s/crti.o\n" % directory)
            records.append({"target": target, "directory": directory, "config": directory + ".cfg", "inputs": inputs,
                            "libraryAliases": [{"alias": "libc.so", "target": "libc.so.6"}],
                            "includeDirectories": [INCLUDES[target]]})
        receipt = {"kind": pb.SHARED_RECEIPT_KIND, "statement": "local", "redistributionCertified": False,
                   "zig": ZIG, "producerHost": "aarch64-macos", "engineVersion": "22.1.1", "engineRelative": "..",
                   "baseRuntimeProvenanceSha256": self.baseSha, "targets": records}
        receipt.update(receiptFields)
        write(os.path.join(root, pr.SHARED_PROVENANCE), json.dumps(receipt) + "\n")
        return root

    def augment(self, *overlays, output="out"):
        return pb.augmentBundle(self.bundle, list(overlays), self.path(output))

    def assertRefused(self, pattern, *overlays, output="out"):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.augment(*overlays, output=output)
        self.assertFalse(os.path.exists(self.path(output)))
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])
        self.assertEqual(self.hashes(self.bundle), self.baseHashes)


class AugmentBundleTest(AugmentCase):
    def test_two_one_target_overlays_add_exactly_their_files_and_one_joined_receipt(self):
        arm, x64 = self.overlay("arm", [ARM]), self.overlay("x64")
        out = self.augment(arm, x64)
        after, runtime = self.hashes(out), "runtime/"
        added = sorted(set(after) - set(self.baseHashes))
        self.assertEqual(added, sorted(runtime + n for n in (
            "aarch64-linux-gnu.2.31.so.cfg", "aarch64-linux-gnu.2.31.so/crti.o", "aarch64-linux-gnu.2.31.so/libc.so",
            "aarch64-linux-gnu.2.31.so/libc.so.6", "x86_64-linux-gnu.2.31.so.cfg", "x86_64-linux-gnu.2.31.so/crti.o",
            "x86_64-linux-gnu.2.31.so/libc.so", "x86_64-linux-gnu.2.31.so/libc.so.6", pr.SHARED_PROVENANCE)))
        changed = sorted(n for n in self.baseHashes if after[n] != self.baseHashes[n])
        self.assertEqual(changed, ["notices/bundle-provenance.json"])
        receipt = json.loads(read(os.path.join(out, "runtime", pr.SHARED_PROVENANCE)))
        self.assertEqual([r["target"] for r in receipt["targets"]], [X64, ARM])
        self.assertEqual({k: v for k, v in receipt.items() if k != "targets"},
                         {k: json.loads(read(os.path.join(x64, pr.SHARED_PROVENANCE)))[k] for k in pb.SHARED_RECEIPT_COMMON})
        self.assertEqual(os.readlink(os.path.join(out, "runtime", X64 + ".so", "libc.so")), "libc.so.6")
        self.assertEqual(read(os.path.join(out, "runtime", ARM + ".so.cfg")), read(os.path.join(arm, ARM + ".so.cfg")))
        self.assertEqual(self.runtimeCalls + self.windowsCalls + self.cppCalls, [])

    def test_the_bundle_receipt_gains_the_shared_entries_and_keeps_everything_else(self):
        before = json.loads(read(os.path.join(self.bundle, "notices", "bundle-provenance.json")))
        out = self.augment(self.overlay("both", [X64, ARM]))
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertEqual({k: v for k, v in receipt.items() if k in before}, before)
        self.assertEqual({k: v for k, v in receipt.items() if k not in before}, {
            "baseBundleIdentity": read(os.path.join(self.bundle, "IDENTITY")).strip(),
            "sharedRuntimeProvenance": "runtime/notices/runtime-shared-provenance.json", "sharedTargets": [X64, ARM]})
        self.assertEqual(receipt["sourceEngineIdentity"], self.engineIdentity)
        self.assertFalse(receipt["redistributionCertified"])

    def test_the_contract_covers_every_file_and_the_clone_is_verified_before_publication(self):
        out = self.augment(self.overlay("x64"))
        listed = [l.split("  ", 1)[1] for l in read(os.path.join(out, "FILES.sha256")).splitlines()]
        self.assertEqual(listed, pe.listFiles(out))
        self.assertIn("runtime/x86_64-linux-gnu.2.31.so/libc.so", listed)
        identity = read(os.path.join(out, "IDENTITY")).strip()
        self.assertEqual(identity, hashlib.sha256(read(os.path.join(out, "FILES.sha256")).encode()).hexdigest())
        self.assertNotEqual(identity, read(os.path.join(self.bundle, "IDENTITY")).strip())
        self.assertEqual(self.verified[0], self.bundle)
        self.assertTrue(self.verified[-1].startswith(out + ".partial-"))

    def test_a_stub_alias_stays_a_relative_link_hashed_with_its_stub(self):
        out = self.augment(self.overlay("x64"))
        hashes = self.hashes(out)
        self.assertEqual(hashes["runtime/x86_64-linux-gnu.2.31.so/libc.so"], hashes["runtime/x86_64-linux-gnu.2.31.so/libc.so.6"])

    def test_an_overlay_holding_anything_beyond_its_receipt_is_refused(self):
        for label, change in (
                ("a file", lambda r: write(os.path.join(r, "extra.txt"))),
                ("a file in the directory", lambda r: write(os.path.join(r, X64 + ".so", "crtbegin.o"))),
                ("a notice", lambda r: write(os.path.join(r, "notices", "other.json"))),
                ("a directory", lambda r: os.makedirs(os.path.join(r, "empty"))),
                ("a missing config", lambda r: os.remove(os.path.join(r, X64 + ".so.cfg"))),
                ("a missing input", lambda r: os.remove(os.path.join(r, X64 + ".so", "crti.o"))),
                ("a changed input", lambda r: write(os.path.join(r, X64 + ".so", "crti.o"), "changed\n")),
                ("a config link", lambda r: (os.remove(os.path.join(r, X64 + ".so.cfg")), os.symlink("/etc/hosts", os.path.join(r, X64 + ".so.cfg")))),
                ("an input link", lambda r: (os.remove(os.path.join(r, X64 + ".so", "crti.o")), os.symlink("/etc/hosts", os.path.join(r, X64 + ".so", "crti.o")))),
                ("an alias leaving the directory", lambda r: (os.remove(os.path.join(r, X64 + ".so", "libc.so")), os.symlink("../" + X64 + ".so.cfg", os.path.join(r, X64 + ".so", "libc.so")))),
                ("an absolute alias", lambda r: (os.remove(os.path.join(r, X64 + ".so", "libc.so")), os.symlink("/etc/hosts", os.path.join(r, X64 + ".so", "libc.so")))),
                ("a directory link", lambda r: os.symlink(self.dir, os.path.join(r, "linked")))):
            overlay = self.overlay("overlay-" + label.replace(" ", "-"))
            change(overlay)
            with self.subTest(label):
                self.assertRefused("overlay|differs|alias|not a regular", overlay)

    def test_a_receipt_that_names_a_path_outside_the_fixed_layout_is_refused(self):
        for label, edit in (("traversal name", lambda r: r["targets"][0]["inputs"][0].update(name="../crti.o")),
                            ("slash name", lambda r: r["targets"][0]["inputs"][0].update(name="a/crti.o")),
                            ("other directory", lambda r: r["targets"][0].update(directory="runtime")),
                            ("other config", lambda r: r["targets"][0].update(config="x.cfg")),
                            ("twice", lambda r: r["targets"][0]["inputs"].append(r["targets"][0]["inputs"][0])),
                            ("unknown key", lambda r: r.update(extra=1)),
                            ("wrong kind", lambda r: r.update(kind="local-zig-runtime-proof")),
                            ("wasi target", lambda r: r["targets"][0].update(target="wasm32-wasi")),
                            ("windows target", lambda r: r["targets"][0].update(target="x86_64-windows-gnu")),
                            ("unversioned glibc", lambda r: r["targets"][0].update(target="x86_64-linux-gnu")),
                            ("the same target twice", lambda r: r["targets"].append(r["targets"][0]))):
            overlay = self.overlay("o-" + label.replace(" ", "-"))
            path = os.path.join(overlay, pr.SHARED_PROVENANCE)
            receipt = json.loads(read(path))
            edit(receipt)
            write(path, json.dumps(receipt))
            with self.subTest(label):
                self.assertRefused("overlay|not a|named|unsupported file name", overlay)

    def editReceipt(self, name, edit, targets=(X64,)):
        overlay = self.overlay(name, targets)
        path = os.path.join(overlay, pr.SHARED_PROVENANCE)
        receipt = json.loads(read(path))
        edit(receipt)
        write(path, json.dumps(receipt))
        return overlay

    def assertRefusedWithOverlaysUnchanged(self, pattern, *overlays):
        before = [self.hashes(o) for o in overlays]
        self.assertRefused(pattern, *overlays)
        self.assertEqual([self.hashes(o) for o in overlays], before)

    def test_an_include_directory_that_is_not_one_plain_name_is_refused_even_where_it_exists(self):
        runtime = os.path.join(self.bundle, "runtime")
        for index, value in enumerate((self.dir, "../..", "..", ".", "", "x86-linux-gnu/..", "/")):
            joined = os.path.join(runtime, "include", "libc", value)
            self.assertTrue(os.path.isdir(joined), msg="%r must exist for the old gate to accept it" % value)
            overlay = self.editReceipt("inc-" + str(index),
                                       lambda r: r["targets"][0].update(includeDirectories=[value]))
            with self.subTest(value):
                self.assertRefusedWithOverlaysUnchanged("unsupported file name", overlay)

    def test_an_include_directory_after_a_valid_one_or_of_another_type_is_refused(self):
        for label, value, pattern in (("second", ["x86-linux-gnu", "../.."], "unsupported file name"),
                                      ("number", [5], "includeDirectories is not a list of names"),
                                      ("string", "x86-linux-gnu", "includeDirectories is not a list of names"),
                                      ("null", None, "includeDirectories is not a list of names")):
            overlay = self.editReceipt("inc-" + label, lambda r: r["targets"][0].update(includeDirectories=value))
            with self.subTest(label):
                self.assertRefusedWithOverlaysUnchanged(pattern, overlay)

    def test_an_overlay_that_names_no_target_is_refused_alone_or_beside_a_valid_one(self):
        empty = self.editReceipt("empty", lambda r: None, targets=())
        self.assertEqual(json.loads(read(os.path.join(empty, pr.SHARED_PROVENANCE)))["targets"], [])
        self.assertRefusedWithOverlaysUnchanged("names no target", empty)
        self.assertRefusedWithOverlaysUnchanged("names no target", self.overlay("valid", [ARM]), empty)

    def test_an_overlay_that_certifies_redistribution_is_refused(self):
        for value in (True, 1, "false", None):
            overlay = self.editReceipt("cert-%s" % type(value).__name__ + str(value),
                                       lambda r: r.update(redistributionCertified=value))
            with self.subTest(value):
                self.assertRefusedWithOverlaysUnchanged("certifies redistribution", overlay)

    def test_an_overlay_of_another_base_zig_engine_or_host_is_refused(self):
        for field, value in (("baseRuntimeProvenanceSha256", "0" * 64), ("zig", {"version": "0.16.0", "sha256": "b" * 64}),
                             ("engineVersion", "22.1.2"), ("producerHost", "x86_64-macos"), ("engineRelative", "../engine")):
            with self.subTest(field):
                self.assertRefused("does not belong to this bundle: %s" % field, self.overlay("o-" + field, **{field: value}))

    def test_overlays_that_disagree_or_repeat_a_target_or_an_overlay_are_refused(self):
        self.assertRefused("differ in statement", self.overlay("a", [X64]), self.overlay("b", [ARM], statement="other"))
        self.assertRefused("target %s is in two overlays" % X64, self.overlay("c", [X64]), self.overlay("d", [X64, ARM]))
        same = self.overlay("e", [X64])
        self.assertRefused("each overlay once", same, same)
        self.assertRefused("each overlay once")

    def test_a_bundle_that_cannot_take_the_overlay_is_refused(self):
        overlay = self.overlay("x64")
        runtime = os.path.join(self.bundle, "runtime")
        receiptPath = os.path.join(self.bundle, "notices", "bundle-provenance.json")
        original = read(receiptPath)

        def rewrite(change):
            receipt = json.loads(original)
            change(receipt)
            write(receiptPath, json.dumps(receipt, indent=2, sort_keys=True) + "\n")
            pe.writeContract(self.bundle, "aarch64-macos", "22.1.1")
            self.baseHashes = self.hashes(self.bundle)

        rewrite(lambda r: r.pop("runtimeProvenance"))
        self.assertRefused("no prepared runtime", overlay)
        rewrite(lambda r: r.update(sharedRuntimeProvenance="x"))
        self.assertRefused("already has shared profiles", overlay)
        write(receiptPath, original)
        for rel, text in ((X64 + ".so/crti.o", "already there"), (X64 + ".so.cfg", "x"), (pr.SHARED_PROVENANCE, "{}")):
            write(os.path.join(runtime, rel), text)
            pe.writeContract(self.bundle, "aarch64-macos", "22.1.1")
            self.baseHashes = self.hashes(self.bundle)
            with self.subTest(rel):
                self.assertRefused("already has", overlay)
            shutil.rmtree(os.path.join(runtime, X64 + ".so"), ignore_errors=True)
            for name in (X64 + ".so.cfg", pr.SHARED_PROVENANCE):
                if os.path.exists(os.path.join(runtime, name)):
                    os.remove(os.path.join(runtime, name))
        pe.writeContract(self.bundle, "aarch64-macos", "22.1.1")
        self.baseHashes = self.hashes(self.bundle)
        shutil.rmtree(os.path.join(runtime, "include", "libc", "x86-linux-gnu"))
        pe.writeContract(self.bundle, "aarch64-macos", "22.1.1")
        self.baseHashes = self.hashes(self.bundle)
        self.assertRefused("no include/libc/x86-linux-gnu", overlay)

    def test_a_base_runtime_not_prepared_for_the_target_is_refused(self):
        path = os.path.join(self.bundle, "runtime", "notices", "runtime-provenance.json")
        receipt = dict(self.runtimeReceipt, targets=[{"target": X64}])
        write(path, json.dumps(receipt) + "\n")
        pe.writeContract(self.bundle, "aarch64-macos", "22.1.1")
        self.baseHashes, self.baseSha = self.hashes(self.bundle), pe.sha256File(path)
        self.assertRefused("not prepared for %s" % ARM, self.overlay("arm", [ARM]))

    def test_the_output_is_never_replaced_or_placed_inside_the_bundle(self):
        overlay = self.overlay("x64")
        for make in (os.makedirs, write):
            taken = self.path("taken")
            make(taken)
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pb.augmentBundle(self.bundle, [overlay], taken)
            shutil.rmtree(taken) if os.path.isdir(taken) else os.remove(taken)
        with self.assertRaisesRegex(pe.EngineError, "inside the bundle"):
            pb.augmentBundle(self.bundle, [overlay], os.path.join(self.bundle, "inner"))
        self.assertEqual(self.hashes(self.bundle), self.baseHashes)

    def test_an_output_reached_through_an_alias_into_the_bundle_is_refused_before_any_copy(self):
        overlay = self.overlay("x64")
        os.symlink(self.bundle, self.path("alias"))
        self.assertEqual(os.path.realpath(self.path("alias", "out")), os.path.join(self.bundle, "out"))
        before = sorted(os.listdir(self.bundle))
        for output in (self.path("alias", "out"), self.path("alias", "a", "b", "out")):
            with mock.patch.object(pb.shutil, "copytree", side_effect=AssertionError("copy reached inside the source")):
                with self.assertRaisesRegex(pe.EngineError, "inside the bundle"):
                    pb.augmentBundle(self.bundle, [overlay], output)
        self.assertEqual(sorted(os.listdir(self.bundle)), before)
        self.assertEqual(self.hashes(self.bundle), self.baseHashes)
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])
        self.assertEqual(self.verified, [])

    def test_an_output_beside_the_bundle_through_a_link_that_leaves_it_is_still_allowed(self):
        os.makedirs(self.path("elsewhere"))
        os.symlink(self.path("elsewhere"), self.path("alias"))
        out = pb.augmentBundle(self.bundle, [self.overlay("x64")], self.path("alias", "out"))
        self.assertEqual(os.path.realpath(out), self.path("elsewhere", "out"))
        self.assertEqual(self.hashes(self.bundle), self.baseHashes)

    def test_an_output_claimed_while_assembling_is_never_replaced_and_leaves_no_partial(self):
        out, original = self.path("out"), pe.writeContract

        def claim(*args):
            os.makedirs(out)
            return original(*args)

        overlay = self.overlay("x64")
        with mock.patch.object(pe, "writeContract", side_effect=claim):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                pb.augmentBundle(self.bundle, [overlay], out)
        self.assertEqual(os.listdir(out), [])
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])

    def test_a_clone_whose_final_verification_fails_is_not_published(self):
        overlay = self.overlay("x64")

        def refuse(root):
            if ".partial-" in root:
                raise pe.EngineError("hash mismatch")
            return "aarch64-macos", "22.1.1", 0

        with mock.patch.object(pe, "verifyEngine", side_effect=refuse):
            with self.assertRaisesRegex(pe.EngineError, "hash mismatch"):
                pb.augmentBundle(self.bundle, [overlay], self.path("out"))
        self.assertFalse(os.path.exists(self.path("out")))
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])
        self.assertEqual(self.hashes(self.bundle), self.baseHashes)

    def test_the_source_bundle_failing_verification_stops_before_any_clone(self):
        overlay = self.overlay("x64")
        with mock.patch.object(pe, "verifyEngine", side_effect=pe.EngineError("hash mismatch")):
            with self.assertRaisesRegex(pe.EngineError, "hash mismatch"):
                pb.augmentBundle(self.bundle, [overlay], self.path("out"))
        self.assertEqual([n for n in os.listdir(self.dir) if n.startswith("out")], [])


class BundleCommandLineTest(AugmentCase):
    def test_bundle_with_shared_runtimes_augments_and_the_legacy_arguments_still_prepare(self):
        arm, x64 = self.overlay("arm", [ARM]), self.overlay("x64")
        self.assertEqual(pb.main(["--bundle", self.bundle, "--shared-runtime", arm, "--shared-runtime", x64,
                                  "--output", self.path("out")]), 0)
        self.assertEqual(json.loads(read(self.path("out", "notices", "bundle-provenance.json")))["sharedTargets"], [X64, ARM])
        self.assertEqual(pb.main(["--bundle", self.bundle, "--shared-runtime", x64, "--output", self.path("out")]), 1)
        self.assertEqual(pb.main(["--engine", self.engine, "--zig", "/z/zig", "--output", self.path("legacy")]), 0)
        self.assertEqual(len(self.runtimeCalls), 1)

    def test_the_two_modes_do_not_mix(self):
        x64 = self.overlay("x64")
        for argv in (["--bundle", self.bundle, "--output", "o"],
                     ["--bundle", self.bundle, "--shared-runtime", x64, "--engine", self.engine, "--output", "o"],
                     ["--bundle", self.bundle, "--shared-runtime", x64, "--zig", "/z/zig", "--output", "o"],
                     ["--bundle", self.bundle, "--shared-runtime", x64, "--target", X64, "--output", "o"],
                     ["--shared-runtime", x64, "--engine", self.engine, "--zig", "/z/zig", "--output", "o"],
                     ["--engine", self.engine, "--output", "o"], ["--zig", "/z/zig", "--output", "o"]):
            with self.subTest(argv), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                pb.main(argv)
        self.assertEqual(self.runtimeCalls, [])


X64W, ARMW = pw.TARGET, pw.ARM64_TARGET
SOURCE_VERSION = "22.1.1"
SOURCE_HOST = "aarch64-macos"
BOTH = [X64W, ARMW]


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def put(root, relative, text):
    """A file of a source runtime at a runtime-relative path, as the {"path", "sha256"} record the receipts list."""
    write(os.path.join(root, *relative.split("/")), text)
    return {"path": relative, "sha256": digest(text)}


def putJson(root, relative, receipt):
    text = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    write(os.path.join(root, *relative.split("/")), text)
    return digest(text)


def sourceRuntime(root, targets=BOTH, sanTargets=None, override=None):
    """A prepared source Windows runtime R at root, as the three producers leave it merged: the C runtime, the C++
    overlay and the sanitizer assets, with real receipts over placeholder bytes. `override` maps "c", "cpp" and
    "san" to fields that replace the receipt's own."""
    targets, override = list(targets), override or {}
    sanTargets = list(targets if sanTargets is None else sanTargets)
    sources = {"llvm-project": {"rev": pws.pinnedRevisions(SOURCE_VERSION)[1], "version": SOURCE_VERSION, "major": "22"}}
    common = {"redistributionCertified": False, "producerHost": SOURCE_HOST, "engineVersion": SOURCE_VERSION,
              "engineRelative": pws.ENGINE_RELATIVE, "sources": sources}
    variants, resources = [], []
    for target in targets:
        for kind in pws.SOURCE_VARIANTS:
            directory, config = pws.variantDirectory(target, kind), pws.variantConfig(target, kind)
            files = [{"name": name, "sha256": put(root, "windows/%s/%s" % (directory, name), directory + name + "\n")["sha256"]}
                     for name in ("crt2.o", "libmingw32.a")]
            put(root, "windows/" + config, pws.renderSourceConfig(target, kind, [pws.HEADER_DIRECTORY], "22"))
            variants.append({"target": target, "variant": kind, "directory": directory, "config": config, "files": files})
        resource = put(root, "windows/resource/" + pws.resourcePath(target), "builtins " + target + "\n")
        resources.append({"target": target, "path": pws.resourcePath(target), "sha256": resource["sha256"]})
    put(root, "windows/include/libc/mingw-w64/_mingw.h", "mingw\n")
    put(root, "windows/include/libc/mingw-w64/sec_api/stdio_s.h", "stdio\n")
    notices = override.get("c", {}).get("notices", ["notices/mingw-w64/COPYING"])
    for notice in notices:
        if ".." not in notice.split("/") and not notice.endswith("MISSING"):
            put(root, "windows/" + notice, "license\n")
    c = dict(common, kind=pws.RECEIPT_KIND, targets=targets, includeDirectories=[pws.HEADER_DIRECTORY],
             variants=variants, resourceFiles=resources, notices=notices)
    c.update(override.get("c", {}))
    cDigest = putJson(root, pwc.BASE_PROVENANCE, c)
    files, payloads = [], {}
    for target in targets:
        directory = pwc.payloadDirectory(target)
        archives = [put(root, "%s/%s" % (directory, name), directory + name + "\n") for name in pwc.ARCHIVES]
        files += archives + [put(root, directory + "/include/c++/v1/__config_site", "site\n")]
        files += [put(root, pwc.configPath(target, kind), pwc.renderCxxConfig(target)) for kind in pws.SOURCE_VARIANTS]
        payloads[target] = {"archives": [{"name": name, "sha256": a["sha256"]} for name, a in zip(pwc.ARCHIVES, archives)],
                            "threadApi": "WIN32", "threadApiSite": []}
    files.append(put(root, pwc.NOTICE_DIRECTORY + "/libcxx/LICENSE.TXT", "license\n"))
    cpp = dict(common, kind=pwc.RECEIPT_KIND, targets=targets, cohort="llvm-%s-source" % SOURCE_VERSION,
               base={"path": pwc.BASE_PROVENANCE, "kind": pws.RECEIPT_KIND, "sha256": cDigest}, payloads=payloads,
               variants=[{"target": t, "variant": v, "config": pwc.configPath(t, v), "base": pwc.baseConfigPath(t, v),
                          "directory": pwc.payloadDirectory(t), "threadApi": "WIN32"}
                         for t in targets for v in pws.SOURCE_VARIANTS],
               files=files)
    cpp.update(override.get("cpp", {}))
    cppDigest = putJson(root, pwc.PROVENANCE, cpp)
    files, assets = [], {}
    for target in sanTargets:
        assets[target] = []
        for spec in san.assetSpecs(target):
            record = put(root, san.overlayPath(target, spec), spec["name"] + "\n")
            files.append(record)
            assets[target].append(dict(record, name=spec["name"], role=spec["role"]))
    files.append(put(root, san.NOTICE, "license\n"))
    sanitizer = dict(common, kind=san.RECEIPT_KIND, targets=sanTargets, cohort="llvm-%s-source" % SOURCE_VERSION,
                     proofs=san.PROOFS, files=files, assets=assets,
                     inputs={"base": {"path": san.BASE_PROVENANCE, "kind": pws.RECEIPT_KIND, "sha256": cDigest},
                             "cpp": {"path": san.CPP_PROVENANCE, "kind": pwc.RECEIPT_KIND, "sha256": cppDigest}})
    sanitizer.update(override.get("san", {}))
    putJson(root, san.PROVENANCE, sanitizer)
    return root


class SourceWindowsCase(BundleCase):
    def setUp(self):
        super().setUp()
        self.events = []
        self.sources = itertools.count()
        self.source = sourceRuntime(self.path("source"))
        for module, name, label in ((pws, "installResource", "pws.installResource"),
                                    (san, "installResource", "san.installResource"), (pe, "writeContract", "writeContract")):
            patcher = mock.patch.object(module, name, side_effect=self.recording(label, getattr(module, name)))
            patcher.start()
            self.addCleanup(patcher.stop)
        for module, name in ((pws, "builtinsProblem"), (san, "structureProblem")):
            patcher = mock.patch.object(module, name, return_value=None)
            patcher.start()
            self.addCleanup(patcher.stop)

    def recording(self, label, original):
        def call(*args):
            self.events.append((label, args))
            return original(*args)
        return call

    def broken(self, mutate=None, **options):
        root = sourceRuntime(self.path("broken-%d" % next(self.sources)), **options)
        if mutate:
            mutate(root)
        return root

    def bundle(self, targets, source=None, zig=None, out="bundle"):
        return pb.prepareBundle(self.engine, zig, self.path(out), targets, windowsRuntime=source or self.source)

    def receipt(self, out="bundle"):
        return json.loads(read(self.path(out, "notices", "bundle-provenance.json")))

    def listed(self, out="bundle"):
        return [l.split("  ", 1)[1] for l in read(self.path(out, "FILES.sha256")).splitlines()]

    def refused(self, pattern, targets=BOTH, source=None, zig=None):
        source = source or self.source
        before = (pc.treeDigest(self.engine), pc.treeDigest(source))
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.bundle(targets, source, zig)
        self.assertFalse(os.path.lexists(self.path("bundle")))
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])
        self.assertEqual((pc.treeDigest(self.engine), pc.treeDigest(source)), before)


class SourceWindowsBundleTest(SourceWindowsCase):
    def test_both_source_cpus_are_copied_with_cpp_and_sanitizer_assets_and_every_file_is_manifested(self):
        engineBefore, sourceBefore = pc.treeDigest(self.engine), pc.treeDigest(self.source)
        out = self.path("bundle")
        self.assertEqual(self.bundle(BOTH), out)
        self.assertEqual((self.windowsCalls, self.runtimeCalls, self.cppCalls, self.sharedCalls), ([], [], [], []))
        listed = self.listed()
        for relative in ("runtime/windows/x86_64-windows-gnu/crt2.o", "runtime/windows/aarch64-windows-gnu.dll/libmingw32.a",
                         "runtime/windows/x86_64-windows-gnu.cfg", "runtime/windows/aarch64-windows-gnu.dll.cfg",
                         "runtime/windows/include/libc/mingw-w64/sec_api/stdio_s.h",
                         "runtime/windows/resource/lib/windows/libclang_rt.builtins-x86_64.a",
                         "runtime/windows/resource/lib/windows/libclang_rt.builtins-aarch64.a",
                         "runtime/windows/notices/mingw-w64/COPYING", "runtime/windows/notices/windows-provenance.json",
                         "runtime/windows/x86_64-windows-gnu.cxx/libc++.a", "runtime/windows/aarch64-windows-gnu.cxx/libunwind.a",
                         "runtime/windows/x86_64-windows-gnu.cxx.cfg", "runtime/windows/aarch64-windows-gnu.dll.cxx.cfg",
                         "runtime/notices/windows-source-cpp-provenance.json",
                         "runtime/notices/windows-source-cpp/libcxx/LICENSE.TXT",
                         "runtime/windows-sanitizers/resource/lib/windows/libclang_rt.ubsan_standalone-x86_64.a",
                         "runtime/windows-sanitizers/resource/lib/windows/libclang_rt.ubsan_standalone-aarch64.a",
                         "runtime/notices/windows-sanitizer-provenance.json",
                         "runtime/notices/windows-sanitizer/compiler-rt/LICENSE.TXT",
                         "lib/clang/22/lib/windows/libclang_rt.builtins-x86_64.a",
                         "lib/clang/22/lib/windows/libclang_rt.builtins-aarch64.a",
                         "lib/clang/22/lib/windows/libclang_rt.ubsan_standalone_cxx-x86_64.a",
                         "lib/clang/22/lib/windows/libclang_rt.asan_dynamic-x86_64.dll.a",
                         "lib/clang/22/lib/windows/libclang_rt.asan_dynamic_runtime_thunk-x86_64.a",
                         "lib/clang/22/lib/windows/libclang_rt.ubsan_standalone-aarch64.a"):
            self.assertIn(relative, listed)
        dll = "runtime/windows/x86_64-windows-gnu/bin/libclang_rt.asan_dynamic-x86_64.dll"
        self.assertEqual([p for p in listed if p.endswith(".dll")], [dll])
        self.assertEqual(listed, pe.listFiles(out))
        for relative in pc.overlayFiles(self.source):
            self.assertEqual(pe.sha256File(os.path.join(out, "runtime", relative)),
                             pe.sha256File(os.path.join(self.source, relative)), msg=relative)
        self.assertEqual((pc.treeDigest(self.engine), pc.treeDigest(self.source)), (engineBefore, sourceBefore))

    def test_target_runtime_archives_are_not_bound_to_their_producer_host(self):
        origins = [("linux", {"c": "x86_64-linux", "cpp": "x86_64-linux", "san": "x86_64-linux"}),
                   ("mixed", {"c": "aarch64-linux", "cpp": "x86_64-windows", "san": "x86_64-linux"})]
        paths = {"c": pwc.BASE_PROVENANCE, "cpp": pwc.PROVENANCE, "san": san.PROVENANCE}
        for label, hosts in origins:
            source = self.broken(override={name: {"producerHost": host} for name, host in hosts.items()})
            self.bundle(BOTH, source, out=label)
            for name, relative in paths.items():
                copied = json.loads(read(self.path(label, "runtime", *relative.split("/"))))
                self.assertEqual(copied["producerHost"], hosts[name])
                self.assertEqual(copied["targets"], BOTH)

    def test_the_bundle_receipt_names_the_source_receipts_and_counts_both_cpus_as_cpp(self):
        self.bundle(BOTH)
        receipt = self.receipt()
        hashes = {name: pe.sha256File(self.path("bundle", "runtime", *relative.split("/")))
                  for name, relative in (("c", "windows/notices/windows-provenance.json"),
                                         ("cpp", "notices/windows-source-cpp-provenance.json"),
                                         ("san", "notices/windows-sanitizer-provenance.json"))}
        self.assertEqual(receipt["windowsRuntimeProvenance"], "runtime/windows/notices/windows-provenance.json")
        self.assertEqual(receipt["windowsSourceTargets"], BOTH)
        self.assertEqual(receipt["windowsRuntimeProvenanceSha256"], hashes["c"])
        self.assertEqual(receipt["windowsSourceCppRuntimeProvenance"], "runtime/notices/windows-source-cpp-provenance.json")
        self.assertEqual(receipt["windowsSourceCppRuntimeProvenanceSha256"], hashes["cpp"])
        self.assertEqual(receipt["windowsSanitizerRuntimeProvenance"], "runtime/notices/windows-sanitizer-provenance.json")
        self.assertEqual(receipt["windowsSanitizerRuntimeProvenanceSha256"], hashes["san"])
        self.assertEqual((receipt["cppTargets"], receipt["cOnlyTargets"]), (BOTH, []))
        self.assertNotIn("cppRuntimeProvenance", receipt)
        self.assertNotIn("runtimeProvenance", receipt)
        self.assertFalse(receipt["redistributionCertified"])

    def test_a_single_explicit_target_takes_the_component_made_for_it(self):
        for target in BOTH:
            source = sourceRuntime(self.path("source-" + target), [target])
            self.bundle([target], source, out="bundle-" + target)
            receipt = self.receipt("bundle-" + target)
            self.assertEqual((receipt["windowsSourceTargets"], receipt["cppTargets"]), ([target], [target]))
            listed = self.listed("bundle-" + target)
            self.assertEqual(any(p.endswith(".dll") for p in listed), target == X64W)
            self.assertEqual("lib/clang/22/lib/windows/libclang_rt.asan_dynamic-x86_64.dll.a" in listed, target == X64W)
        self.assertEqual(self.windowsCalls, [])

    def test_the_resources_are_installed_into_the_engine_copy_in_order_before_the_contract(self):
        self.bundle(BOTH)
        self.assertEqual([label for label, _ in self.events], ["pws.installResource", "san.installResource", "writeContract"])
        clone = self.events[2][1][0]
        self.assertTrue(clone.startswith(self.path("bundle") + ".partial-"))
        resource = os.path.join(clone, "lib", "clang", "22")
        self.assertEqual(self.events[0][1], (os.path.join(clone, "runtime", "windows"), resource))
        self.assertEqual(self.events[1][1], (os.path.join(clone, "runtime"), resource))
        self.assertFalse(os.path.lexists(os.path.join(self.engine, "lib", "clang")))

    def test_linux_and_darwin_cpp_stay_with_their_own_preparer_beside_the_source_windows_component(self):
        self.bundle(["x86_64-linux-gnu.2.31", "aarch64-macos", X64W, ARMW], zig="/z/zig")
        self.assertEqual(self.windowsCalls, [])
        self.assertEqual([call[3] for call in self.cppCalls], [["x86_64-linux-gnu.2.31", "aarch64-macos"]])
        self.assertNotIn("windows", self.cppCalls[0][4])
        self.assertNotIn("windows-sanitizers", self.cppCalls[0][4])
        receipt = self.receipt()
        self.assertEqual(receipt["cppRuntimeProvenance"], "runtime/notices/cpp-provenance.json")
        self.assertEqual(receipt["cppTargets"], ["x86_64-linux-gnu.2.31", "aarch64-macos", X64W, ARMW])
        self.assertEqual(receipt["cOnlyTargets"], [])
        self.assertEqual(receipt["windowsSourceTargets"], BOTH)
        listed = self.listed()
        for relative in ("runtime/x86_64-linux-gnu.2.31.cxx.cfg", "runtime/darwin/aarch64-macos.cxx.cfg",
                         "runtime/notices/cpp-provenance.json", "runtime/windows/x86_64-windows-gnu.cxx.cfg"):
            self.assertIn(relative, listed)

    def test_no_target_names_every_runtime_with_the_source_windows_component_in_place_of_the_zig_windows_one(self):
        self.bundle([], zig="/z/zig")
        self.assertEqual(self.windowsCalls, [])
        self.assertEqual((len(self.runtimeCalls), len(self.darwinCalls)), (1, 1))
        legacy = ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31", "aarch64-macos", "x86_64-macos"]
        self.assertEqual(self.cppCalls[0][3], legacy)
        receipt = self.receipt()
        self.assertEqual(receipt["cppTargets"], legacy + BOTH)
        self.assertEqual(receipt["cOnlyTargets"], ["wasm32-wasi"])
        self.assertEqual(receipt["windowsSourceTargets"], BOTH)

    def test_the_zig_may_be_left_out_only_for_explicit_windows_targets_with_a_source_runtime(self):
        self.bundle(BOTH, out="both")
        self.bundle([ARMW], sourceRuntime(self.path("arm-only"), [ARMW]), out="arm")
        for targets in ([], ["wasm32-wasi"], [X64W, "wasm32-wasi"], [X64W, "aarch64-macos"], ["x86_64-linux-gnu.2.31"]):
            with self.subTest(targets):
                self.refused("--zig", targets)
        with self.assertRaisesRegex(pe.EngineError, "--zig"):
            pb.prepareBundle(self.engine, None, self.path("legacy"), [X64W])
        self.assertFalse(os.path.lexists(self.path("legacy")))

    def test_a_source_runtime_with_no_selected_windows_target_is_refused_before_any_work(self):
        self.refused("no Windows target", ["wasm32-wasi"], zig="/z/zig")
        self.assertEqual((self.runtimeCalls, self.events), ([], []))

    def test_without_the_option_the_zig_windows_runtime_is_prepared_as_before(self):
        self.assertEqual(pb.prepareBundle(self.engine, "/z/zig", self.path("legacy"), [X64W]), self.path("legacy"))
        self.assertEqual([call[3] for call in self.windowsCalls], [[X64W]])
        self.assertEqual([call[3] for call in self.cppCalls], [[X64W]])
        receipt = self.receipt("legacy")
        self.assertEqual(receipt["cppRuntimeProvenance"], "runtime/notices/cpp-provenance.json")
        self.assertNotIn("windowsSourceTargets", receipt)
        self.assertEqual([label for label, _ in self.events], ["writeContract"])


class SourceWindowsRefusalTest(SourceWindowsCase):
    def test_a_runtime_whose_receipts_do_not_cover_exactly_the_selected_targets_is_refused(self):
        for label, options, targets, pattern in (
                ("C lacks the second CPU", {"targets": [X64W]}, BOTH, "C runtime has no aarch64-windows-gnu"),
                ("receipts hold a CPU the selection leaves out", {}, [X64W], "not exactly the selected"),
                ("sanitizer assets lack a CPU", {"sanTargets": [X64W]}, BOTH, "sanitizer receipt targets")):
            with self.subTest(label):
                self.refused(pattern, targets, self.broken(**options))

    def test_a_receipt_of_another_engine_cohort_llvm_or_without_provenance_or_that_certifies_is_refused(self):
        wrongLlvm = {"llvm-project": {"rev": "0" * 40, "version": SOURCE_VERSION, "major": "22"}}
        for label, override, pattern in (
                ("cpp engine version", {"cpp": {"engineVersion": "22.1.2"}}, "produced for"),
                ("missing sanitizer host", {"san": {"producerHost": None}}, "producer host provenance"),
                ("empty C host", {"c": {"producerHost": ""}}, "producer host provenance"),
                ("sanitizer cohort", {"san": {"cohort": "llvm-9.9.9-source"}}, "cohort"),
                ("cpp cohort", {"cpp": {"cohort": "llvm-9.9.9-source"}}, "cohort"),
                ("sanitizer certifies", {"san": {"redistributionCertified": True}}, "certif"),
                ("sanitizer llvm", {"san": {"sources": wrongLlvm}}, "built from llvm-project")):
            with self.subTest(label):
                self.refused(pattern, source=self.broken(override=override))

    def test_a_file_the_receipts_do_not_declare_or_declare_and_the_runtime_lacks_is_refused(self):
        for label, mutate, pattern in (
                ("unknown config", lambda r: write(os.path.join(r, "windows", "x86_64-windows-gnu.extra.cfg")), "do not declare"),
                ("unknown C file", lambda r: write(os.path.join(r, "windows", "x86_64-windows-gnu", "extra.a")), "do not declare"),
                ("unknown header root", lambda r: write(os.path.join(r, "windows", "include", "other", "x.h")), "do not declare"),
                ("unknown sanitizer file", lambda r: write(os.path.join(r, "windows-sanitizers", "stray.txt")), "do not declare"),
                ("missing header tree", lambda r: shutil.rmtree(os.path.join(r, "windows", "include")), "header"),
                ("missing config", lambda r: os.remove(os.path.join(r, "windows", "aarch64-windows-gnu.dll.cfg")), "declare"),
                ("missing resource tree", lambda r: shutil.rmtree(os.path.join(r, "windows", "resource")), "resource"),
                ("missing C++ receipt", lambda r: os.remove(os.path.join(r, "notices", "windows-source-cpp-provenance.json")),
                 "missing")):
            with self.subTest(label):
                self.refused(pattern, source=self.broken(mutate))

    def test_a_config_that_is_not_the_producers_rendering_is_refused(self):
        def append(root):
            with open(os.path.join(root, "windows", "x86_64-windows-gnu.cfg"), "a", newline="\n") as f:
                f.write("-Xlinker --unknown\n")
        self.refused("not the config", source=self.broken(append))

    def test_a_changed_file_a_link_and_an_escaped_or_missing_notice_are_refused(self):
        def change(root):
            write(os.path.join(root, "windows", "x86_64-windows-gnu", "crt2.o"), "changed\n")

        def link(root):
            os.symlink("crt2.o", os.path.join(root, "windows", "x86_64-windows-gnu", "crt2u.o"))

        for label, mutate, options, pattern in (
                ("changed file", change, {}, "does not match the receipt"),
                ("link", link, {}, "is a link"),
                ("escaped notice", None, {"override": {"c": {"notices": ["notices/../escape"]}}}, "unsupported file name"),
                ("missing notice", None, {"override": {"c": {"notices": ["notices/mingw-w64/MISSING"]}}}, "declare")):
            with self.subTest(label):
                self.refused(pattern, source=self.broken(mutate, **options))

    def test_a_destination_the_runtime_or_the_engine_already_holds_is_never_replaced_or_shadowed(self):
        def taken(zig, engine, output, targets, engineRelative):
            self.prepareRuntime(zig, engine, output, targets, engineRelative)
            write(os.path.join(output, "windows", "x86_64-windows-gnu.cfg"), "other\n")
            return output, []

        with mock.patch.object(pr, "prepareRuntime", side_effect=taken):
            self.refused("already has", ["wasm32-wasi", X64W, ARMW], zig="/z/zig")
        shadow = os.path.join(self.engine, "lib", "clang", "22", "lib", "x86_64-w64-windows-gnu", "libclang_rt.builtins.a")
        write(shadow)
        pe.writeContract(self.engine, SOURCE_HOST, SOURCE_VERSION)
        self.refused("would be linked instead")
        os.remove(shadow)
        other = os.path.join(self.engine, "lib", "clang", "22", "lib", "windows", "libclang_rt.builtins-x86_64.a")
        write(other, "other\n")
        pe.writeContract(self.engine, SOURCE_HOST, SOURCE_VERSION)
        self.refused("already exists with other contents")

    def test_an_input_that_changes_while_the_bundle_is_assembled_is_refused_before_publication(self):
        original = pws.installResource

        def change(windows, resourceRoot):
            original(windows, resourceRoot)
            write(os.path.join(self.source, "windows", "late.txt"))

        with mock.patch.object(pws, "installResource", side_effect=change):
            with self.assertRaisesRegex(pe.EngineError, "changed"):
                self.bundle(BOTH)
        self.assertFalse(os.path.lexists(self.path("bundle")))
        self.assertEqual([n for n in os.listdir(self.dir) if ".partial-" in n], [])

    def test_a_failing_resource_installer_publishes_nothing(self):
        for module in (pws, san):
            with self.subTest(module.__name__), mock.patch.object(module, "installResource",
                                                                  side_effect=pe.EngineError("install failed")):
                self.refused("install failed")

    def test_an_output_or_engine_nested_with_the_source_runtime_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "inside the source Windows runtime"):
            pb.prepareBundle(self.engine, None, os.path.join(self.source, "out"), BOTH, windowsRuntime=self.source)
        self.assertEqual(sorted(os.listdir(self.source)), ["notices", "windows", "windows-sanitizers"])
        self.refused("inside the engine", source=sourceRuntime(os.path.join(self.engine, "source")))
        outer = self.path("outer")
        shutil.copytree(self.engine, os.path.join(outer, "engine"))
        sourceRuntime(outer)
        with self.assertRaisesRegex(pe.EngineError, "inside the source Windows runtime"):
            pb.prepareBundle(os.path.join(outer, "engine"), None, self.path("bundle"), BOTH, windowsRuntime=outer)
        self.assertFalse(os.path.lexists(self.path("bundle")))


class SourceWindowsCommandLineTest(SourceWindowsCase):
    def test_windows_runtime_with_explicit_windows_targets_needs_no_zig(self):
        self.assertEqual(pb.main(["--engine", self.engine, "--output", self.path("a"), "--windows-runtime", self.source,
                                  "--target", X64W, "--target", ARMW]), 0)
        self.assertEqual(self.receipt("a")["windowsSourceTargets"], BOTH)
        self.assertEqual(pb.main(["--engine", self.engine, "--zig", "/z/zig", "--output", self.path("b"),
                                  "--windows-runtime", self.source]), 0)
        self.assertEqual(self.receipt("b")["cOnlyTargets"], ["wasm32-wasi"])
        self.assertEqual(self.windowsCalls, [])

    def test_an_unmatched_or_absent_input_is_exit_one_not_a_traceback(self):
        self.assertEqual(pb.main(["--engine", self.engine, "--zig", "/z/zig", "--output", self.path("a"),
                                  "--windows-runtime", self.source, "--target", "wasm32-wasi"]), 1)
        self.assertEqual(pb.main(["--engine", self.engine, "--output", self.path("b"), "--windows-runtime",
                                  self.path("absent"), "--target", X64W]), 1)
        self.assertEqual([n for n in os.listdir(self.dir) if n in ("a", "b")], [])

    def test_the_combinations_the_source_input_does_not_allow_are_usage_errors(self):
        for argv in (["--engine", self.engine, "--output", "o", "--windows-runtime", self.source],
                     ["--engine", self.engine, "--output", "o", "--windows-runtime", self.source, "--target", "wasm32-wasi"],
                     ["--engine", self.engine, "--output", "o", "--windows-runtime", self.source, "--target", X64W,
                      "--target", "aarch64-macos"],
                     ["--engine", self.engine, "--output", "o", "--target", X64W],
                     ["--bundle", self.path("b"), "--shared-runtime", self.path("o"), "--windows-runtime", self.source,
                      "--output", "o"],
                     ["--windows-runtime", self.source, "--output", "o"]):
            with self.subTest(argv), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                pb.main(argv)
        self.assertEqual((self.runtimeCalls, self.events), ([], []))


class BundleLayoutTest(unittest.TestCase):
    """The runtime and engine layouts a bundle relies on, through the real producers' checks."""

    def test_the_bundle_runtime_is_written_for_the_engine_root_above_it(self):
        self.assertEqual(pb.ENGINE_RELATIVE, "..")
        self.assertEqual(pr.checkEngineRelative(pb.ENGINE_RELATIVE), 1)


if __name__ == "__main__":
    unittest.main()
