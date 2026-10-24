import hashlib
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

import prepareBundle as pb
import prepareEngine as pe
import prepareRuntime as pr


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
        for patcher in (mock.patch.object(pe, "verifyEngine", side_effect=self.verify),
                        mock.patch.object(pr, "prepareRuntime", side_effect=self.prepareRuntime)):
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
        return output, []

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

    def test_the_identity_covers_every_file_of_the_bundle_and_replaces_the_engine_identity(self):
        out = self.path("bundle")
        pb.prepareBundle(self.engine, "/z/zig", out, [])
        listed = [l.split("  ", 1)[1] for l in read(os.path.join(out, "FILES.sha256")).splitlines()]
        self.assertEqual(listed, pe.listFiles(out))
        for rel in ("bin/clang", "bin/clang-22", "lib/dep.dylib", "notices/provenance.json",
                    "notices/bundle-provenance.json", "runtime/x86_64-linux-gnu.2.31.cfg",
                    "runtime/notices/runtime-provenance.json", "HOST", "VERSION"):
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
