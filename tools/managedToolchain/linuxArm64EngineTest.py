import json
import os
import unittest
from unittest import mock

import prepareEngine as pe
import prepareLinuxEngine as pl
from prepareLinuxEngineTest import World, buildElf, fields, read, write


ARM64_HOST = "aarch64-linux"
ARM64_LOADER = "/lib/ld-linux-aarch64.so.1"


class Arm64EngineTest(World):
    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(pl, "detectHost", return_value=ARM64_HOST)
        self.native = patcher.start()
        self.addCleanup(patcher.stop)
        old = self.hostLibs
        self.hostLibs = os.path.join(self.host, "usr", "lib", "aarch64-linux-gnu")
        os.rename(old, self.hostLibs)
        self.armTree(self.llvm)
        self.armTree(self.host)
        resource = os.path.join(self.llvm, "lib", "clang", "21", "lib", "linux")
        os.rename(os.path.join(resource, "libclang_rt.builtins-x86_64.a"),
                  os.path.join(resource, "libclang_rt.builtins-aarch64.a"))

    def armTree(self, root):
        for directory, _, names in os.walk(root):
            for name in names:
                path = os.path.join(directory, name)
                if os.path.islink(path) or not pl.isElf(path):
                    continue
                info = fields(path)
                info["machine"] = 183
                if info["interpreter"] is not None:
                    info["interpreter"] = ARM64_LOADER
                buildElf(path, **info)

    def overrideRoot(self, *args, **kwargs):
        root = super().overrideRoot(*args, **kwargs)
        parent = os.path.join(root, "usr", "lib")
        os.rename(os.path.join(parent, "x86_64-linux-gnu"), os.path.join(parent, "aarch64-linux-gnu"))
        control = os.path.join(root, "DEBIAN", "control")
        write(control, read(control).replace("Architecture: amd64", "Architecture: arm64"))
        self.armTree(root)
        return root

    def test_preparation_preserves_arm64_host_resource_and_dependency_closure(self):
        root = self.overrideRoot()
        output, (host, version, count), plan, _ = self.prepare(libraryDirs=[root])
        self.assertEqual((host, version), (ARM64_HOST, "21.1.8"))
        self.assertGreater(count, len(pl.TOOLS))
        self.assertEqual(read(os.path.join(output, "HOST")), ARM64_HOST + "\n")
        self.assertIn("lib/clang/21/lib/linux/libclang_rt.builtins-aarch64.a", plan)
        self.assertNotIn("lib/clang/21/lib/linux/libclang_rt.builtins-x86_64.a", plan)
        receipt = json.loads(read(os.path.join(output, "notices", "provenance.json")))
        self.assertEqual(receipt["host"], ARM64_HOST)
        self.assertEqual(receipt["glibcBaseline"], "2.39")
        for relative in pl.engineFiles(output):
            info = fields(os.path.join(output, relative))
            self.assertEqual(info["machine"], 183, relative)
            self.assertIn(info["interpreter"], (None, ARM64_LOADER), relative)

    def test_the_arm64_builtins_path_is_required_even_when_an_x64_archive_is_present(self):
        resource = os.path.join(self.llvm, "lib", "clang", "21", "lib", "linux")
        os.rename(os.path.join(resource, "libclang_rt.builtins-aarch64.a"),
                  os.path.join(resource, "libclang_rt.builtins-x86_64.a"))
        with self.assertRaisesRegex(pe.EngineError, "layout: missing .*libclang_rt.builtins-aarch64.a"):
            self.prepare(libraryDirs=[self.overrideRoot()])

    def test_an_x64_tool_or_dependency_is_refused(self):
        for relative in (("llvm", "bin", "llvm-nm"), ("libs", "libgcc_s.so.1")):
            with self.subTest(relative=relative):
                path = os.path.join(self.llvm, *relative[1:]) if relative[0] == "llvm" else os.path.join(self.hostLibs, relative[1])
                info = fields(path)
                buildElf(path, **dict(info, machine=62))
                with self.assertRaisesRegex(pe.EngineError, "machine 62, not aarch64"):
                    self.prepare(libraryDirs=[self.overrideRoot()])
                buildElf(path, **info)

    def test_a_foreign_loader_is_refused_even_for_an_arm64_tool(self):
        path = os.path.join(self.llvm, "bin", "clang")
        buildElf(path, **dict(fields(path), interpreter="/lib64/ld-linux-x86-64.so.2"))
        with self.assertRaisesRegex(pe.EngineError, "interpreter .* is not /lib/ld-linux-aarch64.so.1"):
            self.prepare(libraryDirs=[self.overrideRoot()])

    def test_the_bundled_inspector_is_never_run_on_another_native_machine(self):
        output, _, _, _ = self.prepare(libraryDirs=[self.overrideRoot()])
        self.native.return_value = pe.LINUX_X64
        with self.assertRaisesRegex(pe.EngineError, "cannot run.*pass --inspector"):
            pl.bundledInspector(output, ARM64_HOST)
        with self.assertRaisesRegex(pe.EngineError, "cannot run.*pass --inspector"):
            pe.verifyEngine(output)
        self.assertEqual(pe.verifyEngine(output, self.inspector)[:2], (ARM64_HOST, "21.1.8"))

    def test_resealed_bundles_still_refuse_wrong_machine_and_loader(self):
        output, _, _, _ = self.prepare(libraryDirs=[self.overrideRoot()])
        path = os.path.join(output, "bin", "llvm-nm")
        original = fields(path)
        for changed, message in ((dict(machine=62), "machine 62, not aarch64"),
                                  (dict(interpreter="/lib64/ld-linux-x86-64.so.2"), "interpreter .* is not /lib/ld-linux-aarch64.so.1")):
            buildElf(path, **dict(original, **changed))
            pe.writeContract(output, ARM64_HOST, "21.1.8")
            with self.assertRaisesRegex(pe.EngineError, message):
                pe.verifyEngine(output, self.inspector)

    def test_the_arm64_loader_is_host_provided_and_never_bundled(self):
        info = dict(type=3, machine=183, interpreter=None, needed=[], soname="ld-linux-aarch64.so.1",
                    runpath=None, rpath=None, verneed=[], verdef=[])
        self.assertIn("host-provided", pl.roleProblem("lib/ld-linux-aarch64.so.1", info, ARM64_HOST))
        self.assertIsNone(pl.wantedRunpath("/bundle", "/bundle/bin/clang", dict(info, needed=["ld-linux-aarch64.so.1"]),
                                         ARM64_HOST))


class NativeLinuxHostTest(unittest.TestCase):
    def test_native_arm64_machine_spellings_select_the_arm64_bundle(self):
        for machine in ("aarch64", "arm64", "AARCH64"):
            with self.subTest(machine=machine), mock.patch.object(pl.sys, "platform", "linux"), \
                    mock.patch.object(pl.platform, "machine", return_value=machine):
                self.assertEqual(pl.detectHost(), ARM64_HOST)

    def test_an_unknown_machine_or_foreign_os_is_refused(self):
        for system, machine in (("linux", "riscv64"), ("darwin", "arm64")):
            with mock.patch.object(pl.sys, "platform", system), mock.patch.object(pl.platform, "machine", return_value=machine):
                with self.assertRaisesRegex(pe.EngineError, "unsupported host"):
                    pl.detectHost()

    def test_library_search_is_specific_to_the_requested_architecture(self):
        directories = pl.libraryDirectories("/root", ARM64_HOST)
        self.assertEqual(directories[:2], [os.path.join("/root", "lib/aarch64-linux-gnu"),
                                          os.path.join("/root", "usr/lib/aarch64-linux-gnu")])
        self.assertFalse([p for p in directories if "x86_64" in p])
        self.assertEqual(pl.libraryDirectories("/root"), [os.path.join("/root", d) for d in pl.LIBRARY_DIRS])


if __name__ == "__main__":
    unittest.main()
