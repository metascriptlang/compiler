import json
import os
import unittest
from unittest import mock

import prepareEngine as pe
import prepareWindowsEngine as pw
from prepareWindowsEngineTest import World, buildPe, fieldsOf, read


ARM64_HOST = "aarch64-windows"
ARM64_MACHINE = 0xaa64


class Arm64EngineTest(World):
    def setUp(self):
        super().setUp()
        self.detect.return_value = ARM64_HOST
        for tool in pw.TOOLS:
            path = os.path.join(self.bin, tool)
            fields = fieldsOf(path)
            fields["machine"] = ARM64_MACHINE
            buildPe(path, **fields)
        resource = os.path.join(self.llvm, "lib", "clang", "22", "lib", "windows")
        os.rename(os.path.join(resource, "clang_rt.builtins-x86_64.lib"),
                  os.path.join(resource, "clang_rt.builtins-aarch64.lib"))

    def test_preparation_preserves_the_arm64_host_and_requires_arm64_builtins(self):
        output, (host, version, count), plan, _ = self.prepare()
        self.assertEqual((host, version, count), (ARM64_HOST, "22.1.1", len(pw.TOOLS)))
        self.assertEqual(read(os.path.join(output, "HOST")), ARM64_HOST + "\n")
        receipt = json.loads(read(os.path.join(output, "notices", "provenance.json")))
        self.assertEqual(receipt["host"], ARM64_HOST)
        self.assertIn("lib/clang/22/lib/windows/clang_rt.builtins-aarch64.lib", plan)
        self.assertNotIn("lib/clang/22/lib/windows/clang_rt.builtins-x86_64.lib", plan)

    def test_the_arm64_symbolizer_uses_crypto_and_http_from_the_os(self):
        buildPe(os.path.join(self.bin, "llvm-symbolizer.exe"), machine=ARM64_MACHINE,
                imports=["CRYPT32.dll", "WINHTTP.dll", "KERNEL32.dll"])
        _, _, plan, _ = self.prepare()
        self.assertFalse([p for p in plan if p.casefold().endswith(("crypt32.dll", "winhttp.dll"))])

    def test_a_resealed_arm64_bundle_still_refuses_an_x64_tool(self):
        output, _, _, _ = self.prepare()
        buildPe(os.path.join(output, "bin", "llvm-nm.exe"))
        pe.writeContract(output, ARM64_HOST, "22.1.1")
        with self.assertRaisesRegex(pe.EngineError, "machine 0x8664, not ARM64"):
            pe.verifyEngine(output, self.inspector)

    def test_an_x64_tool_is_refused_in_an_arm64_engine(self):
        buildPe(os.path.join(self.bin, "llvm-nm.exe"))
        self.refused(r"llvm-nm\.exe: machine 0x8664, not ARM64")

    def test_an_x64_dependency_is_refused_in_an_arm64_engine(self):
        buildPe(os.path.join(self.bin, "llvm-nm.exe"), machine=ARM64_MACHINE,
                imports=["foreign.dll"])
        self.dll("foreign.dll")
        self.refused(r"foreign\.dll: machine 0x8664, not ARM64")

    def test_an_arm64_engine_cannot_use_its_bundled_inspector_on_an_x64_host(self):
        output, _, _, _ = self.prepare()
        self.detect.return_value = pe.WINDOWS_X64
        with self.assertRaisesRegex(pe.EngineError, "cannot run.*pass --inspector"):
            pw.bundledInspector(output, ARM64_HOST)
        with self.assertRaisesRegex(pe.EngineError, "cannot run.*pass --inspector"):
            pe.verifyEngine(output)
        inspector = buildPe(self.path("external-inspector.exe"))
        self.assertEqual(pe.verifyEngine(output, inspector)[:2], (ARM64_HOST, "22.1.1"))


class NativeWindowsHostTest(unittest.TestCase):
    def test_native_arm64_machine_spellings_choose_the_arm64_bundle(self):
        for machine in ("ARM64", "arm64", "aarch64"):
            with self.subTest(machine=machine), mock.patch.object(pw.sys, "platform", "win32"), \
                    mock.patch.object(pw.platform, "machine", return_value=machine):
                self.assertEqual(pw.detectHost(), ARM64_HOST)

    def test_a_foreign_windows_machine_is_not_guessed(self):
        with mock.patch.object(pw.sys, "platform", "win32"), \
                mock.patch.object(pw.platform, "machine", return_value="x86"):
            with self.assertRaisesRegex(pe.EngineError, "unsupported host windows x86"):
                pw.detectHost()


if __name__ == "__main__":
    unittest.main()
