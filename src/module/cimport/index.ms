// cparse — Public API
//
// Two entry points:
//   1. parseHeader(source, path, opts) → ParseOutput (sync, single header)
//   2. parseHeaders(loaded[], opts, cache, sink) → ParseOutput[] (parallel, spawn + actors)
//
// Pure C parsing only — no MetaScript-specific emit.
// Returns Obj[] and diagnostics. The C→MS emitter is a separate consumer.
//
// Concurrent architecture:
//   - HeaderCache actor deduplicates #include expansion across jobs
//   - DiagnosticSink actor merges diagnostics deterministically
//   - Per-header parse runs on spawn() workers via Promise.all

import { tokenizeFile } from "../cparse/tokenize";
import { preprocess } from "../cparse/preprocess";
import { parseTranslationUnit } from "../cparse/parse";
import { Obj } from "../cparse/obj";
import { TargetInfo, defaultHostTarget } from "../cparse/target";
import { Diagnostic } from "../cparse/error";
import { HeaderCache } from "./cache";
import { DiagnosticSink } from "./sink";

export interface ParseOptions {
	target: TargetInfo;
	includePaths: string[];
	extraDefines: string[];
}

export interface ParseOutput {
	objs: Obj[];
	diagnostics: Diagnostic[];
}

export interface LoadedHeader {
	path: string;
	source: string;
}

export function defaultOptions(): ParseOptions {
	return {
		target: defaultHostTarget(),
		includePaths: [],
		extraDefines: [],
	};
}

// Single-header entry. Synchronous; heavy work on caller thread.
export function parseHeader(
	source: string,
	path: string,
	opts: ParseOptions
): ParseOutput {
	const diagnostics: Diagnostic[] = [];

	const tok = tokenizeFile(source, path);
	for (const d of tok.diagnostics) diagnostics.push(d);

	const pp = preprocess(tok.head, opts.target, opts.includePaths);
	for (const d of pp.diagnostics) diagnostics.push(d);

	const parsed = parseTranslationUnit(pp.head, opts.target);
	for (const d of parsed.diagnostics) diagnostics.push(d);

	return { objs: parsed.objs, diagnostics };
}

// Bulk entry. Each header runs on a worker via spawn(); shared
// HeaderCache actor memoizes #include results across jobs; shared
// DiagnosticSink merges diagnostics into deterministic order.
//
// NOTE: blocked on Promise.all stdlib generic refactor. Leaving the
// idiomatic parallel shape in place so no syntax rewrite is needed
// once the refactor lands.
export async function parseHeaders(
	loaded: LoadedHeader[],
	opts: ParseOptions,
	cache: HeaderCache,
	sink: DiagnosticSink
): Promise<ParseOutput[]> {
	const jobs: Promise<ParseOutput>[] = [];
	for (const item of loaded) {
		jobs.push(spawn(() => {
			const out = parseHeader(item.source, item.path, opts);
			if (out.diagnostics.length > 0) sink.reportAll(move out.diagnostics);
			return out;
		}));
	}
	return await Promise.all(jobs);
}
