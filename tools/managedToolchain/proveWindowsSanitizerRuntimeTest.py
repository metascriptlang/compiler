import contextlib
import ctypes
import io
import os
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

import prepareCppRuntime as pc
import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSanitizerRuntime as san
import prepareWindowsSanitizerRuntimeTest as sanTest
import prepareWindowsSourceCppRuntime as pwc
import prepareWindowsSourceRuntime as pws
import proveWindowsSanitizerRuntime as prove

X64, ARM64 = pw.TARGET, pw.ARM64_TARGET
TARGETS = [X64, ARM64]
CLANG_VERSION = "clang version 23.1.0"
BITCODE = b"BC\xc0\xde rest"
OBJECT = b"\x64\x86 object"
LINKED = b"MZ linked"


def done(returncode=0, stdout="", stderr=""):
    return mock.Mock(returncode=returncode, stdout=stdout, stderr=stderr)


def tagOf(path):
    """(proof, mask, mode) of a file the fake toolchain was asked to write: tags are `proof-mask-mode` with `+` for `,`."""
    proof, mask, mode = os.path.splitext(os.path.basename(path))[0].split("-")
    return proof, mask.replace("+", ","), mode


def linkedInfo(target, proof, mask, **changes):
    """What pw.readPe reads from a good linked file of the proof under mask."""
    spec = prove.PROOFS.get(proof, prove.HOST)
    imports = {"KERNEL32.dll": [], "api-ms-win-crt-runtime-l1-1-0.dll": [], "api-ms-win-core-synch-l1-2-0.dll": []}
    if "address" in prove.sanitizers(mask):
        imports[san.ASAN_DLL_NAME % san.architecture(target)] = []
    info = {"machine": pw.TARGETS[target]["machine"], "subsystem": pw.SUBSYSTEM_CONSOLE,
            "characteristics": 0x2022 if spec["variant"] == "dll" else 0x22,
            "imports": imports, "exports": [spec["export"]] if "export" in spec else []}
    info.update(changes)
    return info


def planText(stage, target, mask, proof, **changes):
    """A `-###` text of the good plain link of the proof: the resource directory searched, the startup object, and with
    address the import library before it and the whole tail after."""
    library = os.path.join(stage, "lib", "clang", "23", "lib", "windows")
    names = {spec["role"]: os.path.join(library, spec["name"]) for spec in san.assetSpecs(target)}
    startup = os.path.join(stage, "runtime", "windows", target, "crt2.o")
    address = "address" in prove.sanitizers(mask)
    words = ["ld.lld"] + ([names["asan-import"]] if address else []) + [startup, "-L" + library, "-lmingw32"]
    words += [names["asan-import"], names["asan-thunk"], "--require-defined", prove.INTERCEPTOR, "--whole-archive",
              names["asan-thunk"], "--no-whole-archive"] if address else []
    words = changes.get("words", words)
    return CLANG_VERSION + "\n" + " ".join('"%s"' % w for w in words) + "\n"


class FakeToolchain:
    """A `run` that writes what each compile and link command would: an object (bitcode under an LTO flag), a linked file,
    the nm listing of a plain object and the plan of a link; `fail` and `warn` map a command to a refusal."""

    def __init__(self, stage, target):
        self.stage, self.target, self.commands = stage, target, []
        self.fail = lambda command: None
        self.warn = lambda command: ""
        self.plan = lambda command, text: text
        self.listing = lambda proof, mask: "".join("         U %s%s\n" % (prove.ENTRIES[s], "x") for s in proof["checks"]
                                                   if s in prove.sanitizers(mask)) + (
            "U __ubsan_handle_dynamic_type_cache_miss_abort\n"
            if proof.get("vptr", False) and "undefined" in prove.sanitizers(mask) else "")

    def __call__(self, command):
        self.commands.append(command)
        failed = self.fail(command)
        if failed:
            return done(1, stderr=failed)
        warned = self.warn(command)
        if os.path.basename(command[0]).startswith("llvm-nm"):
            proof, mask, _ = tagOf(command[-1])
            return done(stdout=self.listing(prove.PROOFS[proof], mask), stderr=warned)
        if "-###" in command:
            proof, mask, _ = tagOf(command[command.index("-###") + 1])
            return done(stderr=self.plan(command, planText(self.stage, self.target, mask, proof)) + warned)
        output = command[command.index("-o") + 1]
        os.makedirs(os.path.dirname(output), exist_ok=True)
        compiled = "-c" in command
        lto = any(flag.startswith("-flto") for flag in command)
        sanTest.write(output, (BITCODE if lto else OBJECT) if compiled else LINKED)
        return done(stderr=warned)


def outcome(proof, run, **changes):
    """The completed process of a good execution of run: its marker for a clean one, else exit 1 and the report of its
    sanitizer at the fixture's line (a heap one with the symbolizer evidence), each overridable by returncode, stdout and
    stderr."""
    kind = run["report"] if run["sanitizer"] else "clean"
    where = "C:\\work dir\\%s:%d:5" % (proof["fixture"], prove.siteLine(proof, run) if run["sanitizer"] else 0)
    values = {
        "clean": (0, run.get("marker"), ""),
        "signed": (1, "", "%s: runtime error: signed integer overflow: 2147483647 + 1 cannot be represented in type 'int'\n"
                   % where),
        "vptr": (1, "", "%s: runtime error: member call on address 0x1 which does not point to an object of type "
                 "'Derived'\n" % where),
        "heap": (1, "", "Using llvm-symbolizer at user-specified path: C:\\stage\\bin\\llvm-symbolizer.exe\n==1==ERROR: "
                 "AddressSanitizer: heap-buffer-overflow on address 0x60 at pc 0x1\nWRITE of size 4 at 0x60\n    #0 0x1 in "
                 "main %s\n    #1 0x2 in __scrt_common_main_seh\n" % where)}[kind]
    return done(changes.get("returncode", values[0]), changes.get("stdout", values[1]), changes.get("stderr", values[2]))


class Programs:
    """A `runProgram` that answers each execution with its good outcome, after `change` has seen it, and records the calls."""

    def __init__(self):
        self.calls = []
        self.change = lambda command, result: result

    def __call__(self, command, environment, directory):
        self.calls.append((command, environment, directory))
        if os.path.basename(command[0]).startswith("host-"):
            proof, step = prove.PROOFS[tagOf(command[1])[0]], int(command[3])
        else:
            proof, step = prove.PROOFS[tagOf(command[0])[0]], None
        run = next(r for r in proof["runs"] if r["step"] == step)
        return self.change(command, outcome(proof, run))


class StageCase(sanTest.TempCase):
    """A stage with the three engine tools, a fake toolchain per target and every file reader patched to what the fake
    toolchain's tags describe."""

    def setUp(self):
        super().setUp()
        self.stage = self.path("stage")
        for name in ("clang", "clang++", "llvm-nm"):
            sanTest.write(os.path.join(self.stage, "bin", name))
        self.work = self.path("work")
        os.makedirs(self.work)
        self.infos = {}

        def readPe(path):
            proof, mask, _ = tagOf(path)
            return self.infos.get(path) or linkedInfo(self.target, proof, mask)

        self.target = X64
        for patch in (mock.patch.object(pw, "readPe", side_effect=readPe),
                      mock.patch.object(prove, "selectionProblem", return_value=None)):
            patch.start()
            self.addCleanup(patch.stop)

    def toolchain(self, target=X64):
        self.target = target
        return FakeToolchain(self.stage, target)

    def check(self, run, target=X64):
        self.target = target
        return prove.checkTarget(run, self.stage, self.work, target)


class StepsTest(StageCase):
    def steps(self, target):
        return prove.proofSteps(self.stage, self.work, target)

    def test_x64_proves_address_undefined_and_both_and_arm64_undefined_alone(self):
        self.assertEqual(prove.masks(X64), ["address", "undefined", "address,undefined"])
        self.assertEqual(prove.masks(ARM64), ["undefined"])

    def test_each_proof_runs_only_under_the_masks_whose_sanitizer_it_exercises(self):
        _, outputs, _ = self.steps(X64)
        proofs = lambda mask: sorted({name for name, m, _ in outputs if m == mask})
        self.assertEqual(proofs("address"), ["clean", "cppdll", "dll", "heap"])
        self.assertEqual(proofs("undefined"), ["clean", "cppdll", "dll", "signed", "vptr"])
        self.assertEqual(proofs("address,undefined"), ["clean", "cppdll", "dll", "heap", "signed", "vptr"])
        _, arm, _ = self.steps(ARM64)
        self.assertEqual({m for _, m, _ in arm}, {"undefined"})
        self.assertEqual(sorted({name for name, _, _ in arm}), ["clean", "cppdll", "dll", "signed", "vptr"])

    def test_every_proof_is_compiled_and_linked_plain_thin_and_full_and_its_plain_link_is_planned_not_run(self):
        steps, outputs, plans = self.steps(X64)
        self.assertEqual({mode for _, _, mode in outputs}, {"plain", "thin", "full"})
        self.assertEqual(len(steps), 2 * len(outputs))
        self.assertEqual(len(plans), len(outputs) // 3)
        for name, command, (proof, mask) in plans:
            self.assertIn("-###", command)
            self.assertEqual(command[command.index("-###") + 1], outputs[(proof, mask, "plain")][0])
        for name, command in steps:
            lto = {"plain": [], "thin": ["-flto=thin"], "full": ["-flto=full"]}[name.split()[-2]]
            self.assertEqual([f for f in command if f.startswith("-flto")], lto, name)

    def test_the_sanitizer_flag_follows_the_configs_and_nothing_else_names_a_sanitizer_file_or_library(self):
        steps, _, plans = self.steps(X64)
        for name, command in steps + [(n, c) for n, c, _ in plans]:
            configs = [i for i, w in enumerate(command) if w.startswith("--config=")]
            flag = [i for i, w in enumerate(command) if w.startswith("-fsanitize=")]
            self.assertEqual(len(flag), 1, name)
            self.assertLess(max(configs), flag[0], name)
            self.assertEqual(command[1], "--no-default-config", name)
            for word in command[1:]:
                self.assertFalse(word.startswith(("-l", "-nostdlib", "-nodefaultlibs", "-Wl,", "-Xlinker"))
                                 or word.endswith((".a", ".lib")) or "whole-archive" in word
                                 or "require-defined" in word, "%s: %s" % (name, word))

    def test_c_proofs_use_the_base_config_and_c_plus_plus_proofs_the_pair_with_the_cxx_config_first(self):
        steps, _, _ = self.steps(X64)
        for name, command in steps:
            configs = [w for w in command if w.startswith("--config=")]
            variant = "dll" if name.startswith(("dll ", "cppdll ")) else "exe"
            base = pwc.baseConfigPath(X64, variant)
            if name.startswith(("vptr ", "cppdll ")):
                self.assertEqual([os.path.basename(c) for c in configs], [
                    os.path.basename(pwc.configPath(X64, variant)), os.path.basename(base)], name)
                self.assertTrue(os.path.basename(command[0]).startswith("clang++"))
                if name.endswith("compile"):
                    self.assertIn(pwc.CXX_STANDARD, command)
            else:
                self.assertEqual([os.path.basename(c) for c in configs], [os.path.basename(base)], name)
                self.assertFalse(os.path.basename(command[0]).startswith("clang++"))
                self.assertNotIn(".cxx", " ".join(command))

    def test_the_fatal_switch_is_explicit_on_compile_and_link_of_the_failing_proofs_under_undefined_only(self):
        steps, _, plans = self.steps(X64)
        for name, command in steps + [(n, c) for n, c, _ in plans]:
            proof, mask = name.split()[0], name.split()[1]
            expected = prove.PROOFS[proof]["fatal"] and "undefined" in prove.sanitizers(mask)
            selected = "undefined,vptr" if proof in ("vptr", "cppdll") else "undefined"
            flags = [word for word in command if word.startswith("-fno-sanitize-recover=")]
            self.assertEqual(flags, ["-fno-sanitize-recover=" + selected] if expected else [], name)

    def test_vptr_proofs_enable_vptr_and_its_fatal_handler_explicitly(self):
        for target in TARGETS:
            steps, _, _ = self.steps(target)
            for name, command in steps:
                proof, mask = name.split()[:2]
                if proof in ("vptr", "cppdll") and "undefined" in mask.split(","):
                    self.assertIn("-fsanitize=" + mask + ",vptr", command, name)
                    self.assertIn("-fno-sanitize-recover=undefined,vptr", command, name)
                else:
                    self.assertIn("-fsanitize=" + mask, command, name)

    def test_compiles_carry_debug_info_and_optimization_and_dll_links_say_shared(self):
        steps, _, _ = self.steps(ARM64)
        for name, command in steps:
            if name.endswith("compile"):
                self.assertIn("-g", command)
                self.assertIn("-O2", command)
                self.assertIn("-c", command)
            elif name.startswith(("dll ", "cppdll ")):
                self.assertIn("-shared", command)
            else:
                self.assertNotIn("-shared", command)

    def test_every_command_names_this_targets_configs_and_files_stay_in_the_work_directory(self):
        steps, outputs, _ = self.steps(ARM64)
        for _, command in steps:
            self.assertTrue(all(ARM64 in w for w in command if w.startswith("--config=")))
        for obj, linked in outputs.values():
            self.assertEqual(os.path.dirname(obj), self.work)
            self.assertEqual(os.path.dirname(linked), self.work)

    def test_the_fixtures_exist_and_each_proof_has_a_distinct_one(self):
        fixtures = [p["fixture"] for p in prove.PROOFS.values()]
        self.assertEqual(len(set(fixtures)), len(fixtures))
        for fixture in fixtures:
            self.assertTrue(fixture.startswith("windowsSanitizer"))
            self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, fixture)), fixture)


class ReferencesTest(unittest.TestCase):
    def test_each_sanitizer_the_fixture_exercises_must_have_its_entry_point_referenced(self):
        both = "         U __asan_report_store4\n         U __ubsan_handle_add_overflow_abort\n"
        self.assertIsNone(prove.referencesProblem(both, prove.PROOFS["clean"], "address,undefined"))
        self.assertIn("__asan_", prove.referencesProblem("         U __ubsan_handle_x\n", prove.PROOFS["clean"], "address"))
        self.assertIn("__ubsan_handle_", prove.referencesProblem("         U __asan_init\n", prove.PROOFS["signed"],
                                                                 "undefined"))

    def test_a_generic_undefined_handler_does_not_prove_vptr_instrumentation(self):
        for name in ("vptr", "cppdll"):
            proof = prove.PROOFS[name]
            generic = "U __ubsan_handle_type_mismatch_v1\n"
            self.assertIsNotNone(prove.referencesProblem(generic, proof, "undefined"))
            precise = generic + "U __ubsan_handle_dynamic_type_cache_miss_abort\n"
            self.assertIsNone(prove.referencesProblem(precise, proof, "undefined"))

    def test_a_defined_symbol_or_a_sanitizer_the_mask_lacks_does_not_count_or_matter(self):
        self.assertIsNotNone(prove.referencesProblem("0000 T __asan_init\n", prove.PROOFS["heap"], "address"))
        self.assertIsNone(prove.referencesProblem("         U __asan_init\n", prove.PROOFS["heap"], "address,undefined"))
        self.assertIsNone(prove.referencesProblem("", prove.PROOFS["heap"], "undefined"))


class PlanTest(unittest.TestCase):
    stage = os.path.join(os.sep, "stage")

    def problem(self, mask, target=X64, **changes):
        return prove.planProblem(planText(self.stage, target, mask, "clean", **changes), self.stage, target, mask)

    def edit(self, mask, change, target=X64):
        words = [w.strip('"') for w in planText(self.stage, target, mask, "clean").splitlines()[1].split('" "')]
        return self.problem(mask, target, words=change(words))

    def test_the_drivers_address_choice_and_the_absence_of_any_on_undefined_are_accepted(self):
        for mask in ("address", "address,undefined", "undefined"):
            self.assertIsNone(self.problem(mask), mask)
        self.assertIsNone(self.problem("undefined", ARM64))

    def test_an_asan_file_without_address_and_a_ubsan_archive_under_any_mask_are_refused(self):
        library = os.path.join(self.stage, "lib", "clang", "23", "lib", "windows")
        asan = os.path.join(library, "libclang_rt.asan_dynamic_runtime_thunk-x86_64.a")
        ubsan = os.path.join(library, "libclang_rt.ubsan_standalone-x86_64.a")
        self.assertIn("without address", self.edit("undefined", lambda w: w + [asan]))
        for mask in ("undefined", "address"):
            self.assertIn("never from a driver tail", self.edit(mask, lambda w: w + [ubsan]))

    def test_the_resource_directory_must_be_searched_and_a_version_named(self):
        self.assertIn("does not search the resource directory", self.edit("undefined", lambda w: [
            x for x in w if not x.startswith("-L")]))
        self.assertIn("no compiler version", prove.planProblem("\"ld.lld\" \"-L/x\"\n", self.stage, X64, "undefined"))
        self.assertIn("0 ld.lld lines", prove.planProblem(CLANG_VERSION + "\n", self.stage, X64, "undefined"))

    def test_the_import_library_must_come_before_the_startup_object_and_again_in_the_tail(self):
        self.assertIn("twice each", self.edit("address", lambda w: w[:1] + w[2:]))
        self.assertIn("does not come before the startup object", self.edit("address", lambda w: w[:1] + [w[2], w[1]] + w[3:]))

    def test_the_tail_must_be_import_thunk_require_defined_then_the_thunk_inside_whole_archive(self):
        self.assertIn("does not require", self.edit("address", lambda w: [x for x in w if x != prove.INTERCEPTOR]))
        self.assertIn("not import, thunk", self.edit("address", lambda w: [x for x in w if x != "--whole-archive"]))
        self.assertIn("not import, thunk", self.edit("address", lambda w: [x for x in w if x != "--no-whole-archive"]))

    def test_a_thunk_or_import_from_another_directory_is_not_the_resource_directorys(self):
        self.assertIn("twice each", self.edit("address", lambda w: [
            x.replace(os.path.join("lib", "clang"), os.path.join("lib", "other")) if "thunk" in x else x for x in w]))


class PeTest(unittest.TestCase):
    def problem(self, proof, mask, target=X64, **changes):
        return prove.peProblem(prove.PROOFS[proof], mask, linkedInfo(target, proof, mask, **changes), target)

    def test_every_proof_under_every_mask_of_each_target_is_accepted_when_it_is_what_the_driver_makes(self):
        for target in TARGETS:
            for mask in prove.masks(target):
                for proof in prove.PROOFS:
                    if prove.applies(prove.PROOFS[proof], mask):
                        self.assertIsNone(self.problem(proof, mask, target), (target, proof, mask))

    def test_the_machine_the_dll_flag_the_subsystem_and_the_own_export_are_checked(self):
        self.assertIn("machine", self.problem("clean", "undefined", machine=pw.TARGETS[ARM64]["machine"]))
        self.assertIn("machine", self.problem("clean", "undefined", ARM64, machine=pw.TARGETS[X64]["machine"]))
        self.assertIn("characteristics", self.problem("clean", "undefined", characteristics=0x2022))
        self.assertIn("characteristics", self.problem("dll", "undefined", characteristics=0x22))
        self.assertIn("subsystem", self.problem("clean", "undefined", subsystem=2))
        self.assertIn("lack sanitizerCProbe", self.problem("dll", "undefined", exports=["other"]))
        self.assertIn("lack sanitizerCppProbe", self.problem("cppdll", "undefined", exports=[]))

    def test_the_asan_dll_is_imported_exactly_when_address_is_on(self):
        dll = san.ASAN_DLL_NAME % "x86_64"
        self.assertIn("lack", self.problem("clean", "address", imports={"KERNEL32.dll": [], "api-ms-win-crt-x.dll": []}))
        imports = {"KERNEL32.dll": [], "api-ms-win-crt-x.dll": [], dll.upper(): []}
        self.assertIn("does not use", self.problem("clean", "undefined", imports=imports))
        self.assertIsNone(self.problem("clean", "address,undefined", imports=imports))

    def test_other_runtime_imports_and_a_missing_ucrt_or_kernel32_are_refused(self):
        base = {"KERNEL32.dll": [], "api-ms-win-crt-x.dll": []}
        for other in ("libc++.dll", "libunwind.dll", "libwinpthread-1.dll", "msvcrt.dll", "libclang_rt.ubsan.dll"):
            self.assertIn("unexpected", self.problem("clean", "undefined", imports=dict(base, **{other: []})), other)
        self.assertIn("not system DLLs", self.problem("clean", "undefined", imports={"KERNEL32.dll": []}))
        self.assertIn("not system DLLs", self.problem("clean", "undefined", imports={"api-ms-win-crt-x.dll": []}))


class CheckTargetTest(StageCase):
    def test_a_toolchain_that_makes_the_expected_files_is_accepted_for_both_targets(self):
        for target in TARGETS:
            run = self.toolchain(target)
            outputs = self.check(run, target)
            keys = {key for key in prove.proofSteps(self.stage, self.work, target)[1]}
            self.assertEqual(set(outputs), keys)
            self.assertTrue(all(os.path.isfile(path) for path in outputs.values()))
            self.assertEqual(sum(1 for c in run.commands if "-###" in c), len(keys) // 3)
            self.assertEqual(sum(1 for c in run.commands if os.path.basename(c[0]).startswith("llvm-nm")), len(keys) // 3)

    def test_a_nonzero_exit_names_the_target_and_step(self):
        run = self.toolchain()
        run.fail = lambda command: "boom" if "-c" in command and "signed" in command[-1] else None
        with self.assertRaisesRegex(pe.EngineError, r"%s signed undefined plain compile failed \(1\).*boom" % X64):
            self.check(run)

    def test_a_warning_on_stderr_of_a_compile_a_link_or_nm_is_an_error(self):
        for needle in ("-c", "-shared", "--undefined-only"):
            run = self.toolchain()
            run.warn = lambda command, needle=needle: "warning: x" if needle in command else ""
            with self.subTest(needle), self.assertRaisesRegex(pe.EngineError, "warned: warning: x"):
                self.check(run)

    def test_a_plan_does_not_need_to_be_silent_but_must_exit_zero(self):
        run = self.toolchain()
        run.fail = lambda command: "plan failed" if "-###" in command else None
        with self.assertRaisesRegex(pe.EngineError, "plan failed"):
            self.check(run)

    def test_an_lto_object_that_is_not_bitcode_is_refused(self):
        run = self.toolchain()
        real = run.__call__

        def flat(command):
            result = real(command)
            if "-c" in command and "-flto=thin" in command:
                sanTest.write(command[command.index("-o") + 1], OBJECT)
            return result

        with self.assertRaisesRegex(pe.EngineError, "is not LTO bitcode"):
            self.check(flat)

    def test_a_plain_object_without_the_sanitizers_entry_points_is_refused_by_name(self):
        run = self.toolchain()
        run.listing = lambda proof, mask: "         U puts\n"
        with self.assertRaisesRegex(pe.EngineError, r"clean address plain: the object references no __asan_\* symbol"):
            self.check(run)

    def test_a_plan_with_a_manual_or_missing_sanitizer_tail_is_refused_by_name(self):
        run = self.toolchain()
        run.plan = lambda command, text: text.replace('"--whole-archive" ', "")
        with self.assertRaisesRegex(pe.EngineError, r"%s clean address plan: the ASan tail" % X64):
            self.check(run)

    def test_the_selection_of_the_c_and_c_plus_plus_plans_is_reused_with_the_right_arguments(self):
        run = self.toolchain()
        with mock.patch.object(prove, "selectionProblem", return_value="the startup object is wrong"):
            with self.assertRaisesRegex(pe.EngineError, "plan: the startup object is wrong"):
                self.check(run)

    def test_a_wrong_machine_dll_kind_or_import_in_a_linked_file_is_refused_with_its_key(self):
        run = self.toolchain()
        wrong = os.path.join(self.work, "dll-undefined-thin.dll")
        self.infos[wrong] = linkedInfo(X64, "dll", "undefined", machine=pw.TARGETS[ARM64]["machine"])
        with self.assertRaisesRegex(pe.EngineError, r"%s dll undefined thin: machine" % X64):
            self.check(run)
        self.infos[wrong] = linkedInfo(X64, "dll", "undefined", imports={"KERNEL32.dll": [], "msvcrt.dll": []})
        with self.assertRaisesRegex(pe.EngineError, "dll undefined thin: imports"):
            self.check(run)


class SelectionDispatchTest(unittest.TestCase):
    def test_c_goes_to_the_source_c_checker_and_c_plus_plus_to_the_pair_checker(self):
        with mock.patch.object(pws, "selectionProblem", return_value="c") as c, \
                mock.patch.object(pwc, "selectionProblem", return_value="cxx") as cxx:
            self.assertEqual(prove.selectionProblem("p", "/s", X64, prove.PROOFS["dll"]), "c")
            c.assert_called_once_with("p", os.path.join("/s", "runtime", "windows"), X64, "dll")
            self.assertEqual(prove.selectionProblem("p", "/s", X64, prove.PROOFS["vptr"]), "cxx")
            cxx.assert_called_once_with("p", os.path.join("/s", "runtime"), X64, "exe", "cxx")


class ControlTest(StageCase):
    def test_the_control_is_the_c_fixture_through_the_base_config_of_every_target_and_variant_in_its_own_directory(self):
        calls = []
        with mock.patch.object(pwc, "controlResults", side_effect=lambda run, stage, work, target, variant: (
                calls.append((work, target, variant)) or (["$ROOT/a"], b"o", b"x"))):
            before = prove.checkControls(None, self.stage, self.work, TARGETS, "control-before")
            after = prove.checkControls(None, self.stage, self.work, TARGETS, "control-after")
        self.assertEqual(sorted(before), sorted((t, v) for t in TARGETS for v in pws.SOURCE_VARIANTS))
        self.assertEqual({w for w, _, _ in calls}, {os.path.join(self.work, "control-before"),
                                                    os.path.join(self.work, "control-after")})
        self.assertIsNone(prove.controlProblem(before, after))

    def test_a_changed_include_list_object_or_linked_file_is_refused_by_what_changed(self):
        before = {(X64, "exe"): (["$ROOT/a"], b"o", b"x")}
        for index, what in enumerate(("include list", "object", "linked file")):
            changed = list(before[(X64, "exe")])
            changed[index] = ["$ROOT/b"] if index == 0 else b"y"
            self.assertRegex(prove.controlProblem(before, {(X64, "exe"): tuple(changed)}), what)


class InputsCase(sanTest.RuntimeCase):
    def setUp(self):
        super().setUp()
        for name in ("clang", "clang++", "llvm-nm"):
            sanTest.write(os.path.join(self.engine, "bin", name))
        self.merged()
        patches = [mock.patch.object(pr, "engineMajor", return_value=("linux", "23.1.0", "23")),
                   mock.patch.object(pwc, "baseReceipt", return_value=(sanTest.BASE_RECEIPT, "bd")),
                   mock.patch.object(pwc, "receiptProblem", return_value=None),
                   mock.patch.object(san, "synchronizationProblem", return_value=None)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)


class InputsTest(InputsCase):
    def test_a_runtime_of_the_engines_cohort_with_all_three_receipts_is_accepted(self):
        receipt, major = prove.checkInputs(self.engine, self.runtime)
        self.assertEqual((receipt["kind"], major), (san.RECEIPT_KIND, "23"))

    def test_a_changed_listed_file_a_missing_receipt_and_an_unlisted_owned_file_are_refused(self):
        sanTest.write(os.path.join(self.runtime, "windows-sanitizers", "resource", "lib", "windows", "extra.a"))
        with self.assertRaisesRegex(pe.EngineError, "present or listed but not both"):
            prove.checkInputs(self.engine, self.runtime)
        os.remove(os.path.join(self.runtime, *san.PROVENANCE.split("/")))
        with self.assertRaisesRegex(pe.EngineError, "is missing"):
            prove.checkInputs(self.engine, self.runtime)

    def test_an_engine_or_receipt_of_another_version_or_cohort_is_refused(self):
        with mock.patch.object(pr, "engineMajor", return_value=("linux", "23.2.0", "23")):
            with self.assertRaisesRegex(pe.EngineError, "not the engine's LLVM 23.2.0"):
                prove.checkInputs(self.engine, self.runtime)

    def test_the_cxx_and_c_receipts_and_the_synchronization_archives_are_still_checked(self):
        with mock.patch.object(pwc, "receiptProblem", return_value="cxx files differ"):
            with self.assertRaisesRegex(pe.EngineError, "cxx files differ"):
                prove.checkInputs(self.engine, self.runtime)
        with mock.patch.object(san, "synchronizationProblem", return_value="no libsynchronization.a"):
            with self.assertRaisesRegex(pe.EngineError, "no libsynchronization.a"):
                prove.checkInputs(self.engine, self.runtime)
        other = dict(sanTest.BASE_RECEIPT, sources={"llvm-project": {"rev": "0" * 40, "version": "23.1.0", "major": "23"}})
        with mock.patch.object(pwc, "baseReceipt", return_value=(other, "bd")):
            with self.assertRaisesRegex(pe.EngineError, "built from llvm-project"):
                prove.checkInputs(self.engine, self.runtime)


def copyStage(engine, windows, root, major):
    """pws.stageTree without the builtins installation: the engine copy and runtime/windows beside it."""
    shutil.copytree(engine, root, symlinks=True)
    shutil.copytree(windows, os.path.join(root, "runtime", "windows"), symlinks=True)


class StageRootTest(InputsCase):
    def stage(self):
        root = self.path("relocated tree")
        before = (pc.treeDigest(self.engine), pc.treeDigest(self.runtime))
        with mock.patch.object(pws, "stageTree", side_effect=copyStage):
            prove.stageRoot(self.engine, self.runtime, root, "23")
        return root, before

    def test_the_root_notices_receipts_and_resource_files_are_copied_beside_the_relocated_windows_directory(self):
        root, _ = self.stage()
        copy = os.path.join(root, "runtime")
        for relative in (san.PROVENANCE, pwc.PROVENANCE, san.NOTICE, "windows-sanitizers/resource/lib/windows/" + san.assetSpecs(
                X64)[0]["name"], "windows/x86_64-windows-gnu/bin/" + san.ASAN_DLL_NAME % "x86_64"):
            self.assertTrue(os.path.isfile(os.path.join(copy, *relative.split("/"))), relative)
        self.assertIsNone(san.receiptProblem(pwc.readJson(copy, san.PROVENANCE)[0], copy, copy))

    def test_the_real_install_puts_the_archives_in_the_copys_resource_directory_and_leaves_every_original_alone(self):
        root, before = self.stage()
        installed = san.installResource(os.path.join(root, "runtime"), os.path.join(root, "lib", "clang", "23"))
        self.assertEqual(len(installed), sum(1 for t in TARGETS for s in san.assetSpecs(t) if s["role"] != "asan-dll"))
        self.assertTrue(os.path.isfile(os.path.join(root, "lib", "clang", "23", "lib", "windows", san.assetSpecs(X64)[0]["name"])))
        self.assertFalse(os.path.exists(os.path.join(self.engine, "lib")))
        self.assertEqual((pc.treeDigest(self.engine), pc.treeDigest(self.runtime)), before)

    def test_a_link_among_the_files_it_copies_is_refused(self):
        receipt = os.path.join(self.runtime, *san.PROVENANCE.split("/"))
        os.replace(receipt, self.path("moved.json"))
        self.symlink(self.path("moved.json"), receipt)
        with mock.patch.object(pws, "stageTree", side_effect=copyStage):
            with self.assertRaisesRegex(pe.EngineError, "is a link"):
                prove.stageRoot(self.engine, self.runtime, self.path("relocated tree"), "23")


class ProveTest(InputsCase):
    def setUp(self):
        super().setUp()
        self.events = []
        self.tmp = self.path("tmp")
        os.makedirs(self.tmp)
        self.toolchains = {}
        self.realInstall = san.installResource

        def sandbox(engine, work, secrets):
            return self.dispatch(work), "none"

        def install(runtime, resource):
            self.events.append("install")
            return self.realInstall(runtime, resource)

        def readPe(path):
            proof, mask, _ = tagOf(path)
            return linkedInfo(self.targetOf(path), proof, mask)

        def controls(run, stage, work, target, variant):
            self.events.append("control after" if "install" in self.events else "control before")
            return ["$ROOT/a"], b"o", b"x"

        sanTest.write(os.path.join(self.engine, "bin", prove.SYMBOLIZER))
        self.programs = Programs()
        self.native = (0, pw.TARGETS[X64]["machine"])
        for patch in (mock.patch.object(pws, "stageTree", side_effect=copyStage),
                      mock.patch.object(prove, "runProgram", side_effect=self.programs),
                      mock.patch.object(prove, "hostMachines", side_effect=lambda *args: self.native),
                      mock.patch.object(pws, "selectionProblem", return_value=None),
                      mock.patch.object(prove, "sandboxRun", side_effect=sandbox),
                      mock.patch.object(san, "installResource", side_effect=install),
                      mock.patch.object(pw, "readPe", side_effect=readPe),
                      mock.patch.object(pwc, "controlResults", side_effect=controls),
                      mock.patch.object(prove, "selectionProblem", return_value=None),
                      mock.patch.object(tempfile, "tempdir", self.tmp)):
            patch.start()
            self.addCleanup(patch.stop)

    def targetOf(self, path):
        return ARM64 if "san-" + ARM64 in path else X64

    def dispatch(self, work):
        def run(command):
            target = ARM64 if any(ARM64 in w for w in command) else X64
            stage = os.path.join(work, "relocated tree")
            return FakeToolchain(stage, target)(command)
        return run

    def prove(self, **options):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            prove.prove(options.get("engine", self.engine), self.runtime, options.get("denied", []), options.get("targets"),
                        options.get("execute", False))
        return out.getvalue()

    def proveExecuting(self, **options):
        with mock.patch.object(prove.sys, "platform", "win32"):
            return self.prove(execute=True, **options)

    def test_a_clean_proof_prints_what_was_inspected_and_that_nothing_was_run_and_cleans_up(self):
        engineBefore, runtimeBefore = pc.treeDigest(self.engine), pc.treeDigest(self.runtime)
        output = self.prove()
        self.assertIn("compile/link inspection only; no execution/runtime diagnostic proven", output)
        self.assertIn("sandbox=none", output)
        for target in TARGETS:
            self.assertRegex(output, "%s: \\d+ linked files inspected" % target)
        self.assertEqual((pc.treeDigest(self.engine), pc.treeDigest(self.runtime)), (engineBefore, runtimeBefore))
        self.assertEqual(os.listdir(self.tmp), [])

    def test_the_install_happens_once_between_the_two_controls_which_cover_every_target_and_variant(self):
        self.prove()
        self.assertEqual(self.events.count("install"), 1)
        self.assertEqual(self.events[:1], ["control before"])
        count = len(TARGETS) * len(pws.SOURCE_VARIANTS)
        self.assertEqual(self.events.count("control before") + self.events.count("control after"), 2 * count)

    def test_one_target_can_be_proven_alone_and_an_unknown_or_absent_one_is_refused_before_staging(self):
        output = self.prove(targets=[ARM64])
        self.assertIn(ARM64 + ":", output)
        self.assertNotIn(X64 + ":", output)
        with self.assertRaisesRegex(pe.EngineError, "unknown or duplicated"):
            self.prove(targets=["x86_64-linux-gnu"])
        self.assertEqual(os.listdir(self.tmp), [])

    def test_default_selection_proves_only_the_targets_in_a_single_cpu_receipt(self):
        receipt, major = prove.checkInputs(self.engine, self.runtime)
        for target in TARGETS:
            with mock.patch.object(prove, "checkInputs", return_value=(dict(receipt, targets=[target]), major)):
                output = self.prove()
            self.assertIn(target + ":", output)
            for other in set(TARGETS) - {target}:
                self.assertNotIn(other + ":", output)
            self.assertEqual(os.listdir(self.tmp), [])

    def test_deny_is_refused_off_macos_before_any_work(self):
        with mock.patch.object(prove.sys, "platform", "linux"):
            with self.assertRaisesRegex(pe.EngineError, "enforced by the macOS sandbox only"):
                self.prove(denied=[self.path("secret")])
        self.assertEqual(self.events, [])

    def test_a_failed_check_leaves_no_work_directory_and_the_originals_unchanged(self):
        before = (pc.treeDigest(self.engine), pc.treeDigest(self.runtime))
        with mock.patch.object(prove, "checkTarget", side_effect=pe.EngineError("proof failed")):
            with self.assertRaisesRegex(pe.EngineError, "proof failed"):
                self.prove()
        self.assertEqual(os.listdir(self.tmp), [])
        self.assertEqual((pc.treeDigest(self.engine), pc.treeDigest(self.runtime)), before)

    def test_a_linked_file_holding_an_original_path_is_refused(self):
        original = os.path.realpath(self.engine).encode()
        real = prove.checkTarget

        def leaky(run, stage, work, target):
            outputs = real(run, stage, work, target)
            sanTest.write(next(iter(outputs.values())), b"MZ " + original)
            return outputs

        with mock.patch.object(prove, "checkTarget", side_effect=leaky):
            with self.assertRaisesRegex(pe.EngineError, "holds source paths"):
                self.prove()

    def test_a_changed_control_after_the_install_is_refused(self):
        calls = []

        def controls(run, stage, work, target, variant):
            calls.append(1)
            return ["$ROOT/a"], b"o", b"x" if len(calls) <= len(TARGETS) * len(pws.SOURCE_VARIANTS) else b"y"

        with mock.patch.object(pwc, "controlResults", side_effect=controls):
            with self.assertRaisesRegex(pe.EngineError, "control's linked file changes"):
                self.prove()

    def test_an_install_that_misses_an_archive_of_a_chosen_target_is_refused(self):
        with mock.patch.object(san, "installResource", return_value=["lib/windows/other.a"]):
            with self.assertRaisesRegex(pe.EngineError, "installResource installed"):
                self.prove()


    def test_nothing_runs_and_nothing_is_staged_when_execute_is_off_and_the_default_output_is_the_inspection_one(self):
        output = self.prove()
        self.assertEqual(self.programs.calls, [])
        self.assertIn(prove.LIMIT, output)
        for text in ("runs natively", "not run", "native machine"):
            self.assertNotIn(text, output)

    def test_a_host_that_is_not_windows_is_refused_before_staging(self):
        with mock.patch.object(prove.sys, "platform", "linux"):
            with self.assertRaisesRegex(pe.EngineError, "needs a Windows host"):
                self.prove(execute=True)
        self.assertEqual((self.events, os.listdir(self.tmp), self.programs.calls), ([], [], []))

    def test_no_chosen_target_matching_the_native_machine_is_refused_before_staging(self):
        self.native = (0, pw.TARGETS[ARM64]["machine"])
        with self.assertRaisesRegex(pe.EngineError, "native machine is ARM64 and %s is not among" % ARM64):
            self.proveExecuting(targets=[X64])
        self.native = (0, 0x14c)
        with self.assertRaisesRegex(pe.EngineError, "neither AMD64 nor ARM64"):
            self.proveExecuting()
        self.assertEqual((self.events, os.listdir(self.tmp), self.programs.calls), ([], [], []))

    def test_an_engine_without_the_symbolizer_is_refused_before_staging(self):
        os.remove(os.path.join(self.engine, "bin", prove.SYMBOLIZER))
        with self.assertRaisesRegex(pe.EngineError, "has no bin/llvm-symbolizer.exe"):
            self.proveExecuting()
        self.assertEqual((self.events, os.listdir(self.tmp), self.programs.calls), ([], [], []))

    def test_only_the_native_target_runs_an_emulated_controller_does_not_change_it_and_the_summary_says_so(self):
        self.native = (pw.TARGETS[X64]["machine"], pw.TARGETS[ARM64]["machine"])
        output = self.proveExecuting()
        self.assertRegex(output, "%s: \\d+ linked files inspected .*; not run" % X64)
        self.assertRegex(output, "%s: \\d+ linked files inspected .*; 21 runs natively" % ARM64)
        self.assertIn("native machine ARM64; this process is emulated", output)
        self.assertIn(prove.LIMIT_EXECUTED, output)
        self.assertNotIn(prove.LIMIT, output)
        self.assertEqual(len(self.programs.calls), 21)
        programs = [c[1] if os.path.basename(c[0]).startswith("host-") else c[0] for c, _, _ in self.programs.calls]
        self.assertTrue(all("san-" + ARM64 in path for path in programs))
        self.assertEqual(os.listdir(self.tmp), [])

    def test_the_x64_native_run_executes_every_case_and_the_other_target_is_only_inspected(self):
        output = self.proveExecuting(targets=None)
        self.assertRegex(output, "%s: \\d+ linked files inspected .*; 63 runs natively" % X64)
        self.assertIn("native machine AMD64; this process is not emulated", output)
        self.assertEqual(os.listdir(self.tmp), [])

    def test_a_run_that_fails_leaves_no_work_directory(self):
        self.programs.change = lambda command, result: outcome(prove.PROOFS["clean"], prove.PROOFS["clean"]["runs"][0],
                                                               returncode=1) if "clean-" in command[0] else result
        with self.assertRaisesRegex(pe.EngineError, "a clean run exited 1"):
            self.proveExecuting()
        self.assertEqual(os.listdir(self.tmp), [])


class SandboxTest(unittest.TestCase):
    def test_off_macos_the_host_runs_and_the_sandbox_is_labelled_absent(self):
        with mock.patch.object(prove.sys, "platform", "linux"):
            run, label = prove.sandboxRun("/e", "/w", ["/e"])
        self.assertEqual(label, "none")
        self.assertTrue(callable(run))

    def test_on_macos_every_original_is_denied_and_a_sandbox_that_runs_the_original_clang_is_refused(self):
        work = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work)
        with mock.patch.object(prove.sys, "platform", "darwin"), \
                mock.patch.object(pr, "sandboxed", return_value=done(1)) as sandboxed:
            run, label = prove.sandboxRun("/e", work, ["/e", "/r", "/d"])
            self.assertEqual(label, "macos")
            run(["clang"])
            self.assertEqual(sandboxed.call_args_list[-1][0][2], ["clang"])
            with open(os.path.join(work, "deny.sb"), encoding="utf-8") as f:
                profile = f.read()
            for path in ("/e", "/r", "/d"):
                self.assertIn('(deny file-read* (subpath "%s"))(deny process-exec (subpath "%s"))' % (path, path), profile)
        with mock.patch.object(prove.sys, "platform", "darwin"), mock.patch.object(pr, "sandboxed", return_value=done(0)):
            with self.assertRaisesRegex(pe.EngineError, "does not deny"):
                prove.sandboxRun("/e", work, ["/e"])


def kernel32(process, native, result=1):
    """A kernel32 whose IsWow64Process2 stores process and native through the pointers it is given."""
    def query(handle, processPointer, nativePointer):
        query.handles.append(handle)
        processPointer.contents.value, nativePointer.contents.value = process, native
        return result

    query.handles = []
    return types.SimpleNamespace(IsWow64Process2=query, GetCurrentProcess=lambda: -1)


class NativeTest(unittest.TestCase):
    def native(self, chosen, process, machine, **options):
        with mock.patch.object(prove.sys, "platform", "win32"), \
                mock.patch("platform.machine", side_effect=AssertionError("platform.machine is not the native machine")):
            return prove.nativeTarget(chosen, kernel32(process, machine, **options))

    def test_the_native_machine_selects_its_own_target_and_an_emulated_process_is_reported_not_trusted(self):
        self.assertEqual(self.native(TARGETS, 0, pw.TARGETS[X64]["machine"]), (X64, False))
        self.assertEqual(self.native(TARGETS, 0, pw.TARGETS[ARM64]["machine"]), (ARM64, False))
        self.assertEqual(self.native(TARGETS, pw.TARGETS[X64]["machine"], pw.TARGETS[ARM64]["machine"]), (ARM64, True))
        self.assertEqual(self.native([ARM64], 0, pw.TARGETS[ARM64]["machine"]), (ARM64, False))

    def test_isWow64Process2_is_called_with_the_current_process_and_the_header_types(self):
        fake = kernel32(0, pw.TARGETS[X64]["machine"])
        self.assertEqual(prove.hostMachines(fake), (0, pw.TARGETS[X64]["machine"]))
        query = fake.IsWow64Process2
        self.assertEqual(query.handles, [-1])
        self.assertEqual((query.restype, query.argtypes), (ctypes.c_int, [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort),
                                                                          ctypes.POINTER(ctypes.c_ushort)]))
        self.assertEqual(fake.GetCurrentProcess.restype, ctypes.c_void_p)

    def test_a_chosen_set_without_the_native_target_names_both(self):
        with self.assertRaisesRegex(pe.EngineError, "native machine is AMD64 and %s is not among the chosen targets %s" % (
                X64, ARM64)):
            self.native([ARM64], 0, pw.TARGETS[X64]["machine"])

    def test_an_unsupported_native_machine_a_failed_call_and_a_missing_function_are_named_errors(self):
        for machine in (0, 0x14c):
            with self.assertRaisesRegex(pe.EngineError, "native machine %#x is neither AMD64 nor ARM64" % machine):
                self.native(TARGETS, 0, machine)
        with mock.patch.object(ctypes, "get_last_error", create=True, return_value=5):
            with self.assertRaisesRegex(pe.EngineError, "IsWow64Process2 failed with error 5"):
                self.native(TARGETS, 0, pw.TARGETS[X64]["machine"], result=0)
        with mock.patch.object(prove.sys, "platform", "win32"):
            with self.assertRaisesRegex(pe.EngineError, "no IsWow64Process2 .*1709"):
                prove.nativeTarget(TARGETS, types.SimpleNamespace(GetCurrentProcess=lambda: -1))

    def test_a_host_that_is_not_windows_is_refused_without_asking_the_api(self):
        for platform in ("linux", "darwin"):
            with mock.patch.object(prove.sys, "platform", platform), mock.patch.object(prove, "hostMachines") as asked:
                with self.assertRaisesRegex(pe.EngineError, "needs a Windows host: this one is %s" % platform):
                    prove.nativeTarget(TARGETS)
            asked.assert_not_called()


class EnvironmentTest(sanTest.TempCase):
    environ = {"PATH": "C:\\keep;C:\\more", "SystemRoot": "C:\\Windows", "TEMP": "C:\\t", "asan_options": "x=1",
               "UBSAN_OPTIONS": "y=1", "LSAN_OPTIONS": "z=1", "ASAN_SYMBOLIZER_PATH": "C:\\other.exe"}
    heap, clean = prove.PROOFS["heap"]["runs"][0], prove.PROOFS["clean"]["runs"][0]

    def test_path_and_the_system_variables_are_inherited_unchanged_and_the_symbolizer_is_the_staged_one(self):
        before = dict(self.environ)
        environment = prove.proofEnvironment(self.environ, "C:\\stage\\bin\\llvm-symbolizer.exe", self.clean)
        self.assertEqual(self.environ, before)
        for key in ("PATH", "SystemRoot", "TEMP"):
            self.assertEqual(environment[key], self.environ[key])
        self.assertEqual({environment[k] for k in ("ASAN_SYMBOLIZER_PATH", "UBSAN_SYMBOLIZER_PATH")},
                         {"C:\\stage\\bin\\llvm-symbolizer.exe"})
        self.assertEqual([k for k in environment if k.upper() in ("ASAN_OPTIONS", "UBSAN_OPTIONS", "LSAN_OPTIONS")], [])

    def test_only_a_heap_run_gets_options_and_they_are_the_proofs_own_not_an_inherited_value(self):
        self.assertEqual(prove.proofEnvironment(self.environ, "s", self.heap)["ASAN_OPTIONS"], "verbosity=2")
        self.assertEqual(prove.proofEnvironment({"ASAN_OPTIONS": "halt_on_error=0"}, "s", self.heap)["ASAN_OPTIONS"],
                         "verbosity=2")

    def test_the_symbolizer_path_is_the_absolute_staged_tool_and_the_runtimes_refused_forms_are_refused(self):
        tool = os.path.join(self.dir, "stage", "bin", prove.SYMBOLIZER)
        with self.assertRaisesRegex(pe.EngineError, "has no bin/llvm-symbolizer.exe"):
            prove.symbolizerPath(os.path.join(self.dir, "stage"))
        sanTest.write(tool)
        self.assertEqual(prove.symbolizerPath(os.path.join(self.dir, "stage")), tool)
        percent = os.path.join(self.dir, "a%b")
        sanTest.write(os.path.join(percent, "bin", prove.SYMBOLIZER))
        with self.assertRaisesRegex(pe.EngineError, "not one the runtime accepts"):
            prove.symbolizerPath(percent)
        with mock.patch.object(os.path, "isfile", return_value=True):
            with self.assertRaisesRegex(pe.EngineError, "not one the runtime accepts"):
                prove.symbolizerPath(self.dir + '"quoted')
            with self.assertRaisesRegex(pe.EngineError, "not one the runtime accepts"):
                prove.symbolizerPath("relative")


class RunProgramTest(unittest.TestCase):
    def test_a_program_runs_with_the_given_environment_directory_and_the_bounded_timeout_capturing_both_streams(self):
        with mock.patch.object(subprocess, "run", return_value=done(0, "o", "e")) as run:
            self.assertEqual(prove.runProgram(["p.exe", "1"], {"A": "b"}, "d").stdout, "o")
        run.assert_called_once_with(["p.exe", "1"], env={"A": "b"}, cwd="d", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    encoding="utf-8", errors="replace", timeout=45)

    def test_a_program_that_does_not_finish_is_a_named_error(self):
        with mock.patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired(["p.exe"], 45)):
            with self.assertRaisesRegex(pe.EngineError, "p.exe did not finish in 45 seconds"):
                prove.runProgram([os.path.join("d", "p.exe")], {}, "d")


class RunProblemTest(unittest.TestCase):
    def cases(self):
        return [(name, proof, run) for name, proof in prove.PROOFS.items() for run in proof["runs"]]

    def fatal(self):
        return [case for case in self.cases() if case[2]["sanitizer"]]

    def test_every_run_of_every_proof_is_accepted_when_it_is_what_the_sanitizers_print(self):
        for name, proof, run in self.cases():
            self.assertIsNone(prove.runProblem(proof, run, outcome(proof, run)), (name, run["step"]))

    def test_the_sites_are_single_lines_of_the_fixtures_and_a_missing_or_repeated_one_is_an_error(self):
        for name, proof, run in self.fatal():
            with open(os.path.join(pr.FIXTURES, proof["fixture"]), encoding="utf-8") as f:
                self.assertIn(run["site"], f.read().splitlines()[prove.siteLine(proof, run) - 1], name)
        with self.assertRaisesRegex(pe.EngineError, "on 0 lines"):
            prove.siteLine(prove.PROOFS["signed"], {"site": "no such text"})
        with self.assertRaisesRegex(pe.EngineError, "on 2 lines"):
            prove.siteLine(prove.PROOFS["clean"], {"site": "volatile"})

    def test_a_clean_run_needs_exit_zero_its_exact_marker_and_no_report(self):
        for name in ("clean", "dll", "cppdll"):
            proof, run = prove.PROOFS[name], prove.PROOFS[name]["runs"][0]
            for change in ({"returncode": 1}, {"stdout": run["marker"] + "extra\n"}, {"stdout": ""},
                           {"stderr": "x.c:1:1: runtime error: boom\n"}, {"stderr": "ERROR: AddressSanitizer: x\n"}):
                self.assertIn("a clean run exited", prove.runProblem(proof, run, outcome(proof, run, **change)), (name, change))

    def test_a_run_that_must_fail_is_refused_when_it_exits_zero_crashes_silently_or_cannot_load(self):
        for name, proof, run in self.fatal():
            self.assertIn("exited 0", prove.runProblem(proof, run, outcome(proof, run, returncode=0)), name)
            for code in (0xC0000005, 0xC0000135, 3):
                result = outcome(proof, run, returncode=code, stderr="")
                self.assertIn("does not hold the", prove.runProblem(proof, run, result), (name, code))

    def test_a_run_that_reaches_its_marker_is_refused_even_with_the_report(self):
        for name, proof, run in self.fatal():
            for stdout in ("sanitizer %s unreachable 1\n" % name, prove.HOST_MARKER):
                self.assertIn("reached its marker", prove.runProblem(proof, run, outcome(proof, run, stdout=stdout)), name)

    def test_the_report_must_name_the_fixture_and_its_line_and_the_column_is_optional(self):
        for name, proof, run in self.fatal():
            line = prove.siteLine(proof, run)
            good = outcome(proof, run).stderr
            for bad in (good.replace(":%d:" % line, ":%d:" % (line + 1)), good.replace(proof["fixture"], "other.c"),
                        good.replace(proof["fixture"], "x" + proof["fixture"])):
                self.assertIn("has no %s report at" % run["report"],
                              prove.runProblem(proof, run, outcome(proof, run, stderr=bad)), (name, bad))
            if run["report"] != "heap":
                self.assertIsNone(prove.runProblem(proof, run, outcome(proof, run, stderr=good.replace(":5:", ":"))), name)

    def test_a_heap_frame_without_a_source_location_is_not_accepted(self):
        proof, run = prove.PROOFS["heap"], prove.PROOFS["heap"]["runs"][0]
        good = outcome(proof, run).stderr
        located = "main C:\\work dir\\windowsSanitizerHeap.c:10:5"
        self.assertIn(located, good)
        for frame in ("main (windowsSanitizerHeap.exe+0x1234)", "main", ""):
            self.assertIn("has no heap report", prove.runProblem(proof, run, outcome(proof, run, stderr=good.replace(
                located, frame))))
        late = good.replace("#0 0x1 in " + located, "#0 0x1 in main (a.exe+0x1)").replace(
            "#1 0x2 in __scrt_common_main_seh", "#1 0x2 in " + located)
        self.assertIn("has no heap report", prove.runProblem(proof, run, outcome(proof, run, stderr=late)))

    def test_the_other_sanitizers_report_instead_of_or_beside_the_right_one_is_refused(self):
        signed, heap = prove.PROOFS["signed"], prove.PROOFS["heap"]
        signedRun, heapRun = signed["runs"][0], heap["runs"][0]
        signedText, heapText = outcome(signed, signedRun).stderr, outcome(heap, heapRun).stderr
        for proof, run, instead, beside in ((signed, signedRun, heapText, signedText + heapText),
                                            (heap, heapRun, signedText, heapText + signedText)):
            for text in (instead, beside):
                self.assertIn("report alone", prove.runProblem(proof, run, outcome(proof, run, stderr=text)))

    def test_a_heap_report_must_say_which_symbolizer_backend_was_used(self):
        proof, run = prove.PROOFS["heap"], prove.PROOFS["heap"]["runs"][0]
        text = outcome(proof, run).stderr.split("\n", 1)[1]
        self.assertIn("llvm-symbolizer was used", prove.runProblem(proof, run, outcome(proof, run, stderr=text)))

    def test_either_vptr_kind_may_fire_first_and_the_type_names_are_required(self):
        proof, run = prove.PROOFS["vptr"], prove.PROOFS["vptr"]["runs"][0]
        good = outcome(proof, run).stderr
        self.assertIsNone(prove.runProblem(proof, run, outcome(proof, run, stderr=good.replace("member call on", "downcast of"))))
        self.assertIn("has no vptr report", prove.runProblem(proof, run, outcome(proof, run, stderr=good.replace(
                "member call on", "load of"))))
        self.assertIn("has no vptr report", prove.runProblem(proof, run, outcome(proof, run, stderr=good.replace(
                "'Derived'", "'Base'"))))

    def test_the_loader_hosts_own_failure_is_never_a_sanitizers_whatever_else_it_printed(self):
        failure = "windowsSanitizerHost: LoadLibraryW(x.dll) failed with error 126\n"
        for name, proof, run in self.cases():
            for text in (failure, outcome(proof, run).stderr + failure):
                self.assertIn("the loader host failed", prove.runProblem(proof, run, outcome(proof, run, returncode=2, stderr=text)),
                              name)


class DllCopyTest(sanTest.TempCase):
    def setUp(self):
        super().setUp()
        self.name = san.ASAN_DLL_NAME % san.architecture(X64)
        self.source = self.path("root", "runtime", "windows", X64, "bin", self.name)
        self.directory = self.path("work")
        os.makedirs(self.directory)
        sanTest.write(self.source, b"MZ asan dll\n")

    def copy(self):
        return prove.copyAsanDll(self.path("root"), X64, self.directory)

    def test_the_dll_is_copied_byte_identical_beside_the_programs_and_the_source_is_not_touched(self):
        source, copy, digest = self.copy()
        self.assertEqual((source, copy), (self.source, os.path.join(self.directory, self.name)))
        self.assertEqual(sanTest.read(copy), b"MZ asan dll\n")
        self.assertEqual((pe.sha256File(copy), pe.sha256File(source)), (digest, digest))
        self.assertEqual(sorted(os.listdir(self.directory)), [self.name])

    def test_a_missing_source_an_existing_copy_and_a_copy_that_differs_are_refused(self):
        sanTest.write(os.path.join(self.directory, self.name), b"other")
        with self.assertRaisesRegex(pe.EngineError, "exists already beside the programs"):
            self.copy()
        os.remove(os.path.join(self.directory, self.name))
        with mock.patch.object(shutil, "copyfile", side_effect=lambda s, d: sanTest.write(d, b"MZ changed")):
            with self.assertRaisesRegex(pe.EngineError, "differs from"):
                self.copy()
        os.remove(os.path.join(self.directory, self.name))
        os.remove(self.source)
        with self.assertRaisesRegex(pe.EngineError, "has no windows/%s/bin/%s" % (X64, self.name)):
            self.copy()

    def test_a_link_to_the_dll_is_refused_and_leaves_nothing_beside_the_programs(self):
        os.replace(self.source, self.path("moved.dll"))
        self.symlink(self.path("moved.dll"), self.source)
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            self.copy()
        self.assertEqual(os.listdir(self.directory), [])

    def test_a_link_among_the_directories_of_the_dll_is_refused(self):
        os.replace(os.path.dirname(self.source), self.path("moved bin"))
        try:
            os.symlink(self.path("moved bin"), os.path.dirname(self.source), target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("this host cannot create a directory symlink")
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            self.copy()
        self.assertEqual(os.listdir(self.directory), [])


class HostTest(StageCase):
    def setUp(self):
        super().setUp()
        patch = mock.patch.object(pws, "selectionProblem", return_value=None)
        self.selection = patch.start()
        self.addCleanup(patch.stop)

    def host(self, run, target=X64, mask="address,undefined"):
        self.target = target
        return prove.checkHost(run, self.stage, self.work, target, mask)

    def test_the_host_is_compiled_and_linked_for_the_mask_through_the_c_base_config_with_the_wide_startup(self):
        for target in TARGETS:
            for mask in prove.masks(target):
                run = self.toolchain(target)
                path = self.host(run, target, mask)
                self.assertEqual(path, os.path.join(self.work, "host-%s-plain.exe" % mask.replace(",", "+")))
                compile_, link, plan = run.commands
                for command in run.commands:
                    self.assertFalse(os.path.basename(command[0]).startswith("clang++"))
                    self.assertEqual([os.path.basename(w) for w in command if w.startswith("--config=")],
                                     [os.path.basename(pwc.baseConfigPath(target, "exe"))])
                    self.assertEqual([w for w in command if w.startswith("-fsanitize")], ["-fsanitize=" + mask])
                    self.assertNotIn("vptr", " ".join(command))
                    self.assertNotIn("-fno-sanitize-recover=undefined", command)
                self.assertEqual(("-c" in compile_, "-municode" in compile_), (True, False))
                self.assertTrue(compile_[compile_.index("-c") + 1].endswith("windowsSanitizerHost.c"))
                self.assertIn("-g", compile_)
                self.assertEqual(("-municode" in link, "-municode" in plan, "-###" in plan), (True, True, True))
                self.selection.assert_called_with(mock.ANY, os.path.join(self.stage, "runtime", "windows"), target, "wide")

    def test_a_plan_selection_pe_or_toolchain_failure_names_the_host_and_mask(self):
        self.selection.return_value = "the startup object is wrong"
        with self.assertRaisesRegex(pe.EngineError, "%s host address: the startup object is wrong" % X64):
            self.host(self.toolchain(), mask="address")
        self.selection.return_value = None
        run = self.toolchain()
        run.plan = lambda command, text: text.replace('"--whole-archive" ', "")
        with self.assertRaisesRegex(pe.EngineError, "host address: the ASan tail"):
            self.host(run, mask="address")
        self.infos[os.path.join(self.work, "host-undefined-plain.exe")] = linkedInfo(X64, "host", "undefined", subsystem=2)
        with self.assertRaisesRegex(pe.EngineError, "host undefined: subsystem"):
            self.host(self.toolchain(), mask="undefined")
        failing = self.toolchain()
        failing.fail = lambda command: "boom" if "-municode" in command and "-###" not in command else None
        with self.assertRaisesRegex(pe.EngineError, "%s host undefined link failed \\(1\\).*boom" % X64):
            self.host(failing, mask="undefined")


class ExecuteTargetTest(StageCase):
    environ = {"PATH": "C:\\keep", "SystemRoot": "C:\\Windows", "ASAN_OPTIONS": "inherited=1"}

    def setUp(self):
        super().setUp()
        sanTest.write(os.path.join(self.stage, "bin", prove.SYMBOLIZER))
        for target in TARGETS:
            sanTest.write(os.path.join(self.stage, "runtime", "windows", target, "bin", san.ASAN_DLL_NAME % san.architecture(
                target)), b"MZ asan dll\n")
        self.programs = Programs()
        self.selection = mock.patch.object(pws, "selectionProblem", return_value=None)
        self.selection.start()
        self.addCleanup(self.selection.stop)
        patch = mock.patch.object(prove, "runProgram", side_effect=self.programs)
        patch.start()
        self.addCleanup(patch.stop)

    def execute(self, target=X64):
        outputs = self.check(self.toolchain(target), target)
        return prove.executeTarget(self.toolchain(target), self.stage, target, outputs, self.environ)

    def test_every_proof_runs_plain_thin_and_full_under_each_mask_that_can_exercise_it(self):
        self.assertEqual(self.execute(X64), 63)
        self.assertEqual(len(self.programs.calls), 63)

    def test_arm64_runs_the_undefined_cases_alone_and_copies_no_asan_dll(self):
        self.assertEqual(self.execute(ARM64), 21)
        self.assertEqual([f for f in os.listdir(self.work) if f.startswith("libclang_rt")], [])
        self.assertEqual(len(self.programs.calls), 21)

    def test_executables_run_bare_and_dlls_run_through_the_host_of_their_mask_with_step_and_expected_value(self):
        self.execute()
        for command, _, _ in self.programs.calls:
            if os.path.basename(command[0]).startswith("host-"):
                proof, mask, mode = tagOf(command[1])
                self.assertEqual(os.path.basename(command[0]), "host-%s-plain.exe" % mask.replace(",", "+"))
                spec = prove.PROOFS[proof]
                self.assertEqual(command[2], spec["export"])
                expected = {"cppdll": {"0": "2"}}.get(proof, {}).get(command[3], "0")
                self.assertEqual((command[3] in ("0", "1", "2"), command[4]), (True, expected))
            else:
                self.assertEqual(len(command), 1)
        steps = {(tagOf(c[1])[0], c[3]) for c, _, _ in self.programs.calls if os.path.basename(c[0]).startswith("host-")}
        self.assertEqual(steps, {("dll", "0"), ("dll", "1"), ("dll", "2"), ("cppdll", "0"), ("cppdll", "1")})

    def test_a_mask_without_a_sanitizer_never_runs_that_sanitizers_steps(self):
        self.execute()
        for command, _, _ in self.programs.calls:
            if os.path.basename(command[0]).startswith("host-"):
                proof, mask, _ = tagOf(command[1])
                step = int(command[3])
                if step == 2:
                    self.assertIn("address", mask.split(","))
                if (proof, step) in (("dll", 1), ("cppdll", 1)):
                    self.assertIn("undefined", mask.split(","))
            else:
                proof, mask, _ = tagOf(command[0])
                if proof == "heap":
                    self.assertIn("address", mask.split(","))
                if proof in ("signed", "vptr"):
                    self.assertIn("undefined", mask.split(","))

    def test_the_asan_dll_sits_beside_the_programs_before_the_first_run_and_is_a_byte_identical_copy(self):
        seen = []
        dll = os.path.join(self.work, san.ASAN_DLL_NAME % san.architecture(X64))
        self.programs.change = lambda command, result: seen.append(sanTest.read(dll)) or result
        self.execute()
        self.assertEqual(set(seen), {b"MZ asan dll\n"})
        self.assertEqual({d for _, _, d in self.programs.calls}, {self.work})

    def test_the_child_environment_keeps_path_and_the_systems_and_sets_only_the_symbolizer_and_heap_options(self):
        before = os.environ.get("PATH")
        self.execute()
        self.assertEqual(os.environ.get("PATH"), before)
        symbolizer = os.path.join(self.stage, "bin", prove.SYMBOLIZER)
        for command, environment, _ in self.programs.calls:
            self.assertEqual((environment["PATH"], environment["SystemRoot"]), ("C:\\keep", "C:\\Windows"))
            self.assertEqual((environment["ASAN_SYMBOLIZER_PATH"], environment["UBSAN_SYMBOLIZER_PATH"]), (symbolizer,) * 2)
            heap = "heap" in tagOf(command[0])[0] or (len(command) > 3 and command[3] == "2")
            self.assertEqual(environment.get("ASAN_OPTIONS"), "verbosity=2" if heap else None, command)

    def test_a_failing_run_names_the_target_proof_mask_mode_and_step(self):
        self.programs.change = lambda command, result: outcome(prove.PROOFS["signed"], prove.PROOFS["signed"]["runs"][0],
                                                               returncode=0) if "signed-undefined-thin" in command[0] else result
        with self.assertRaisesRegex(pe.EngineError, "%s signed undefined thin: exited 0" % X64):
            self.execute()
        os.remove(os.path.join(self.work, san.ASAN_DLL_NAME % san.architecture(X64)))
        self.programs.change = lambda command, result: done(2, "", "windowsSanitizerHost: LoadLibraryW(x) failed with error "
                                                              "126\n") if len(command) > 3 and command[3] == "2" else result
        with self.assertRaisesRegex(pe.EngineError, r"%s dll address full step 2: the loader host failed" % X64):
            self.execute()

    def test_a_dll_or_its_source_that_changes_while_the_programs_run_is_refused(self):
        name = san.ASAN_DLL_NAME % san.architecture(X64)
        source = os.path.join(self.stage, "runtime", "windows", X64, "bin", name)
        copy = os.path.join(self.work, name)
        for victim in (copy, source):
            self.programs.change = lambda command, result, victim=victim: sanTest.write(victim, b"MZ changed") or result
            with self.assertRaisesRegex(pe.EngineError, "changed while the programs ran"):
                self.execute()
            sanTest.write(source, b"MZ asan dll\n")
            os.remove(copy)

    def test_a_missing_symbolizer_stops_before_anything_is_copied_built_or_run(self):
        os.remove(os.path.join(self.stage, "bin", prove.SYMBOLIZER))
        outputs = self.check(self.toolchain())
        run = self.toolchain()
        with self.assertRaisesRegex(pe.EngineError, "has no bin/llvm-symbolizer.exe"):
            prove.executeTarget(run, self.stage, X64, outputs, self.environ)
        self.assertEqual((run.commands, self.programs.calls), ([], []))
        self.assertFalse(os.path.exists(os.path.join(self.work, san.ASAN_DLL_NAME % san.architecture(X64))))


class CommandLineTest(unittest.TestCase):
    def main(self, *argv):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            try:
                return prove.main(list(argv)), err.getvalue()
            except SystemExit as error:
                return error.code, err.getvalue()

    def test_engine_and_runtime_are_required(self):
        for argv in ((), ("--engine", "/e"), ("--runtime", "/r")):
            code, error = self.main(*argv)
            self.assertEqual(code, 2)
            self.assertIn("required", error)

    def test_execute_reaches_the_prover_and_is_off_by_default(self):
        with mock.patch.object(prove, "prove") as proved:
            self.assertEqual(self.main("--engine", "/e", "--runtime", "/r", "--execute")[0], 0)
            proved.assert_called_once_with("/e", "/r", [], [], True)
            proved.reset_mock()
            self.assertEqual(self.main("--engine", "/e", "--runtime", "/r")[0], 0)
            proved.assert_called_once_with("/e", "/r", [], [], False)

    def test_the_options_reach_the_prover_and_an_engine_error_is_exit_one(self):
        with mock.patch.object(prove, "prove") as proved:
            code, _ = self.main("--engine", "/e", "--runtime", "/r", "--target", X64, "--deny", "/d")
        self.assertEqual(code, 0)
        proved.assert_called_once_with("/e", "/r", ["/d"], [X64], False)
        with mock.patch.object(prove, "prove", side_effect=pe.EngineError("bad")):
            code, error = self.main("--engine", "/e", "--runtime", "/r")
        self.assertEqual((code, error), (1, "proveWindowsSanitizerRuntime: error: bad\n"))


if __name__ == "__main__":
    unittest.main()
