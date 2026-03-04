// MetaScript Compiler CLI — build.ms config loader
// TEMPORARY: Raiser VM detached for C-backend bootstrap.
// Hardcoded defaults — build.ms is not evaluated.

/* RAISER VM DETACHED — uncomment to re-attach:
import { readFile, fileExists, clockMs } from "std/process";
import { evalSourceFull } from "../codegen/raiser/eval";
import {
	RaiserValueKind, RaiserValue,
	heapObjectGetString, heapObjectGetObjectHandle, heapObjectGetField,
	heapArrayLen, heapArrayGet,
	RaiserObjectHeap, RaiserArrayHeap,
} from "../raiser/value";
import { error, dim } from "../utils/color";
END RAISER VM DETACHED */

// --- Interfaces ---

export interface BuildSection {
	target: string;
	outDir: string;
	outFile: string;
	optimize: string;
}

export interface ResolveSection {
	searchPaths: string[];
	extensions: string[];
	aliasKeys: string[];
	aliasValues: string[];
}

export interface BuildConfig {
	root: string;
	build: BuildSection;
	resolve: ResolveSection;
	valid: boolean;
}

// --- Public API ---

export function defaultResolveSection(): ResolveSection {
	const sp: string[] = [];
	const ext: string[] = [];
	const ak: string[] = [];
	const av: string[] = [];
	return { searchPaths: sp, extensions: ext, aliasKeys: ak, aliasValues: av };
}

export function loadBuildConfig(filePath: string, showTime: boolean): BuildConfig {
	// TEMPORARY: Hardcode config for C-Backend bootstrap — bypasses Raiser VM
	const defBs: BuildSection = { target: "c", outDir: "out", outFile: "", optimize: "debug" };
	const defRs = defaultResolveSection();
	return { root: "src/index.ms", build: defBs, resolve: defRs, valid: true };
	/* Original implementation (uncomment to re-attach):

	// --- Helpers ---
	function extractStringArray(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, objHandle: number, fieldName: string): string[] {
		const result: string[] = [];
		const val = heapObjectGetField(objHeap, objHandle, fieldName);
		if (val.kind !== RaiserValueKind.Array) return result;
		const arrHandle = val.intVal;
		const len = heapArrayLen(arrHeap, arrHandle);
		let i = 0;
		while (i < len) {
			const elem = heapArrayGet(arrHeap, arrHandle, i);
			if (elem.kind === RaiserValueKind.String) {
				result.push(elem.strVal);
			}
			i = i + 1;
		}
		return result;
	}

	const defBs: BuildSection = { target: "c", outDir: "out", outFile: "", optimize: "debug" };
	const defRs = defaultResolveSection();
	const defCfg: BuildConfig = { root: "", build: defBs, resolve: defRs, valid: false };

	if (!fileExists(filePath)) return defCfg;

	const t0 = clockMs();
	const source = readFile(filePath);
	if (source.length === 0) return defCfg;

	const ctx = evalSourceFull(source);
	if (showTime) {
		const elapsed = clockMs() - t0;
		const ms = "" + elapsed;
		const display = ms.slice(0, ms.length < 6 ? ms.length : 6);
		console.log(dim("  raiser eval in " + display + "ms"));
	}
	if (ctx.lastResult.kind !== RaiserValueKind.Object) {
		console.log(error("error") + ": build.ms did not export a config object");
		return defCfg;
	}

	const handle = ctx.lastResult.intVal;
	const heap = ctx.objectHeap;
	const root = heapObjectGetString(heap, handle, "root");
	if (root.length === 0) return defCfg;

	// Extract build section
	let bsTarget = "c";
	let bsOutDir = "out";
	let bsOutFile = "";
	let bsOptimize = "debug";

	const buildHandle = heapObjectGetObjectHandle(heap, handle, "build");
	if (buildHandle >= 0) {
		const t = heapObjectGetString(heap, buildHandle, "target");
		if (t.length > 0) {
			if (t === "native") {
				bsTarget = "c";
			} else {
				bsTarget = t;
			}
		}
		const od = heapObjectGetString(heap, buildHandle, "outDir");
		if (od.length > 0) { bsOutDir = od; }
		const outF = heapObjectGetString(heap, buildHandle, "outFile");
		if (outF.length > 0) { bsOutFile = outF; }
		const opt = heapObjectGetString(heap, buildHandle, "optimize");
		if (opt.length > 0) { bsOptimize = opt; }
	}

	// Extract resolve section
	let rs = defaultResolveSection();
	const resolveHandle = heapObjectGetObjectHandle(heap, handle, "resolve");
	if (resolveHandle >= 0) {
		const sp = extractStringArray(heap, ctx.arrayHeap, resolveHandle, "searchPaths");
		if (sp.length > 0) { rs.searchPaths = sp; }
		const ext = extractStringArray(heap, ctx.arrayHeap, resolveHandle, "extensions");
		if (ext.length > 0) { rs.extensions = ext; }
		// Alias extraction deferred — requires field iteration API
	}

	const bs: BuildSection = { target: bsTarget, outDir: bsOutDir, outFile: bsOutFile, optimize: bsOptimize };
	return { root, build: bs, resolve: rs, valid: true };
	*/
}
