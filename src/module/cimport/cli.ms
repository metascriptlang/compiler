// cparse — Standalone CLI entry
//
// Usage:
//   bun run run-ms run src/compiler/cparse/main.ms -- <header.h> [options]
//
// Options:
//   --target=<triple>   linux-x86_64 | linux-aarch64 | macos-x86_64 |
//                       macos-aarch64 | windows-x64 | wasm32
//   --export            prepend `export ` to each emitted decl
//   -I<dir>             add include search path
//   -D<name[=value]>    predefine macro
//   --names=a,b,c       restrict emitted decls to this whitelist
//
// Runs fully standalone. No dependency on the main compiler pipeline.
// Useful during porting to iterate on tokenizer/preprocessor/parser
// without rebuilding the whole compiler.

import { parseHeader, defaultOptions, ParseOptions } from "./index";
import {
	TargetInfo,
	targetLinuxX86_64, targetLinuxAarch64,
	targetMacosX86_64, targetMacosAarch64,
	targetWindowsX64, targetWasm32,
} from "./target";

function resolveTarget(name: string): TargetInfo {
	return match (name) {
		"linux-x86_64" => targetLinuxX86_64(),
		"linux-aarch64" => targetLinuxAarch64(),
		"macos-x86_64" => targetMacosX86_64(),
		"macos-aarch64" => targetMacosAarch64(),
		"windows-x64" => targetWindowsX64(),
		"wasm32" => targetWasm32(),
		_ => targetMacosAarch64(),
	};
}

export function runCli(args: string[]): number {
	let headerPath = "";
	const opts = defaultOptions();

	for (const a of args) {
		if (a.startsWith("--target=")) {
			opts.target = resolveTarget(a.slice(9, a.length));
		} else if (a === "--export") {
			opts.emit.withExport = true;
		} else if (a.startsWith("-I")) {
			opts.includePaths.push(a.slice(2, a.length));
		} else if (a.startsWith("-D")) {
			opts.extraDefines.push(a.slice(2, a.length));
		} else if (a.startsWith("--names=")) {
			const list = a.slice(8, a.length);
			opts.emit.importedNames = list.split(",");
		} else if (!a.startsWith("-")) {
			headerPath = a;
		}
	}

	if (headerPath === "") {
		console.log("usage: cparse <header.h> [--target=...] [-I...] [-D...] [--export] [--names=a,b]");
		return 1;
	}

	// File I/O via MS standard runtime. For now we delegate to the caller —
	// wire with std/io once the rest of the pipeline exists.
	// TODO: read file bytes here.
	const source = "";

	const out = parseHeader(source, headerPath, opts);
	console.log(out.msSource);
	for (const d of out.diagnostics) {
		console.log(`${d.file}:${d.line}:${d.col}: ${d.message}`);
	}
	return out.diagnostics.length === 0 ? 0 : 2;
}
