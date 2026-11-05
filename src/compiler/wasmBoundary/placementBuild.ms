import { execPath, execFileResult, cwd } from "std/process";
import { ensureDir, writeFile, rename, exists, remove } from "std/fs";
import { basename, isAbsolute, join, normalize } from "std/fs/path";
import { LEDGER_EXPORT, ledgerEntryLines } from "./wasmSide";
import {
	CliOptions,
	MODE_RELEASE,
	MODE_DANGER,
	newCliOptions,
} from "../options";
import {
	defineSymbol,
	definedValue,
	initDefines,
	isOptionDefine,
	seedProjectDir,
} from "../defines";

function wasmHalfOptions(opts: CliOptions): Result<string[], string> {
	if (opts.passC.includes("\0") || opts.passL.includes("\0")) {
		return Result.err("wasm half compiler/linker flags contain NUL and cannot be passed to the child");
	}
	const args = [`--passC=-msimd128 ${opts.passC}`];
	if (opts.passL != "") args.push(`--passL=${opts.passL}`);
	for (const name of opts.defines.names) {
		if (name != "projectDir" && isOptionDefine(opts.defines, name)) continue;
		const value = definedValue(opts.defines, name);
		if (name.includes("=") || name.includes("\0") || value.includes("\0")) {
			return Result.err("wasm half define cannot be passed to the child: names must not contain '=' or NUL, values must not contain NUL");
		}
		args.push(`-d:${name}=${value}`);
	}
	if (opts.lto != "") args.push(`--lto=${opts.lto}`);
	if (opts.mode == MODE_RELEASE) args.push("--release");
	if (opts.mode == MODE_DANGER) args.push("--danger");
	return Result.ok(args);
}

test "wasm half forwards an explicit LTO strategy including off" {
	for (const lto of ["off", "thin", "full"]) {
		const opts = newCliOptions();
		opts.lto = lto;
		const args = wasmHalfOptions(opts);
		assert args.ok;
		assert args.value.includes(`--lto=${lto}`);
	}
}

test "wasm half leaves the unwritten LTO default to the child driver" {
	const args = wasmHalfOptions(newCliOptions());
	assert args.ok;
	assert !args.value.some((arg) => arg.startsWith("--lto="));
}

test "wasm half carries user defines and project identity, not parent target facts" {
	const opts = newCliOptions();
	initDefines(opts.defines, "js", "macos", "arm64", "drc", 0);
	seedProjectDir(opts.defines, "/p/project with space");
	defineSymbol(opts.defines, "probeMarker", "true");
	defineSymbol(opts.defines, "label", "a=b with space λ");
	defineSymbol(opts.defines, "empty", "");
	const args = wasmHalfOptions(opts);
	assert args.ok;
	assert args.value.includes("-d:probeMarker=true");
	assert args.value.includes("-d:label=a=b with space λ");
	assert args.value.includes("-d:empty=");
	assert args.value.includes("-d:projectDir=/p/project with space");
	for (const name of ["backend", "js", "os", "macos", "cpu", "arm64", "mm", "drc", "mode", "debug"]) {
		assert !args.value.some((arg) => arg.startsWith(`-d:${name}=`));
	}
}

test "wasm half preserves an explicit raw linker argument" {
	const opts = newCliOptions();
	opts.passL = '--js-library="/p/user lib.js" -sUSE_WEBGPU=1';
	const args = wasmHalfOptions(opts);
	assert args.ok;
	assert args.value.includes(`--passL=${opts.passL}`);
}

test "wasm half refuses define names that cannot round trip through argv" {
	for (const name of ["bad=name", "bad\0name"]) {
		const opts = newCliOptions();
		defineSymbol(opts.defines, name, "value");
		assert !wasmHalfOptions(opts).ok;
	}
}

test "wasm half refuses a NUL in a define value instead of truncating it" {
	const opts = newCliOptions();
	defineSymbol(opts.defines, "label", "a\0b");
	assert !wasmHalfOptions(opts).ok;
}

test "wasm half refuses NUL in raw compiler and linker flags" {
	const c = newCliOptions();
	c.passC = "-DVALUE=a\0b";
	assert !wasmHalfOptions(c).ok;
	const l = newCliOptions();
	l.passL = "-Wl,a\0b";
	assert !wasmHalfOptions(l).ok;
}

// Builds the wasm half of a placed program as its own `--os=emcc --app=lib`
// build, in a child of the running binary because a build keeps its link flags
// and object lists in process-wide state.
// `exportedSymbols` are the emcc export names as `-sEXPORTED_FUNCTIONS` spells
// them, leading underscore included.
// A `--passC` naming `-DMS_DRC_LEDGER` reaches the child, which then exports
// `msb_ledger()`: the half's exit never runs `atexit`, so the ledger is read
// by calling it.
// Writes `<outStem>.wasm.mjs` and `<outStem>.wasm`.
export function buildWasmHalf(
	entrySourceBase: string,
	exportedBase: string[],
	runtimeMethods: string[],
	jsLibrary: string,
	outStem: string,
	opts: CliOptions,
): Result<void, string> {
	if (exportedBase.length == 0) {
		return Result.err("internal: buildWasmHalf got no exported symbols");
	}
	const optionArgs = wasmHalfOptions(opts);
	if (!optionArgs.ok) return Result.err(optionArgs.error);
	const ledger = opts.passC.includes("-DMS_DRC_LEDGER");
	const entrySource = ledger
		? entrySourceBase + ledgerEntryLines().join("\n") + "\n"
		: entrySourceBase;
	const exportedSymbols = ledger ? [...exportedBase, LEDGER_EXPORT] : exportedBase;
	const stem = isAbsolute(outStem)
		? normalize(outStem)
		: normalize(join(cwd(), outStem));
	const base = basename(stem);
	const stage = `${stem}.wasmbuild`;
	const entry = `${stage}/${base}.ms`;
	const library = `${stage}/${base}.lib.js`;
	const mjs = `${stage}/${base}.mjs`;
	const ensured = ensureDir(stage);
	if (!ensured.ok) {
		return Result.err(`cannot create ${stage}: ${ensured.error.message}`);
	}
	const wroteEntry = writeFile(entry, entrySource);
	if (!wroteEntry.ok) {
		return Result.err(`cannot write ${entry}: ${wroteEntry.error.message}`);
	}
	const wroteLibrary = writeFile(library, jsLibrary);
	if (!wroteLibrary.ok) {
		return Result.err(
			`cannot write ${library}: ${wroteLibrary.error.message}`,
		);
	}

	let exports = "";
	for (const symbol of exportedSymbols) {
		exports = exports == "" ? symbol : `${exports},${symbol}`;
	}
	const runtime = runtimeMethods.length == 0
		? ""
		: ` -sEXPORTED_RUNTIME_METHODS=${runtimeMethods.join(",")}`;
	const linkFlags = `-sWASM_BIGINT=1 -sEXPORTED_FUNCTIONS=${exports}${runtime}`
		+ " -msimd128 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=node,web"
		+ ` --js-library=${library}`;
	const args = [
		"build",
		entry,
		"--target=c",
		"--os=emcc",
		"--app=lib",
		`--output=${mjs}`,
		`--passL=${linkFlags}`,
	];
	for (const arg of optionArgs.value) args.push(arg);
	const run = execFileResult(execPath, args, stage);
	if (!run.started) {
		return Result.err(
			`cannot start ${execPath} for the wasm half (errno ${run.startErrno})`,
		);
	}
	if (run.exitCode != 0 || run.signal != 0) {
		return Result.err(
			`the wasm half failed to build (exit ${run.exitCode}, `
				+ `signal ${run.signal}):\n${run.output}${run.errorOutput}`,
		);
	}
	const built = `${stage}/${base}.wasm`;
	if (!exists(mjs) || !exists(built)) {
		return Result.err(`the wasm half built but ${mjs} or ${built} is missing`);
	}
	const outMjs = `${stem}.wasm.mjs`;
	const outWasm = `${stem}.wasm`;
	if (exists(outMjs)) remove(outMjs);
	if (exists(outWasm)) remove(outWasm);
	const movedMjs = rename(mjs, outMjs);
	if (!movedMjs.ok) {
		return Result.err(
			`cannot move ${mjs} to ${outMjs}: ${movedMjs.error.message}`,
		);
	}
	const movedWasm = rename(built, outWasm);
	if (!movedWasm.ok) {
		return Result.err(
			`cannot move ${built} to ${outWasm}: ${movedWasm.error.message}`,
		);
	}
	return Result.ok(null);
}
