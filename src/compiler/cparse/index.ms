// cparse — Public API
//
// Two entry points:
//   1. parseHeader(path, target, opts) → MS source string  (single header)
//   2. parseHeaders(paths, target, opts) → string[]        (parallel, spawn + actors)
//
// Concurrent architecture:
//   - HeaderCache actor deduplicates #include expansion across jobs
//   - DiagnosticSink actor merges diagnostics deterministically
//   - Per-header parse runs on spawn() workers via Promise.all

import { tokenizeFile } from "./tokenize";
import { preprocess } from "./preprocess";
import { parseTranslationUnit } from "./parse";
import { emitMetaScript, EmitOptions } from "./emit";
import { TargetInfo, defaultHostTarget } from "./target";
import { Diagnostic } from "./error";
import { HeaderCache } from "./cache";
import { DiagnosticSink } from "./sink";

export { TargetInfo, defaultHostTarget } from "./target";
export { Diagnostic, DiagSeverity } from "./error";
// HeaderCache + DiagnosticSink are exported inline via `export actor` in their
// own files — importers should `import { HeaderCache } from "./cache"` etc.
// Re-exporting actors from a barrel file can cause duplicate class emission
// in C codegen, so we keep them pinned to their source modules.

export interface ParseOptions {
	target: TargetInfo;
	includePaths: string[];
	extraDefines: string[];        // "-D" equivalents, "NAME=value" or "NAME"
	emit: EmitOptions;
}

export interface ParseOutput {
	msSource: string;
	diagnostics: Diagnostic[];
}

// One loaded header file as an input to parseHeaders. The caller is
// responsible for reading the file bytes (std/fs) — this module does not
// touch the filesystem, which keeps it unit-testable without fixtures.
export interface LoadedHeader {
	path: string;
	source: string;
}

export function defaultOptions(): ParseOptions {
	return {
		target: defaultHostTarget(),
		includePaths: [],
		extraDefines: [],
		emit: { withExport: false, importedNames: [] },
	};
}

// Single-header entry. Synchronous shape; heavy work on caller thread.
// For multi-header bulk binding use parseHeaders (spawns per-header).
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

	const msSource = emitMetaScript(parsed.objs, opts.emit);
	return { msSource, diagnostics };
}

// Bulk binding entry. Each header runs on a worker via spawn(); shared
// HeaderCache actor memoizes #include results across jobs; shared
// DiagnosticSink merges diagnostics into deterministic order.
//
// Callers typically do:
//
//     const cache = new HeaderCache();
//     const sink = new DiagnosticSink();
//     const sources = await parseHeaders(loaded, opts, cache, sink);
//     const diags = await sink.flush();
//
// `loaded` is an array of LoadedHeader the caller has already read from disk.
// File I/O is the caller's responsibility — we don't touch the filesystem
// here, which keeps the module fully unit-testable.
//
// NOTE: currently blocked on Promise.all stdlib generic refactor — the
// signature `all(Promise<void>[]): Promise<void>` drops the element type,
// so this function fails type checking until Promise is redesigned. Leaving
// the idiomatic parallel shape in place so no syntax rewrite is needed
// once the refactor lands. Iteration loop uses `bun run run-ms` in the
// meantime; self-hosted build unblocks with the Promise refactor.
export async function parseHeaders(
	loaded: LoadedHeader[],
	opts: ParseOptions,
	cache: HeaderCache,
	sink: DiagnosticSink
): Promise<string[]> {
	const jobs: Promise<string>[] = [];
	for (const item of loaded) {
		// Capture by const → eligible for SHARE (Rule 3) across workers.
		// opts.target is immutable after construction; cache/sink are actors.
		jobs.push(spawn(() => {
			const out = parseHeader(item.source, item.path, opts);
			// Transfer diagnostics into the sink's mailbox. `move` invalidates
			// out.diagnostics on our side — we don't touch it afterwards, only
			// out.msSource, which is a distinct string field.
			if (out.diagnostics.length > 0) sink.reportAll(move out.diagnostics);
			return out.msSource;
		}));
	}
	return await Promise.all(jobs);
}
