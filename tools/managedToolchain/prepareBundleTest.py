import hashlib
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

import prepareBundle as pb
import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


class BundleTest(unittest.TestCase):
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
        self.cppCalls = []
        for patcher in (mock.patch.object(pe, "verifyEngine", side_effect=self.verify),
                        mock.patch.object(pr, "prepareRuntime", side_effect=self.prepareRuntime),
                        mock.patch.object(pw, "prepareWindowsRuntime", side_effect=self.prepareWindows),
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
        write(os.path.join(output, "notices", "runtime-provenance.json"), '{"kind": "runtime"}\n')
        write(os.path.join(output, "x86_64-linux-gnu.2.31", "libm.so.6"), "stub\n")
        os.symlink("libm.so.6", os.path.join(output, "x86_64-linux-gnu.2.31", "libm.so"))
        write(os.path.join(output, "wasm32-wasi", "libm.a"), "!<arch>\n")
        return output, []

    def prepareWindows(self, zig, engine, windows, targets=None):
        self.windowsCalls.append((zig, engine, windows, targets))
        write(os.path.join(windows, "x86_64-windows-gnu.cfg"), "-target w\n")
        write(os.path.join(windows, "notices", pw.PROVENANCE), '{"kind": "windows"}\n')
        return windows, []

    def addCpp(self, zig, engine, runtime, targets=None, seed=None):
        self.cppCalls.append((zig, engine, runtime, targets, sorted(os.listdir(runtime))))
        for target in targets:
            write(os.path.join(runtime, pc.VARIANTS[(target, "exe")]["config"]), "-isystem cxx\n")
        write(os.path.join(runtime, pc.PROVENANCE), '{"kind": "cpp"}\n')
        return {}

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

    def test_every_runtime_gets_the_cpp_overlay_of_its_x86_64_targets_and_the_receipt_names_the_c_only_ones(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        zig, source, runtime, targets, present = self.cppCalls[0]
        self.assertEqual((zig, source, targets), ("/z/zig", self.engine, ["x86_64-linux-gnu.2.31", "x86_64-windows-gnu"]))
        self.assertEqual((os.path.basename(runtime), present), ("runtime", ["notices", "wasm32-wasi", "windows", "x86_64-linux-gnu.2.31",
                                                                           "x86_64-linux-gnu.2.31.cfg"]))
        receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
        self.assertEqual(receipt["cppRuntimeProvenance"], "runtime/notices/cpp-provenance.json")
        self.assertEqual(receipt["cppTargets"], ["x86_64-linux-gnu.2.31", "x86_64-windows-gnu"])
        self.assertEqual(receipt["cOnlyTargets"], ["wasm32-wasi", "aarch64-linux-gnu.2.31", "aarch64-windows-gnu"])
        listed = [l.split("  ", 1)[1] for l in read(os.path.join(out, "FILES.sha256")).splitlines()]
        for rel in ("runtime/x86_64-linux-gnu.2.31.cxx.cfg", "runtime/notices/cpp-provenance.json"):
            self.assertIn(rel, listed)

    def test_the_cpp_overlay_follows_the_selected_targets_only(self):
        for requested, cpp, cOnly in ((["x86_64-windows-gnu"], ["x86_64-windows-gnu"], []),
                                      (["x86_64-linux-gnu.2.31", "aarch64-windows-gnu"], ["x86_64-linux-gnu.2.31"],
                                       ["aarch64-windows-gnu"]),
                                      (["wasm32-wasi"], None, None), (["aarch64-windows-gnu"], None, None)):
            self.cppCalls.clear()
            out = self.path("bundle-" + "-".join(requested))
            pb.prepareBundle(self.engine, "/z/zig", out, requested)
            receipt = json.loads(read(os.path.join(out, "notices", "bundle-provenance.json")))
            self.assertEqual([call[3] for call in self.cppCalls], [cpp] if cpp else [], msg=requested)
            self.assertEqual(receipt.get("cppTargets"), cpp, msg=requested)
            self.assertEqual(receipt.get("cOnlyTargets"), cOnly, msg=requested)
            self.assertEqual("cppRuntimeProvenance" in receipt, bool(cpp), msg=requested)

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
            write(os.path.join(output, "notices", "runtime-provenance.json"), "{}\n")
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


class BundleLayoutTest(unittest.TestCase):
    """The runtime and engine layouts a bundle relies on, through the real producers' checks."""

    def test_the_bundle_runtime_is_written_for_the_engine_root_above_it(self):
        self.assertEqual(pb.ENGINE_RELATIVE, "..")
        self.assertEqual(pr.checkEngineRelative(pb.ENGINE_RELATIVE), 1)


if __name__ == "__main__":
    unittest.main()
