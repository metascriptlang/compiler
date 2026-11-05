import hashlib
import os
import shutil
import tempfile
import unittest

import prepareEngine as pe
import prepareEngineFromSource as src


class RecipeTest(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareEngineFromSourceTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def tarball(self, name="llvm-project-23.1.4.src.tar.xz", body=b"x"):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(body)
        return path, hashlib.sha256(body).hexdigest()

    def test_configure_names_the_cache_and_source_tree(self):
        command = src.configureCommand("/s", "/b", "/p")
        self.assertEqual(command[command.index("-S") + 1], "/s/llvm")
        self.assertEqual(command[command.index("-C") + 1], src.CACHE_FILE)
        self.assertIn("-DCMAKE_INSTALL_PREFIX=/p", command)

    def test_cache_file_selects_driver_build_and_targets(self):
        with open(src.CACHE_FILE) as f:
            text = f.read()
        self.assertIn("LLVM_TOOL_LLVM_DRIVER_BUILD ON", text)
        self.assertIn('"X86;AArch64;WebAssembly"', text)
        self.assertIn("LLVM_ENABLE_ASSERTIONS OFF", text)
        self.assertRegex(text, r'set\(LLVM_DISTRIBUTION_COMPONENTS\s+"[^\"]*;llvm-rc;')

    def test_build_rejects_zero_jobs(self):
        with self.assertRaisesRegex(pe.EngineError, "at least 1"):
            src.buildCommand("/b", 0)
        self.assertIn("-j16", src.buildCommand("/b", 16))

    def test_run_reports_the_real_exit_code(self):
        src.run(["sh", "-c", "exit 0"])
        with self.assertRaisesRegex(pe.EngineError, r"rc=7"):
            src.run(["sh", "-c", "exit 7"])

    def test_sha_mismatch_is_refused_before_extraction(self):
        path, digest = self.tarball()
        src.verifySource(path, digest)
        with self.assertRaisesRegex(pe.EngineError, "expected"):
            src.verifySource(path, "0" * 64)
        with self.assertRaisesRegex(pe.EngineError, "64 lowercase"):
            src.verifySource(path, "abc")

    def test_non_source_tarball_name_is_refused(self):
        path, digest = self.tarball("clang.tar.xz")
        with self.assertRaisesRegex(pe.EngineError, "source tarball"):
            src.prepareFromSource(path, digest, self.dir, os.path.join(self.dir, "out"), 1)

    def test_provenance_names_tarball_digest_and_cache(self):
        path, digest = self.tarball()
        record = src.writeProvenance(self.dir, path, digest, src.CACHE_FILE)
        self.assertEqual(record["source_sha256"], digest)
        self.assertEqual(record["llvm_version"], "23.1.4")
        self.assertEqual(record["cache_sha256"], pe.sha256File(src.CACHE_FILE))


if __name__ == "__main__":
    unittest.main()
