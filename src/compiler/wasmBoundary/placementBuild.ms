import { execPath, execFileResult, cwd } from "std/process";
import { ensureDir, writeFile, rename, exists, remove } from "std/fs";
import { basename, isAbsolute, join, normalize } from "std/fs/path";
import { CliOptions, MODE_RELEASE, MODE_DANGER } from "../options";

// Builds the wasm half of a placed program as its own `--os=emcc --app=lib` build, in a child of the
// running binary because a build keeps its link flags and object lists in process-wide state.
// `exportedSymbols` are the emcc export names as `-sEXPORTED_FUNCTIONS` spells them, leading underscore included.
// Writes `<outStem>.wasm.mjs` and `<outStem>.wasm`.
export function buildWasmHalf(entrySource: string, exportedSymbols: string[], runtimeMethods: string[], jsLibrary: string, outStem: string, opts: CliOptions): Result<void, string> {
	if (exportedSymbols.length == 0) return Result.err("internal: buildWasmHalf got no exported symbols");
	const stem = isAbsolute(outStem) ? normalize(outStem) : normalize(join(cwd(), outStem));
	const base = basename(stem);
	const stage = `${stem}.wasmbuild`;
	const entry = `${stage}/${base}.ms`;
	const library = `${stage}/${base}.lib.js`;
	const mjs = `${stage}/${base}.mjs`;
	const ensured = ensureDir(stage);
	if (!ensured.ok) return Result.err(`cannot create ${stage}: ${ensured.error.message}`);
	const wroteEntry = writeFile(entry, entrySource);
	if (!wroteEntry.ok) return Result.err(`cannot write ${entry}: ${wroteEntry.error.message}`);
	const wroteLibrary = writeFile(library, jsLibrary);
	if (!wroteLibrary.ok) return Result.err(`cannot write ${library}: ${wroteLibrary.error.message}`);

	let exports = "";
	for (const symbol of exportedSymbols) exports = exports == "" ? symbol : `${exports},${symbol}`;
	const runtime = runtimeMethods.length == 0 ? "" : ` -sEXPORTED_RUNTIME_METHODS=${runtimeMethods.join(",")}`;
	const args = ["build", entry, "--target=c", "--os=emcc", "--app=lib", `--output=${mjs}`,
		`--passL=-sWASM_BIGINT=1 -sEXPORTED_FUNCTIONS=${exports}${runtime} -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=node,web --js-library=${library}`];
	if (opts.mode == MODE_RELEASE) args.push("--release");
	if (opts.mode == MODE_DANGER) args.push("--danger");
	const run = execFileResult(execPath, args, stage);
	if (!run.started) return Result.err(`cannot start ${execPath} for the wasm half (errno ${run.startErrno})`);
	if (run.exitCode != 0 || run.signal != 0) {
		return Result.err(`the wasm half failed to build (exit ${run.exitCode}, signal ${run.signal}):\n${run.output}${run.errorOutput}`);
	}
	const built = `${stage}/${base}.wasm`;
	if (!exists(mjs) || !exists(built)) return Result.err(`the wasm half built but ${mjs} or ${built} is missing`);
	const outMjs = `${stem}.wasm.mjs`;
	const outWasm = `${stem}.wasm`;
	if (exists(outMjs)) remove(outMjs);
	if (exists(outWasm)) remove(outWasm);
	const movedMjs = rename(mjs, outMjs);
	if (!movedMjs.ok) return Result.err(`cannot move ${mjs} to ${outMjs}: ${movedMjs.error.message}`);
	const movedWasm = rename(built, outWasm);
	if (!movedWasm.ok) return Result.err(`cannot move ${built} to ${outWasm}: ${movedWasm.error.message}`);
	return Result.ok(null);
}
