// cparse — Public API
//
// parseHeader(source, path, opts) → ParseOutput: tokenize → preprocess →
// parse one C header, collecting diagnostics from all three phases.
//
// Pure C parsing only — no MetaScript-specific emit. The C→MS emitter
// (emit.ms translateCHeader) is the consumer.

import { tokenizeFile } from "../cparse/tokenize";
import { preprocess } from "../cparse/preprocess";
import { parseTranslationUnit } from "../cparse/parse";
import { Obj } from "../cparse/obj";
import { TargetInfo, defaultHostTarget } from "../cparse/target";
import { Diagnostic } from "../cparse/error";

export interface ParseOptions {
	target: TargetInfo;
	includePaths: string[];
	extraDefines: string[];
}

export interface ParseOutput {
	objs: Obj[];
	diagnostics: Diagnostic[];
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
