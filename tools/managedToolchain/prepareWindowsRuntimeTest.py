import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw

ARCHIVES = ["libmingw32.lib", "zigc.lib", "compiler_rt.lib", "ws2_32.lib", "bcrypt.lib", "mswsock.lib",
            "api-ms-win-crt-stdio-l1-1-0.lib", "kernel32.lib", "user32.lib"]
COMPILE = ("/z/zig clang /fx/runtimeWindows.c --no-default-config -target x86_64-unknown-windows-gnu -g -gcodeview "
           "-fno-lto -DNDEBUG -D__MSVCRT_VERSION__=0xE00 -D_WIN32_WINNT=0x0a00 -isystem /z/lib/include "
           "-isystem /z/lib/libc/include/x86_64-windows-gnu -isystem /z/lib/libc/include/generic-mingw "
           "-isystem /z/lib/libc/include/any-windows-any -Xclang -target-cpu -Xclang x86-64 "
           "-Xclang -target-feature -Xclang -amx-transpose -Xclang -target-feature -Xclang +sse2 -c -o /t/o.o")


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareWindowsRuntimeTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


def linkLine(cache, startup="crt2.obj", dll=False, archives=ARCHIVES, extra="", machine="X64"):
    options = "-lldmingw -ERRORLIMIT:0 -NOLOGO -DEBUG -PDB:p.pdb -PDBALTPATH:p.pdb -MLLVM:-float-abi=hard "
    options += "-BASE:5368709120 -BUILD-ID:NO -MACHINE:%s " % machine if dll else \
        "-STACK:16777216 -BASE:5368709120 -BUILD-ID:NO -MACHINE:%s " % machine
    options += ("-DLL " if dll else "") + "-BREPRO -OUT:/o/fixture -IMPLIB:/o/fixture.lib "
    inputs = " ".join("%s/%s" % (cache, n) for n in [startup] + archives)
    return "lld-link " + options + extra + "/l/runtimeWindows.obj -ALTERNATENAME:__image_base__=__ImageBase " + inputs


class LinkLineTest(TempCase):
    def setUp(self):
        super().setUp()
        self.cache = self.path("cache")
        for name in ["crt2.obj", "dllcrt2.obj"] + ARCHIVES:
            write(os.path.join(self.cache, name))

    def parse(self, line):
        return pw.parseCoffLinkArgv(line, "runtimeWindows.obj", self.cache, self.dir)

    def test_an_executable_line_yields_its_stack_base_and_ordered_inputs(self):
        found = self.parse(linkLine(self.cache))
        self.assertEqual((found["dll"], found["stack"], found["base"], found["machine"]),
                         (False, 16777216, 5368709120, "X64"))
        self.assertEqual([os.path.basename(p) for p in found["inputs"]], ["crt2.obj"] + ARCHIVES)
        self.assertEqual(found["notCarried"], ["-ALTERNATENAME:__image_base__=__ImageBase"])

    def test_a_dll_line_has_no_stack_and_names_the_dll_startup(self):
        found = self.parse(linkLine(self.cache, "dllcrt2.obj", True))
        self.assertEqual((found["dll"], found["stack"]), (True, None))
        self.assertEqual(os.path.basename(found["inputs"][0]), "dllcrt2.obj")

    def test_the_machine_is_read_from_the_line_and_a_line_without_one_is_refused(self):
        self.assertEqual(self.parse(linkLine(self.cache, machine="ARM64"))["machine"], "ARM64")
        with self.assertRaisesRegex(pe.EngineError, "no -MACHINE"):
            self.parse(linkLine(self.cache).replace("-MACHINE:X64 ", ""))

    def test_an_option_that_is_neither_carried_nor_named_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "-OPT:NOICF is not understood"):
            self.parse(linkLine(self.cache, extra="-OPT:NOICF "))

    def test_an_input_outside_the_private_cache_or_before_the_fixture_object_is_refused(self):
        write(self.path("elsewhere.lib"))
        with self.assertRaisesRegex(pe.EngineError, "not from this run's private cache"):
            self.parse(linkLine(self.cache) + " " + self.path("elsewhere.lib"))
        with self.assertRaisesRegex(pe.EngineError, "comes before the fixture object"):
            self.parse(linkLine(self.cache, extra=self.cache + "/zigc.lib "))

    def test_a_line_without_the_fixture_object_or_a_base_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "0 times"):
            self.parse("lld-link -BASE:5368709120 -OUT:/o/fixture")
        with self.assertRaisesRegex(pe.EngineError, "comes before the fixture object"):
            self.parse(linkLine(self.cache).replace("runtimeWindows.obj", "other.obj"))
        with self.assertRaisesRegex(pe.EngineError, "no -BASE"):
            self.parse(linkLine(self.cache).replace("-BASE:5368709120 ", ""))

    def test_the_select_function_takes_the_one_lld_link_line_that_writes_the_output(self):
        stderr = "\n".join([COMPILE, "ar rcs x.a", linkLine(self.cache), "lld-link -OUT:/o/other " + self.cache])
        compile_, link = pw.selectWindowsLines(stderr, "/fx/runtimeWindows.c", "/o/fixture")
        self.assertEqual((compile_, link), (COMPILE, linkLine(self.cache)))
        with self.assertRaisesRegex(pe.EngineError, "found 1 and 0"):
            pw.selectWindowsLines(COMPILE, "/fx/runtimeWindows.c", "/o/fixture")


class LibraryTailTest(unittest.TestCase):
    def test_the_tail_is_the_archive_stems_in_link_order(self):
        stems = pw.libraryTail(["/c/crt2.obj"] + ["/c/" + n for n in ARCHIVES], "crt2.obj")
        self.assertEqual(stems, [n[:-4] for n in ARCHIVES])

    def test_the_other_startup_object_a_non_archive_and_a_missing_runtime_archive_are_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "not dllcrt2.obj"):
            pw.libraryTail(["/c/crt2.obj", "/c/libmingw32.lib"], "dllcrt2.obj")
        with self.assertRaisesRegex(pe.EngineError, "not a .lib"):
            pw.libraryTail(["/c/crt2.obj", "/c/extra.o"], "crt2.obj")
        with self.assertRaisesRegex(pe.EngineError, "no zigc.lib"):
            pw.libraryTail(["/c/crt2.obj", "/c/libmingw32.lib", "/c/compiler_rt.lib"], "crt2.obj")


ARM_COMPILE = COMPILE.replace("x86_64-unknown-windows-gnu", "aarch64-unknown-windows-gnu").replace(
    "-Xclang x86-64 ", "-Xclang generic ").replace("-Xclang -target-feature -Xclang -amx-transpose ",
                                                  "-Xclang -target-feature -Xclang -tme ")
ARM_REMOVED = ["-no-zcz-fp", "-tme", "-zcz", "-zcz-gp"]


class ConfigTest(unittest.TestCase):
    def render(self, variant, target=pw.TARGET):
        compile_ = pr.parseCompileArgv(ARM_COMPILE if target == pw.ARM64_TARGET else COMPILE)
        compile_["features"], _ = pr.translateFeatures(compile_["features"], target, compile_["cpu"], "0.16.0", "22")
        link = {"stack": 16777216 if variant == "exe" else None, "base": 0x140000000}
        return pw.renderWindowsConfig(variant, compile_, link, ["any-windows-any"], [n[:-4] for n in ARCHIVES], "22",
                                      target)

    def test_the_arm64_configs_carry_their_own_target_cpu_directory_and_startup_object(self):
        exe, dll = self.render("exe", pw.ARM64_TARGET).splitlines(), self.render("dll", pw.ARM64_TARGET).splitlines()
        self.assertIn("-target aarch64-unknown-windows-gnu", exe)
        self.assertIn("-Xclang -target-cpu -Xclang generic", exe)
        self.assertIn("--sysroot=<CFGDIR>/aarch64-windows-gnu", exe)
        self.assertIn("-Xlinker <CFGDIR>/aarch64-windows-gnu/crt2.obj", exe)
        self.assertIn("--ld-path=<CFGDIR>/../../bin/ld.lld", exe)
        self.assertIn("--sysroot=<CFGDIR>/aarch64-windows-gnu.dll", dll)
        self.assertIn("-Xlinker <CFGDIR>/aarch64-windows-gnu.dll/dllcrt2.obj", dll)
        self.assertIn("-shared", dll)
        self.assertNotIn("-shared", exe)
        for lines in (exe, dll):
            self.assertEqual([l for l in lines if l.startswith("$")], ["$-l" + n[:-4] for n in ARCHIVES])
            self.assertFalse(any("x86" in l or "amd64" in l.lower() for l in lines))
        self.assertNotIn("tme", "\n".join(exe))

    def test_the_executable_config_reaches_the_engine_two_levels_up_and_the_startup_object_first(self):
        lines = self.render("exe").splitlines()
        self.assertIn("-target x86_64-unknown-windows-gnu", lines)
        self.assertIn("--ld-path=<CFGDIR>/../../bin/ld.lld", lines)
        self.assertIn("-isystem <CFGDIR>/../../lib/clang/22/include", lines)
        self.assertIn("-isystem <CFGDIR>/include/libc/any-windows-any", lines)
        self.assertIn("--sysroot=<CFGDIR>/x86_64-windows-gnu", lines)
        self.assertIn("-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu", lines)
        self.assertIn("-Xlinker --stack=16777216", lines)
        self.assertIn("-Xlinker --image-base=0x140000000", lines)
        self.assertIn("-Xlinker <CFGDIR>/x86_64-windows-gnu/crt2.obj", lines)
        self.assertNotIn("-shared", lines)

    def test_the_archives_are_dollar_lines_after_every_other_line_in_the_given_order(self):
        lines = self.render("exe").splitlines()
        tail = [l for l in lines if l.startswith("$")]
        self.assertEqual(tail, ["$-l" + n[:-4] for n in ARCHIVES])
        self.assertEqual(lines[-len(tail):], tail)
        self.assertFalse(any("$" in l for l in lines[:-len(tail)]))

    def test_the_dll_config_names_its_own_directory_startup_and_shared(self):
        lines = self.render("dll").splitlines()
        self.assertIn("-shared", lines)
        self.assertIn("--sysroot=<CFGDIR>/x86_64-windows-gnu.dll", lines)
        self.assertIn("-Xlinker <CFGDIR>/x86_64-windows-gnu.dll/dllcrt2.obj", lines)
        self.assertIn("-Xlinker --image-base=0x140000000", lines)
        self.assertFalse(any("--stack" in l for l in lines))

    def test_only_the_removed_disabled_feature_is_left_out_and_for_this_zig_engine_and_target(self):
        text = self.render("exe")
        self.assertNotIn("amx-transpose", text)
        self.assertIn("-Xclang -target-feature -Xclang +sse2\n", text)
        feature = ["-amx-transpose"]
        self.assertEqual(pr.translateFeatures(feature, pw.TARGET, "x86-64", "0.16.0", "22")[0], [])
        for other in (("x86_64-windows-gnu.dll", "x86-64", "0.16.0", "22"), (pw.TARGET, "znver4", "0.16.0", "22"),
                      (pw.TARGET, "x86-64", "0.17.0", "22"), (pw.TARGET, "x86-64", "0.16.0", "23")):
            self.assertEqual(pr.translateFeatures(feature, *other)[0], feature, msg=other)
        self.assertEqual(pr.translateFeatures(["-amx-tile", "+avx512f"], pw.TARGET, "x86-64", "0.16.0", "22")[0],
                         ["-amx-tile", "+avx512f"])

    def test_the_arm64_removed_features_are_left_out_only_for_this_zig_engine_target_and_cpu(self):
        for feature in ARM_REMOVED:
            self.assertEqual(pr.translateFeatures([feature, "+neon"], pw.ARM64_TARGET, "generic", "0.16.0", "22"),
                             (["+neon"], [e for e in pr.REMOVED_DISABLED_FEATURES if e["feature"] == feature]))
            for other in ((pw.TARGET, "generic", "0.16.0", "22"), (pw.ARM64_TARGET, "apple-m1", "0.16.0", "22"),
                          (pw.ARM64_TARGET, "generic", "0.17.0", "22"), (pw.ARM64_TARGET, "generic", "0.16.0", "23")):
                self.assertEqual(pr.translateFeatures([feature], *other)[0], [feature], msg=(feature, other))
        # an enabled feature of the same names, and a feature the table does not name, stay
        self.assertEqual(pr.translateFeatures(["+tme", "-sve", "-bogus"], pw.ARM64_TARGET, "generic", "0.16.0", "22")[0],
                         ["+tme", "-sve", "-bogus"])

    def test_each_arm64_translation_names_pinned_sources_for_both_llvm_versions_and_its_field_default(self):
        entries = {e["feature"]: e for e in pr.REMOVED_DISABLED_FEATURES if e["target"] == pw.ARM64_TARGET}
        self.assertEqual(sorted(entries), ARM_REMOVED)
        for feature, entry in entries.items():
            sources = "\n".join(entry["sources"])
            for version in ("llvmorg-21.1.0/", "llvmorg-22.1.1/"):
                self.assertIn(version + "llvm/lib/Target/AArch64/AArch64Features.td", sources, msg=feature)
                self.assertIn(version + "llvm/lib/Target/AArch64/AArch64Processors.td#L", sources, msg=feature)
            if feature != "-tme":
                self.assertIn("llvmorg-22.1.1/llvm/utils/TableGen/SubtargetEmitter.cpp#L172", sources, msg=feature)
        self.assertIn("no-zcz-fpr64", entries["-no-zcz-fp"]["reason"])
        self.assertIn("default, true for both", entries["-no-zcz-fp"]["reason"])
        for feature in ("-zcz", "-zcz-gp"):
            self.assertIn("zcz-gpr64", entries[feature]["reason"])
            self.assertIn("default false", entries[feature]["reason"])

    def test_a_path_that_would_need_quoting_is_refused(self):
        with self.assertRaises(pe.EngineError):
            pw.renderWindowsConfig("exe", pr.parseCompileArgv(COMPILE), {"stack": None, "base": 1},
                                   ["any windows"], ["a"], "22")


def section(name, virtualAddress, rawPointer, body):
    return struct.pack("<8sIIIIIIHHI", name, len(body), virtualAddress, len(body), rawPointer, 0, 0, 0, 0, 0)


def syntheticPe(path, machine=pw.MACHINE_AMD64, dll=False, subsystem=pw.SUBSYSTEM_CONSOLE,
                imports=(("WS2_32.dll", ["WSAStartup"]), ("bcrypt.dll", ["BCryptGenRandom"]),
                         ("KERNEL32.dll", ["ExitProcess"]), ("api-ms-win-crt-stdio-l1-1-0.dll", ["puts"])),
                exports=("addNumbers",)):
    """A PE32+ file whose one section holds the import and export tables, at RVA 0x1000 == file offset 0x400."""
    base, body = 0x1000, bytearray()
    place = lambda data: (len(body), body.extend(data))[0]
    names = {}
    for dll_, functions in imports:
        names[dll_] = (place(dll_.encode() + b"\0"), [place(b"\0\0" + f.encode() + b"\0") for f in functions])
    thunkAt = {}
    for dll_, (_, hints) in names.items():
        thunkAt[dll_] = place(b"".join(struct.pack("<Q", base + h) for h in hints) + struct.pack("<Q", 0))
    descriptors = place(b"".join(struct.pack("<IIIII", base + thunkAt[d], 0, 0, base + names[d][0], base + thunkAt[d])
                                 for d, _ in imports) + bytes(20))
    exportNames = [place(e.encode() + b"\0") for e in exports]
    nameTable = place(b"".join(struct.pack("<I", base + n) for n in exportNames))
    exportTable = place(struct.pack("<IIHHIIIIIII", 0, 0, 0, 0, 0, 1, len(exports), len(exports), 0, base + nameTable, 0))
    optional = bytearray(240)
    struct.pack_into("<H", optional, 0, 0x20b)
    struct.pack_into("<H", optional, 68, subsystem)
    struct.pack_into("<II", optional, 112, base + exportTable if exports else 0, 40)
    struct.pack_into("<II", optional, 120, base + descriptors, 40)
    coff = struct.pack("<HHIIIHH", machine, 1, 0, 0, 0, len(optional), 0x2000 if dll else 0x22)
    header = bytearray(0x400)
    header[:2] = b"MZ"
    struct.pack_into("<I", header, 0x3c, 0x80)
    header[0x80:0x84] = b"PE\0\0"
    header[0x84:0x84 + len(coff)] = coff
    header[0x98:0x98 + len(optional)] = optional
    sect = section(b".rdata", base, 0x400, body)
    header[0x98 + len(optional):0x98 + len(optional) + len(sect)] = sect
    with open(path, "wb") as f:
        f.write(bytes(header) + bytes(body))


class PeTest(TempCase):
    def test_machine_subsystem_imports_and_exports_are_read(self):
        syntheticPe(self.path("a.dll"), dll=True)
        info = pw.readPe(self.path("a.dll"))
        self.assertEqual((info["machine"], info["subsystem"]), (pw.MACHINE_AMD64, pw.SUBSYSTEM_CONSOLE))
        self.assertTrue(info["characteristics"] & pw.DLL_CHARACTERISTIC)
        self.assertEqual(info["imports"]["bcrypt.dll"], ["BCryptGenRandom"])
        self.assertEqual(sorted(info["imports"]), ["KERNEL32.dll", "WS2_32.dll", "api-ms-win-crt-stdio-l1-1-0.dll", "bcrypt.dll"])
        self.assertEqual(info["exports"], ["addNumbers"])

    def test_a_file_that_is_not_a_pe_is_refused(self):
        write(self.path("x"), "not a pe")
        with self.assertRaisesRegex(pe.EngineError, "not a PE"):
            pw.readPe(self.path("x"))

    def test_the_promise_of_each_variant_is_checked(self):
        syntheticPe(self.path("exe"), exports=())
        syntheticPe(self.path("dll"), dll=True)
        self.assertIsNone(pw.peProblem("exe", pw.readPe(self.path("exe"))))
        self.assertIsNone(pw.peProblem("dll", pw.readPe(self.path("dll"))))
        self.assertRegex(pw.peProblem("dll", pw.readPe(self.path("exe"))), "do not match a dll")
        self.assertRegex(pw.peProblem("exe", pw.readPe(self.path("dll"))), "do not match a exe")

    def test_the_machine_of_each_target_is_checked_and_the_other_one_refused(self):
        syntheticPe(self.path("arm"), machine=pw.MACHINE_ARM64, exports=())
        syntheticPe(self.path("x64"), exports=())
        self.assertEqual(pw.readPe(self.path("arm"))["machine"], 0xaa64)
        self.assertIsNone(pw.peProblem("exe", pw.readPe(self.path("arm")), pw.ARM64_TARGET))
        self.assertIsNone(pw.peProblem("exe", pw.readPe(self.path("x64")), pw.TARGET))
        self.assertIsNone(pw.peProblem("exe", pw.readPe(self.path("x64"))))
        self.assertRegex(pw.peProblem("exe", pw.readPe(self.path("arm"))), "0xaa64 is not AMD64")
        self.assertRegex(pw.peProblem("exe", pw.readPe(self.path("arm")), pw.TARGET), "not AMD64")
        self.assertRegex(pw.peProblem("exe", pw.readPe(self.path("x64")), pw.ARM64_TARGET), "0x8664 is not ARM64")

    def test_a_wrong_machine_subsystem_missing_export_or_missing_import_is_a_problem(self):
        cases = [({"machine": 0xaa64}, "exe", "not AMD64"), ({"subsystem": 2}, "exe", "not console"),
                 ({"dll": True, "exports": ()}, "dll", "lack addNumbers"),
                 ({"imports": (("KERNEL32.dll", ["ExitProcess"]),), "exports": ()}, "exe", "lack"),
                 ({"imports": (("WS2_32.dll", ["a"]), ("bcrypt.dll", ["b"]), ("KERNEL32.dll", ["c"])), "exports": ()},
                  "exe", "C runtime")]
        for arguments, variant, message in cases:
            syntheticPe(self.path("f"), **arguments)
            self.assertRegex(pw.peProblem(variant, pw.readPe(self.path("f"))), message, msg=arguments)


FAKE_ZIG = """#!%(python)s
import os, sys
lib = %(lib)r
if sys.argv[1] == "version":
    print("0.16.0")
    sys.exit(0)
target = sys.argv[sys.argv.index("-target") + 1]
arm = target.startswith("aarch64")
dll = "-shared" in sys.argv
out = sys.argv[sys.argv.index("-o") + 1]
fixture = [a for a in sys.argv if a.endswith(".c")][0]
stem = os.path.splitext(os.path.basename(fixture))[0]
cache = os.path.join(os.environ["ZIG_GLOBAL_CACHE_DIR"], "o", target + ("-dll" if dll else "-exe"))
os.makedirs(cache, exist_ok=True)
names = (["dllcrt2.obj"] if dll else ["crt2.obj"]) + %(archives)r
paths = []
for name in names:
    with open(os.path.join(cache, name), "w") as f:
        f.write("artifact %%s %%s %%s" %% (name, target, "dll" if dll else "exe"))
    paths.append(os.path.join(cache, name))
isystem = "-isystem %%s/include" %% lib
for d in (target, "any-windows-any"):
    isystem += " -isystem %%s/libc/include/%%s" %% (lib, d)
machine = %(machine)r or ("ARM64" if arm else "X64")
cpu, zigTarget = ("generic", "aarch64-unknown-windows-gnu") if arm else (%(x64Cpu)r, "x86_64-unknown-windows-gnu")
feature = "-tme" if arm else "-amx-transpose"
sys.stderr.write("%%s clang %%s --no-default-config -target %%s -g -gcodeview -DNDEBUG "
                 "-D__MSVCRT_VERSION__=0xE00 %%s -Xclang -target-cpu -Xclang %%s -Xclang -target-feature "
                 "-Xclang %%s -Xclang -target-feature -Xclang +sse2 -c -o /t/o.o\\n" %% (
                 sys.argv[0], fixture, zigTarget, isystem, cpu, feature))
link = "lld-link -lldmingw -ERRORLIMIT:0 -NOLOGO -DEBUG -PDB:p.pdb -PDBALTPATH:p.pdb -MLLVM:-float-abi=hard "
link += "-BASE:6442450944 -BUILD-ID:NO -MACHINE:%%s -DLL " %% machine if dll else \
    "-STACK:16777216 -BASE:5368709120 -BUILD-ID:NO -MACHINE:%%s " %% machine
link += "-BREPRO -OUT:%%s -IMPLIB:%%s.lib %%s/%%s.obj -ALTERNATENAME:__image_base__=__ImageBase %%s" %% (
    out, out, cache, stem, " ".join(paths))
sys.stderr.write(link + "\\n")
"""


class PipelineTest(TempCase):
    def setUp(self):
        super().setUp()
        self.lib = self.path("zig", "lib")
        write(os.path.join(self.lib, "libc", "include", "any-windows-any", "h.h"))
        os.makedirs(os.path.join(self.lib, "include"))
        for rel in ("../LICENSE", "libc/mingw/COPYING"):
            write(os.path.normpath(os.path.join(self.lib, rel)), "license " + rel)
        self.zig = self.path("zig", "zigfake")
        self.writeZig()
        self.engine = self.path("engine")
        os.makedirs(self.engine)
        for patcher in (mock.patch.object(pe, "verifyEngine", return_value=("aarch64-macos", "22.1.1", 0)),
                        mock.patch.object(pw, "verifyConfigs")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def writeZig(self, machine=None, x64Cpu="x86-64",
                 archives=("libmingw32.lib", "zigc.lib", "compiler_rt.lib", "ws2_32.lib")):
        write(self.zig, FAKE_ZIG % {"python": sys.executable, "lib": self.lib, "archives": list(archives),
                                    "machine": machine, "x64Cpu": x64Cpu})
        os.chmod(self.zig, 0o755)

    def receipt(self, out):
        return json.loads(read(os.path.join(out, "notices", pw.PROVENANCE)))

    def test_the_runtime_has_both_targets_each_with_two_configs_two_input_directories_shared_headers_and_a_receipt(self):
        out = self.path("rt", "windows")
        pw.prepareWindowsRuntime(self.zig, self.engine, out)
        self.assertEqual(sorted(os.listdir(out)), [
            "aarch64-windows-gnu", "aarch64-windows-gnu.cfg", "aarch64-windows-gnu.dll", "aarch64-windows-gnu.dll.cfg",
            "include", "notices", "x86_64-windows-gnu", "x86_64-windows-gnu.cfg", "x86_64-windows-gnu.dll",
            "x86_64-windows-gnu.dll.cfg"])
        for target, other in (("x86_64-windows-gnu", "aarch64"), ("aarch64-windows-gnu", "x86_64")):
            self.assertEqual(sorted(os.listdir(os.path.join(out, target))),
                             ["compiler_rt.lib", "crt2.obj", "libmingw32.lib", "ws2_32.lib", "zigc.lib"])
            self.assertEqual(sorted(os.listdir(os.path.join(out, target + ".dll")))[:2], ["compiler_rt.lib", "dllcrt2.obj"])
            self.assertEqual(read(os.path.join(out, target + ".dll", "libmingw32.lib")),
                             "artifact libmingw32.lib %s dll" % target)
            exe, dll = (read(os.path.join(out, target + suffix)) for suffix in (".cfg", ".dll.cfg"))
            self.assertIn("$-llibmingw32\n$-lzigc\n$-lcompiler_rt\n$-lws2_32\n", exe)
            self.assertIn("-Xlinker --stack=16777216\n", exe)
            self.assertIn("-Xlinker --image-base=0x140000000\n", exe)
            self.assertIn("-Xlinker --image-base=0x180000000\n", dll)
            self.assertNotIn(self.dir, exe + dll)
            self.assertNotIn(other, exe + dll)
        self.assertEqual(os.listdir(os.path.join(out, "include", "libc")), ["any-windows-any"])
        self.assertIn("-target x86_64-unknown-windows-gnu\n", read(os.path.join(out, "x86_64-windows-gnu.cfg")))
        self.assertIn("-target aarch64-unknown-windows-gnu\n", read(os.path.join(out, "aarch64-windows-gnu.cfg")))
        self.assertIn("-Xclang -target-cpu -Xclang generic\n", read(os.path.join(out, "aarch64-windows-gnu.dll.cfg")))
        self.assertIn("-Xlinker <CFGDIR>/aarch64-windows-gnu.dll/dllcrt2.obj\n", read(os.path.join(out, "aarch64-windows-gnu.dll.cfg")))
        self.assertNotIn("amx-transpose", read(os.path.join(out, "x86_64-windows-gnu.cfg")))
        self.assertNotIn("-tme", read(os.path.join(out, "aarch64-windows-gnu.cfg")))
        self.assertIn("-Xclang -target-feature -Xclang +sse2\n", read(os.path.join(out, "aarch64-windows-gnu.cfg")))
        self.assertEqual(read(os.path.join(out, "notices", "mingw-w64", "COPYING")), "license libc/mingw/COPYING")

    def test_the_receipt_names_the_unproved_modes_what_zig_did_not_carry_and_certifies_nothing(self):
        out = self.path("rt", "windows")
        pw.prepareWindowsRuntime(self.zig, self.engine, out)
        receipt = self.receipt(out)
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual((receipt["targets"], receipt["engineRelative"]),
                         (["x86_64-windows-gnu", "aarch64-windows-gnu"], "../.."))
        self.assertEqual(receipt["includeDirectories"], ["any-windows-any"])
        self.assertEqual(receipt["includeDirectoriesAbsentInZig"],
                         {"x86_64-windows-gnu": ["x86_64-windows-gnu"], "aarch64-windows-gnu": ["aarch64-windows-gnu"]})
        self.assertEqual([(r["target"], r["variant"]) for r in receipt["variants"]], [
            ("x86_64-windows-gnu", "exe"), ("x86_64-windows-gnu", "dll"),
            ("aarch64-windows-gnu", "exe"), ("aarch64-windows-gnu", "dll")])
        x64Exe, x64Dll, armExe, armDll = receipt["variants"]
        self.assertEqual([e["feature"] for e in x64Exe["cpuFeaturesNotCarried"]], ["-amx-transpose"])
        self.assertEqual([e["feature"] for e in armExe["cpuFeaturesNotCarried"]], ["-tme"])
        self.assertEqual((x64Exe["linkMachine"], armExe["linkMachine"]), ("X64", "ARM64"))
        self.assertEqual((armExe["zigTarget"], armExe["cpu"]), ("aarch64-unknown-windows-gnu", "generic"))
        self.assertEqual(armDll["zigLinkOptionsNotCarried"], ["-ALTERNATENAME:__image_base__=__ImageBase"])
        self.assertEqual(armExe["libraryTail"], ["libmingw32", "zigc", "compiler_rt", "ws2_32"])
        self.assertTrue(any("never run" in limit for limit in receipt["limits"]))
        self.assertFalse(any("aarch64" in limit and "not prepared" in limit for limit in receipt["limits"]))
        for record in receipt["variants"]:
            for item in record["inputs"]:
                self.assertEqual(item["sha256"], pe.sha256File(os.path.join(out, record["directory"], item["name"])))

    def test_one_target_alone_leaves_the_other_out_and_an_unknown_or_repeated_target_is_refused(self):
        out = self.path("rt", "windows")
        pw.prepareWindowsRuntime(self.zig, self.engine, out, ["aarch64-windows-gnu"])
        self.assertEqual(sorted(os.listdir(out)), ["aarch64-windows-gnu", "aarch64-windows-gnu.cfg",
                                                    "aarch64-windows-gnu.dll", "aarch64-windows-gnu.dll.cfg",
                                                    "include", "notices"])
        self.assertEqual(self.receipt(out)["targets"], ["aarch64-windows-gnu"])
        for bad in (["wasm32-wasi"], ["x86_64-windows-gnu", "x86_64-windows-gnu"]):
            with self.assertRaisesRegex(pe.EngineError, "unknown or duplicated"):
                pw.prepareWindowsRuntime(self.zig, self.engine, self.path("bad", "windows"), bad)

    def test_a_link_line_for_the_other_machine_or_a_compile_line_for_another_cpu_is_refused(self):
        self.writeZig(machine="X64")
        with self.assertRaisesRegex(pe.EngineError, "aarch64-windows-gnu exe link line has -MACHINE:X64, not ARM64"):
            pw.prepareWindowsRuntime(self.zig, self.engine, self.path("rt", "windows"), ["aarch64-windows-gnu"])
        self.writeZig(machine="ARM64")
        with self.assertRaisesRegex(pe.EngineError, "x86_64-windows-gnu exe link line has -MACHINE:ARM64, not X64"):
            pw.prepareWindowsRuntime(self.zig, self.engine, self.path("rt2", "windows"), ["x86_64-windows-gnu"])
        self.writeZig(x64Cpu="znver4")
        with self.assertRaisesRegex(pe.EngineError, "cpu znver4, not .* cpu x86-64"):
            pw.prepareWindowsRuntime(self.zig, self.engine, self.path("rt3", "windows"), ["x86_64-windows-gnu"])

    def test_an_existing_output_is_never_replaced_and_a_failure_leaves_nothing(self):
        os.makedirs(self.path("rt", "windows"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pw.prepareWindowsRuntime(self.zig, self.engine, self.path("rt", "windows"))
        os.remove(os.path.join(self.lib, "libc", "mingw", "COPYING"))
        with self.assertRaisesRegex(pe.EngineError, "COPYING is missing"):
            pw.prepareWindowsRuntime(self.zig, self.engine, self.path("out", "windows"))
        self.assertEqual(os.listdir(self.path("out")), [])

    def test_the_standalone_form_is_a_new_runtime_directory_holding_only_windows(self):
        output, records = pw.prepareRuntimeDirectory(self.zig, self.engine, self.path("fresh", "runtime"))
        self.assertEqual(os.listdir(output), ["windows"])
        self.assertEqual([(r["target"], r["variant"]) for r in records][:2], [("x86_64-windows-gnu", "exe"),
                                                                               ("x86_64-windows-gnu", "dll")])
        self.assertEqual(len(records), 4)
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            pw.prepareRuntimeDirectory(self.zig, self.engine, output)

    def test_a_missing_runtime_archive_fails_before_any_output(self):
        self.writeZig(archives=("libmingw32.lib", "zigc.lib", "ws2_32.lib"))
        with self.assertRaisesRegex(pe.EngineError, "no compiler_rt.lib"):
            pw.prepareWindowsRuntime(self.zig, self.engine, self.path("rt", "windows"))
        self.assertEqual(os.listdir(self.path("rt")), [])


class RealLinkTest(TempCase):
    """The consumer case on each prepared Windows target, through a real prepared runtime relocated to a path
    with a space: the `$-l` tail follows the caller's inputs, a compile has no library input, a duplicate
    caller library is harmless, a missing library is refused, and the PE files are what Zig made.
    Needs MANAGED_TOOLCHAIN_ENGINE=<prepared engine> and MANAGED_TOOLCHAIN_WINDOWS_RUNTIME=<runtime dir>."""
    ABSENT_MACROS = {pw.TARGET: ["__AMX_"], pw.ARM64_TARGET: ["__ARM_FEATURE_TME"]}

    def setUp(self):
        super().setUp()
        engine, runtime = os.environ.get("MANAGED_TOOLCHAIN_ENGINE"), os.environ.get("MANAGED_TOOLCHAIN_WINDOWS_RUNTIME")
        if not (engine and runtime and sys.platform == "darwin"):
            self.skipTest("needs MANAGED_TOOLCHAIN_ENGINE and MANAGED_TOOLCHAIN_WINDOWS_RUNTIME on the macOS producer host")
        self.root = self.path("a root")
        os.makedirs(self.root)
        for entry in os.listdir(engine):
            os.symlink(os.path.join(engine, entry), os.path.join(self.root, entry))
        shutil.copytree(runtime, os.path.join(self.root, "runtime"), symlinks=True)
        self.clang = os.path.join(self.root, "bin", "clang")
        self.runtime = os.path.join(self.root, "runtime", "windows")
        self.targets = [t for t in pw.TARGETS if os.path.isfile(os.path.join(self.runtime, pw.variantConfig(t, "exe")))]
        if not self.targets:
            self.fail("the runtime has no Windows target config")

    def run_(self, command):
        return subprocess.run(command, cwd=self.dir, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"})

    def invoke(self, config, *arguments):
        return self.run_([self.clang, "--config", os.path.join(self.runtime, config)] + list(arguments))

    def fixture(self, name):
        return os.path.join(pr.FIXTURES, name)

    def test_both_variants_compile_and_link_without_a_warning_and_with_the_callers_libraries_again(self):
        for target in self.targets:
            work = self.path("work-" + target)
            os.makedirs(work)
            outputs = pw.checkWindowsConfig(self.run_, self.clang, self.runtime, work, self.ABSENT_MACROS[target], target)
            self.assertEqual(sorted(outputs), ["dll", "dllLibs", "exe", "exeLibs"], msg=target)
            self.assertEqual(pw.readPe(outputs["exe"])["machine"], pw.TARGETS[target]["machine"], msg=target)
            self.assertEqual(pw.readPe(outputs["dll"])["machine"], pw.TARGETS[target]["machine"], msg=target)

    def test_a_compile_with_the_dollar_config_has_no_library_input(self):
        for target in self.targets:
            config = pw.variantConfig(target, "exe")
            done = self.invoke(config, "-O2", "-c", self.fixture("runtimeWindows.c"), "-o", "w.o", "-###")
            self.assertEqual(done.returncode, 0, msg=target)
            self.assertNotIn("libmingw32", done.stderr)
            done = self.invoke(config, "w.o", "-o", "w.exe", "-###")
            self.assertLess(done.stderr.index("w.o"), done.stderr.index("-llibmingw32"), msg=target)
            self.assertNotIn("/opt/homebrew", done.stderr)

    def test_a_library_the_runtime_does_not_ship_is_still_refused(self):
        for target in self.targets:
            config = pw.variantConfig(target, "exe")
            self.assertEqual(self.invoke(config, "-O2", "-c", self.fixture("runtimeWindows.c"), "-o", "w.o").returncode, 0)
            done = self.invoke(config, "w.o", "-lnosuch", "-o", "w.exe")
            self.assertNotEqual(done.returncode, 0, msg=target)
            self.assertIn("unable to find library -lnosuch", done.stderr)


if __name__ == "__main__":
    unittest.main()
