import contextlib
import io
import os
import shutil
import tempfile
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
    spec = prove.PROOFS[proof]
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

        for patch in (mock.patch.object(pws, "stageTree", side_effect=copyStage),
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
            prove.prove(options.get("engine", self.engine), self.runtime, options.get("denied", []), options.get("targets"))
        return out.getvalue()

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

    def test_execute_is_rejected_before_anything_runs(self):
        with mock.patch.object(prove, "prove") as proved:
            code, error = self.main("--engine", "/e", "--runtime", "/r", "--execute")
        self.assertEqual(code, 2)
        self.assertIn("--execute is not implemented", error)
        proved.assert_not_called()

    def test_the_options_reach_the_prover_and_an_engine_error_is_exit_one(self):
        with mock.patch.object(prove, "prove") as proved:
            code, _ = self.main("--engine", "/e", "--runtime", "/r", "--target", X64, "--deny", "/d")
        self.assertEqual(code, 0)
        proved.assert_called_once_with("/e", "/r", ["/d"], [X64])
        with mock.patch.object(prove, "prove", side_effect=pe.EngineError("bad")):
            code, error = self.main("--engine", "/e", "--runtime", "/r")
        self.assertEqual((code, error), (1, "proveWindowsSanitizerRuntime: error: bad\n"))


if __name__ == "__main__":
    unittest.main()
