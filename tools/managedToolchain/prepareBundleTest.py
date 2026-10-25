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
        write(os.path.join(output, "notices", "runtime-provenance.json"), json.dumps(self.runtimeReceipt) + "\n")
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


class AugmentCase(BundleCase):
    runtimeReceipt = {"kind": "runtime", "zig": ZIG, "engineRelative": "..",
                      "targets": [{"target": X64}, {"target": ARM}, {"target": "wasm32-wasi"}]}

    def setUp(self):
        super().setUp()
        self.bundle = self.path("base")
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
        for value in ("/tmp", "../..", "..", ".", "", "x86-linux-gnu/..", "/"):
            joined = os.path.join(runtime, "include", "libc", value)
            self.assertTrue(os.path.isdir(joined), msg="%r must exist for the old gate to accept it" % value)
            overlay = self.editReceipt("inc-" + (value.replace("/", "_") or "empty"),
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


class BundleLayoutTest(unittest.TestCase):
    """The runtime and engine layouts a bundle relies on, through the real producers' checks."""

    def test_the_bundle_runtime_is_written_for_the_engine_root_above_it(self):
        self.assertEqual(pb.ENGINE_RELATIVE, "..")
        self.assertEqual(pr.checkEngineRelative(pb.ENGINE_RELATIVE), 1)


if __name__ == "__main__":
    unittest.main()
