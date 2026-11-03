import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

import prepareDarwinRuntime as pd
import prepareEngine as pe
import prepareRuntime as pr


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareDarwinRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


def machO(cpu=0x0100000c, fileType=pd.MH_EXECUTE, dylib=pd.LIBSYSTEM, minos=pd.MINOS, platform=pd.PLATFORM_MACOS,
          signature=True):
    """A 64-bit Mach-O header with the load commands of a linked executable, enough for readMachO."""
    name = dylib.encode() + b"\0"
    name += b"\0" * (-len(name) % 8)
    commands = [(pd.LC_BUILD_VERSION, struct.pack("<IIIII", platform, minos, minos, 0, 0)),
                (pd.LC_MAIN, struct.pack("<QQ", 0, 0)),
                (pd.LC_LOAD_DYLIB, struct.pack("<IIII", 24, 2, 0, 0) + name)]
    if signature:
        commands.append((pd.LC_CODE_SIGNATURE, struct.pack("<II", 0, 0)))
    body = b"".join(struct.pack("<II", kind, 8 + len(payload)) + payload for kind, payload in commands)
    return struct.pack("<IiiIIIII", pd.MH_MAGIC_64, cpu, 0, fileType, len(commands), len(body), 0, 0) + body


class MachOTest(TempCase):
    def info(self, **kwargs):
        with open(self.path("f"), "wb") as f:
            f.write(machO(**kwargs))
        return pd.readMachO(self.path("f"))

    def test_the_load_commands_dylibs_and_build_version_are_read(self):
        info = self.info()
        self.assertEqual((info["cpuType"], info["dylibs"], info["build"]), (0x0100000c, [pd.LIBSYSTEM], (1, pd.MINOS)))
        self.assertIsNone(pd.machOProblem(info, pd.TARGET))

    def test_a_file_that_is_not_a_macho_is_refused(self):
        write(self.path("f"), "MZ" + "x" * 40)
        with self.assertRaisesRegex(pe.EngineError, "not a 64-bit Mach-O"):
            pd.readMachO(self.path("f"))

    def test_each_promise_of_an_executable_is_checked(self):
        self.assertIn("is not x86_64", pd.machOProblem(self.info(), pd.X64_TARGET))
        self.assertIn("LC_CODE_SIGNATURE is absent", pd.machOProblem(self.info(signature=False), pd.TARGET))
        self.assertIn("LC_CODE_SIGNATURE is present", pd.machOProblem(self.info(cpu=0x01000007), pd.X64_TARGET))
        self.assertIsNone(pd.machOProblem(self.info(cpu=0x01000007, signature=False), pd.X64_TARGET))
        self.assertIn("LC_MAIN", pd.machOProblem(self.info(fileType=6), pd.TARGET))
        self.assertIn("dylibs", pd.machOProblem(self.info(dylib="/usr/lib/libz.dylib"), pd.TARGET))
        self.assertIn("build version", pd.machOProblem(self.info(minos=0x000c0000), pd.TARGET))
        self.assertIn("build version", pd.machOProblem(self.info(platform=2), pd.TARGET))


class ConfigTest(unittest.TestCase):
    def test_a_config_names_the_target_with_the_minimum_version_the_sysroot_and_the_engine_linker(self):
        for target, arch in ((pd.TARGET, "aarch64"), (pd.X64_TARGET, "x86_64")):
            self.assertEqual(pd.renderDarwinConfig(target), "\n".join([
                "--target=%s-apple-macos11.0" % arch, "-isysroot <CFGDIR>/sysroot",
                "--ld-path=<CFGDIR>/../../bin/ld64.lld", "-nostdlib",
                "-Xlinker <CFGDIR>/%s/libcompiler_rt.a" % target, "$-lSystem"]) + "\n")

    def test_the_config_names_no_other_architecture(self):
        self.assertNotIn("x86_64", pd.renderDarwinConfig(pd.TARGET))


class PipelineTest(TempCase):
    def setUp(self):
        super().setUp()
        self.lib = self.path("zig", "lib")
        write(os.path.join(self.lib, "libc", "include", "any-darwin-any", "stdio.h"), "stdio\n")
        write(os.path.join(self.lib, "libc", "include", "any-darwin-any", "sys", "types.h"), "types\n")
        write(os.path.join(self.lib, "libc", "darwin", "libSystem.tbd"), "tbd\n")
        write(os.path.join(self.lib, "libc", "darwin", "SDKSettings.json"), "{}\n")
        write(self.path("zig", "LICENSE"), "zig license")
        self.zig = self.path("zig", "zigfake")
        write(self.zig, "#!/bin/sh\n")
        os.chmod(self.zig, 0o755)
        self.engine = self.path("engine")
        os.makedirs(self.engine)
        self.verify = mock.patch.object(pd, "verifyConfigs").start()
        mock.patch.object(pr, "normalizeInput").start()
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(pr, "engineMajor", return_value=("aarch64-macos", "22.1.1", "22")).start()
        mock.patch.object(pr, "zigIdentity", return_value={"version": "0.16.0", "sha256": "ab"}).start()
        self.builtins = mock.patch.object(pd, "zigBuiltins", side_effect=self.fakeBuiltins).start()

    def fakeBuiltins(self, zig, target, work):
        path = self.path("cache", target, pd.BUILTINS)
        write(path, "builtins " + target + "\n")
        return path

    def receipt(self, out):
        return json.loads(read(os.path.join(out, "notices", pd.PROVENANCE)))

    def test_the_runtime_has_a_sysroot_two_configs_the_zig_notice_and_a_receipt(self):
        out = self.path("rt", "darwin")
        pd.prepareDarwinRuntime(self.zig, self.engine, out)
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-macos", "aarch64-macos.cfg", "notices", "sysroot", "x86_64-macos",
                                                   "x86_64-macos.cfg"])
        self.assertEqual(read(os.path.join(out, "x86_64-macos", pd.BUILTINS)), "builtins x86_64-macos\n")
        self.assertEqual(read(os.path.join(out, "sysroot", "usr", "include", "sys", "types.h")), "types\n")
        self.assertEqual(read(os.path.join(out, "sysroot", "usr", "lib", "libSystem.tbd")), "tbd\n")
        self.assertEqual(os.listdir(os.path.join(out, "sysroot")), ["usr"])
        self.assertEqual(read(os.path.join(out, "notices", "zig", "LICENSE")), "zig license")
        self.assertIn("--target=x86_64-apple-macos11.0\n", read(os.path.join(out, "x86_64-macos.cfg")))
        self.verify.assert_called_once()
        self.assertEqual(self.verify.call_args[0][2], [pd.TARGET, pd.X64_TARGET])

    def test_the_receipt_certifies_nothing_and_names_the_stub_headers_and_what_was_left_out(self):
        out = self.path("rt", "darwin")
        pd.prepareDarwinRuntime(self.zig, self.engine, out)
        receipt = self.receipt(out)
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual((receipt["targets"], receipt["engineRelative"], receipt["minimumMacosVersion"]),
                         ([pd.TARGET, pd.X64_TARGET], "../..", "11.0"))
        self.assertEqual(receipt["sysrootContents"]["headers"]["files"], 2)
        self.assertEqual(receipt["sysrootContents"]["stub"]["sha256"],
                         pe.sha256File(os.path.join(out, "sysroot", "usr", "lib", "libSystem.tbd")))
        self.assertEqual(receipt["zigFilesNotCarried"], ["lib/libc/darwin/SDKSettings.json"])
        self.assertEqual(receipt["notices"], ["notices/zig/LICENSE"])
        self.assertEqual(receipt["builtins"][pd.TARGET]["sha256"],
                         pe.sha256File(os.path.join(out, pd.TARGET, pd.BUILTINS)))
        self.assertTrue(any("never run" in limit for limit in receipt["limits"]))

    def test_one_target_alone_leaves_the_other_out_and_an_unknown_or_repeated_target_is_refused(self):
        out = self.path("rt", "darwin")
        pd.prepareDarwinRuntime(self.zig, self.engine, out, [pd.X64_TARGET])
        self.assertEqual(sorted(f for f in os.listdir(out) if f.endswith(".cfg")), ["x86_64-macos.cfg"])
        self.assertFalse(os.path.exists(os.path.join(out, pd.TARGET)))
        self.assertEqual(self.receipt(out)["targets"], [pd.X64_TARGET])
        for bad in (["x86_64-windows-gnu"], [pd.TARGET, pd.TARGET]):
            with self.assertRaisesRegex(pe.EngineError, "unknown or duplicated"):
                pd.prepareDarwinRuntime(self.zig, self.engine, self.path("bad", "darwin"), bad)

    def test_an_existing_output_is_never_replaced_and_a_failure_leaves_nothing(self):
        os.makedirs(self.path("rt", "darwin"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pd.prepareDarwinRuntime(self.zig, self.engine, self.path("rt", "darwin"))
        self.verify.side_effect = pe.EngineError("link failed")
        with self.assertRaisesRegex(pe.EngineError, "link failed"):
            pd.prepareDarwinRuntime(self.zig, self.engine, self.path("out", "darwin"))
        self.assertEqual(os.listdir(self.path("out")), [])

    def test_a_zig_without_the_headers_the_stub_or_the_license_is_refused_before_any_output(self):
        os.remove(os.path.join(self.lib, "libc", "darwin", "libSystem.tbd"))
        with self.assertRaisesRegex(pe.EngineError, "has no libc/include/any-darwin-any"):
            pd.prepareDarwinRuntime(self.zig, self.engine, self.path("a", "darwin"))
        write(os.path.join(self.lib, "libc", "darwin", "libSystem.tbd"))
        os.remove(self.path("zig", "LICENSE"))
        with self.assertRaisesRegex(pe.EngineError, "LICENSE is missing"):
            pd.prepareDarwinRuntime(self.zig, self.engine, self.path("b", "darwin"))
        self.assertEqual(os.listdir(self.path("b")), [])

    def test_a_symlink_in_the_headers_is_refused(self):
        try:
            os.symlink("stdio.h", os.path.join(self.lib, "libc", "include", "any-darwin-any", "link.h"))
        except (OSError, NotImplementedError):
            self.skipTest("no symlinks here")
        with self.assertRaisesRegex(pe.EngineError, "symlink"):
            pd.prepareDarwinRuntime(self.zig, self.engine, self.path("rt", "darwin"))

    def test_the_standalone_form_is_a_new_runtime_directory_holding_only_darwin(self):
        output, targets = pd.prepareRuntimeDirectory(self.zig, self.engine, self.path("fresh", "runtime"))
        self.assertEqual((os.listdir(output), targets), (["darwin"], [pd.TARGET, pd.X64_TARGET]))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pd.prepareRuntimeDirectory(self.zig, self.engine, output)


class RealLinkTest(TempCase):
    """Both targets through a real clang and ld64.lld, at -O0 and -O2 -flto=thin, with the linked files read as Mach-O.
    Needs MANAGED_TOOLCHAIN_ZIG_LIB=<a Zig lib directory>, MANAGED_TOOLCHAIN_ZIG=<its zig> and
    MANAGED_TOOLCHAIN_DARWIN_ENGINE=<a directory with bin/clang and bin/ld64.lld>."""

    def setUp(self):
        super().setUp()
        lib, engine = os.environ.get("MANAGED_TOOLCHAIN_ZIG_LIB"), os.environ.get("MANAGED_TOOLCHAIN_DARWIN_ENGINE")
        if not (lib and engine):
            self.skipTest("needs MANAGED_TOOLCHAIN_ZIG_LIB and MANAGED_TOOLCHAIN_DARWIN_ENGINE")
        self.darwin = self.path("runtime", "darwin")
        os.makedirs(self.darwin)
        pd.copySysroot(lib, self.darwin)
        zig = os.environ.get("MANAGED_TOOLCHAIN_ZIG")
        if not zig:
            self.skipTest("needs MANAGED_TOOLCHAIN_ZIG beside MANAGED_TOOLCHAIN_ZIG_LIB")
        pd.copyBuiltins(zig, engine, self.darwin, pd.TARGETS, self.dir)
        for target in pd.TARGETS:
            pe.writeText(os.path.join(self.darwin, pd.configName(target)), pd.renderDarwinConfig(target))
        self.clang = os.path.join(engine, "bin", "clang")
        os.makedirs(self.path("bin"))
        for name in os.listdir(os.path.join(engine, "bin")):
            if name.startswith("ld64.lld"):
                shutil.copy(os.path.join(engine, "bin", name), self.path("bin", name))

    def test_each_target_links_a_macho_at_both_optimization_levels(self):
        run = lambda command: subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             universal_newlines=True)
        for target in pd.TARGETS:
            work = self.path("work-" + target)
            os.makedirs(work)
            outputs = pd.checkDarwinConfig(run, self.clang, self.darwin, work, target)
            self.assertEqual(len(outputs), 2, msg=target)


if __name__ == "__main__":
    unittest.main()
