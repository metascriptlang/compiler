import hashlib
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareEngineFromSource as src
import prepareLinuxEngine as linux


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


    def packageInputs(self):
        install, runtime, source, output = [os.path.join(self.dir, name)
                                             for name in ("install", "runtime", "source", "engine")]
        files = {"bin/llvm": "multicall", "lib/clang/23/include/stddef.h": "header"}
        for name, text in files.items():
            path = os.path.join(install, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
        for name in pe.LLVM_TOOLS + pe.CLANG_ALIASES + pe.LLD_ALIASES + ("lld", "llvm-readobj"):
            os.symlink("llvm", os.path.join(install, "bin", name))
        os.makedirs(runtime)
        for name in ("builtins", "ubsan_minimal"):
            with open(os.path.join(runtime, "libclang_rt." + name + ".a"), "wb") as f:
                f.write(b"!<arch>\n" + name.encode())
        for name in ("llvm", "compiler-rt"):
            path = os.path.join(source, name, "LICENSE.TXT")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write("Apache License v2.0 with LLVM Exceptions\n")
        cmake = os.path.join(source, "cmake", "Modules", "LLVMVersion.cmake")
        os.makedirs(os.path.dirname(cmake))
        with open(cmake, "w") as f:
            f.write("set(LLVM_VERSION_MAJOR 23)\nset(LLVM_VERSION_MINOR 1)\nset(LLVM_VERSION_PATCH 4)\n")
        tarball, digest = self.tarball()
        src.writeProvenance(install, tarball, digest, src.CACHE_FILE)
        self.enterContext(mock.patch.object(linux, "sys")).platform = "linux"
        self.enterContext(mock.patch.object(linux.platform, "machine", return_value="x86_64"))
        self.enterContext(mock.patch.object(pe, "toolVersion", return_value="23.1.4"))
        self.enterContext(mock.patch.object(pe, "verifyEngine"))
        return install, runtime, source, output

    def test_package_keeps_one_multicall_payload_and_exact_source_runtime_licenses(self):
        install, runtime, source, output = self.packageInputs()
        src.packageLinuxEngine(install, runtime, source, output)
        self.assertEqual(os.readlink(os.path.join(output, "bin/clang-23")), "llvm")
        self.assertFalse(os.path.islink(os.path.join(output, "bin/llvm-readobj")))
        self.assertEqual(os.stat(os.path.join(output, "bin/llvm")).st_ino,
                         os.stat(os.path.join(output, "bin/llvm-readobj")).st_ino)
        with open(os.path.join(output, "notices/provenance.json")) as f:
            receipt = json.load(f)
        self.assertEqual(receipt["kind"], "local-source-engine-proof")
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual(set(receipt["licenses"]), {"llvm", "compiler-rt"})
        self.assertTrue(receipt["noticeGaps"])
        for name in ("builtins", "ubsan_minimal"):
            target = os.path.join(output, "lib/clang/23/lib/linux/libclang_rt." + name + "-x86_64.a")
            self.assertEqual(pe.sha256File(target), receipt["runtimeArchives"][name]["sha256"])
        self.assertTrue(os.path.isfile(os.path.join(output, "IDENTITY")))

    def test_package_cli_uses_verified_install_without_rebuilding(self):
        install, runtime, source, output = self.packageInputs()
        tarball = os.path.join(self.dir, "llvm-project-23.1.4.src.tar.xz")
        with mock.patch.object(src, "prepareFromSource", side_effect=AssertionError("must not rebuild")):
            self.assertEqual(src.main(["--source-tarball", tarball,
                                       "--source-sha256", pe.sha256File(tarball),
                                       "--package-install", install, "--runtime-dir", runtime,
                                       "--source-tree", source, "--output", output]), 0)
        self.assertTrue(os.path.isfile(os.path.join(output, "IDENTITY")))

    def test_package_refuses_invalid_archive_without_partial_output(self):
        args = self.packageInputs()
        with open(os.path.join(args[1], "libclang_rt.builtins.a"), "wb") as f:
            f.write(b"not an archive")
        with self.assertRaisesRegex(pe.EngineError, "static compiler-rt archive"):
            src.packageLinuxEngine(*args)
        self.assertFalse(os.path.lexists(args[3]))

    def test_package_refuses_linux_arm64_without_mocking_host_detector(self):
        args = self.packageInputs()
        with mock.patch.object(linux.platform, "machine", return_value="aarch64"):
            with self.assertRaisesRegex(pe.EngineError, "unsupported host linux aarch64"):
                src.packageLinuxEngine(*args)
        self.assertFalse(os.path.lexists(args[3]))

    def test_package_refuses_missing_runtime_and_does_not_leave_output(self):
        args = self.packageInputs()
        os.remove(os.path.join(args[1], "libclang_rt.ubsan_minimal.a"))
        with self.assertRaisesRegex(pe.EngineError, "missing.*ubsan_minimal"):
            src.packageLinuxEngine(*args)
        self.assertFalse(os.path.lexists(args[3]))

    def test_package_refuses_existing_output_without_replacing_it(self):
        args = self.packageInputs()
        os.mkdir(args[3])
        with self.assertRaisesRegex(pe.EngineError, "exists"):
            src.packageLinuxEngine(*args)
        self.assertEqual(os.listdir(args[3]), [])

    def test_package_refuses_source_engine_version_mismatch(self):
        args = self.packageInputs()
        with mock.patch.object(pe, "toolVersion", return_value="24.0.0"):
            with self.assertRaisesRegex(pe.EngineError, "does not match"):
                src.packageLinuxEngine(*args)
        self.assertFalse(os.path.lexists(args[3]))

    def test_package_refuses_an_alias_leaving_the_install_tree(self):
        args = self.packageInputs()
        alias = os.path.join(args[0], "bin/clang")
        os.remove(alias)
        os.symlink(os.path.join(args[2], "llvm/LICENSE.TXT"), alias)
        with self.assertRaisesRegex(pe.EngineError, "symlink bin/clang leaves the bundle"):
            src.packageLinuxEngine(*args)
        self.assertFalse(os.path.lexists(args[3]))


if __name__ == "__main__":
    unittest.main()
