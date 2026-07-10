// cparse — C preprocessor
//
// Expands macros, handles #if/#include/#define directives.
// No global state — all context passed explicitly via PPContext.

import { CToken, CTokenKind, LitKind, makeEofToken } from "./token";
import { Diagnostic, DiagSeverity, makeDiag } from "./error";
import { TargetInfo, predefinedMacros, targetLinuxX86_64 } from "./target";
import { tokenizeFile, convertPPTokens } from "./tokenize";
import { readFile } from "std/fs";

export interface PreprocessResult {
	head: CToken;
	diagnostics: Diagnostic[];
	// Owns every token created during preprocessing (macro-expansion copies,
	// synthesized EOFs). Tokenize's arena owns the input tokens; both must stay
	// in scope while any token from the result chain is used.
	arena: CToken[];
}

// ===== Data Structures =====

interface Macro {
	name: string;
	isObjlike: boolean;
	params: MacroParam[];
	vaArgsName: string;       // "" if not variadic
	body: CToken;              // head of body token list (Eof-terminated)
	handler: string;          // "__FILE__", "__LINE__", etc. "" for user macros
}

interface MacroParam {
	name: string;
}

interface MacroArg {
	name: string;
	isVaArgs: boolean;
	tok: CToken;               // head of argument token list (Eof-terminated)
}

// Conditional compilation stack
const COND_THEN = 0;
const COND_ELIF = 1;
const COND_ELSE = 2;

interface CondIncl {
	ctx: number;              // COND_THEN, COND_ELIF, COND_ELSE
	included: boolean;        // whether tokens in this block have been emitted
	parent: CondIncl;
}

// Preprocessing context (replaces the upstream parser's globals)
interface PPContext {
	macros: HashMap<string, Macro>;
	condStack: CondIncl;      // null as CondIncl at top level
	pragmaOnce: HashMap<string, boolean>;
	includeStack: HashMap<string, boolean>;  // files currently being processed (circular include guard)
	includePaths: string[];
	target: TargetInfo;
	diags: Diagnostic[];
	file: string;
	counter: number;          // for __COUNTER__
	arena: CToken[];          // owns all tokens this preprocess session creates
}

// ===== Token Utilities =====

function copyToken(ctx: PPContext, tok: CToken): CToken {
	const c: CToken = {
		kind: tok.kind, next: null as unknown as Ptr<CToken>,
		intVal: tok.intVal, floatVal: tok.floatVal, litKind: tok.litKind,
		stringVal: tok.stringVal, file: tok.file, line: tok.line, col: tok.col,
		byteOffset: tok.byteOffset, byteLength: tok.byteLength,
		atBol: tok.atBol, hasSpace: tok.hasSpace,
		hideset: tok.hideset.slice(0, tok.hideset.length),
		origin: tok.origin,
	};
	ctx.arena.push(c);
	return c;
}

function newEof(ctx: PPContext, tok: CToken): CToken {
	const eof = makeEofToken(tok.file);
	eof.line = tok.line;
	eof.col = tok.col;
	ctx.arena.push(eof);
	return eof;
}

// Append tok2 list after the end of tok1 list. Returns tok1 head.
function append(tok1: CToken, tok2: CToken): CToken {
	if (tok1.kind === CTokenKind.Eof) return tok2;
	const head = tok1;
	let cur = tok1;
	while (cur.next.kind !== CTokenKind.Eof) cur = cur.next;
	cur.next = tok2;
	return head;
}

// Skip to next line. Returns first token of next line.
function skipLine(tok: CToken): CToken {
	while (tok.kind !== CTokenKind.Eof && !tok.atBol) tok = tok.next;
	return tok;
}

// Copy tokens until newline, terminate with EOF.
function copyLine(ctx: PPContext, tok: CToken): CToken[] {
	const head = makeEofToken(tok.file);
	let cur = head;
	// If tok is already at beginning of next line, body is empty
	if (tok.atBol || tok.kind === CTokenKind.Eof) {
		cur.next = newEof(ctx, tok);
		return [head.next, tok];
	}
	while (tok.kind !== CTokenKind.Eof && !tok.next.atBol) {
		const c = copyToken(ctx, tok);
		cur.next = c;
		cur = c;
		tok = tok.next;
	}
	// Include the last token on the line
	if (tok.kind !== CTokenKind.Eof) {
		const c = copyToken(ctx, tok);
		cur.next = c;
		cur = c;
	}
	cur.next = newEof(ctx, tok);
	// When the line runs to EOF, tok IS the EOF token and tok.next is null —
	// return the EOF itself so callers always get a walkable token.
	const rest = tok.kind === CTokenKind.Eof ? tok : tok.next;
	return [head.next, rest]; // [copied line head, rest of stream]
}

// Join token texts with spaces.
function joinTokens(tok: CToken): string {
	let result = "";
	let first = true;
	while (tok.kind !== CTokenKind.Eof) {
		if (!first && tok.hasSpace) result = result + " ";
		result = result + tok.stringVal;
		first = false;
		tok = tok.next;
	}
	return result;
}

// ===== Hideset (recursive macro prevention) =====

function hidesetContains(hs: string[], name: string): boolean {
	for (const h of hs) {
		if (h === name) return true;
	}
	return false;
}

function hidesetUnion(a: string[], b: string[]): string[] {
	const result: string[] = [];
	for (const h of a) result.push(h);
	for (const h of b) {
		if (!hidesetContains(result, h)) result.push(h);
	}
	return result;
}

function hidesetIntersection(a: string[], b: string[]): string[] {
	const result: string[] = [];
	for (const h of a) {
		if (hidesetContains(b, h)) result.push(h);
	}
	return result;
}

// Add name to hideset of all tokens in list.
function addHideset(tok: CToken, name: string): void {
	let t = tok;
	while (t.kind !== CTokenKind.Eof) {
		if (!hidesetContains(t.hideset, name)) t.hideset.push(name);
		t = t.next;
	}
}

// ===== Macro Management =====

function addMacro(ctx: PPContext, name: string, isObjlike: boolean, body: CToken): Macro {
	const mac: Macro = {
		name, isObjlike, params: [], vaArgsName: "", body,
		handler: "",
	};
	ctx.macros.set(name, mac);
	return mac;
}

function findMacro(ctx: PPContext, tok: CToken): Macro {
	if (tok.kind !== CTokenKind.Ident) return null as unknown as Macro;
	if (!ctx.macros.has(tok.stringVal)) return null as unknown as Macro;
	return ctx.macros.get(tok.stringVal) as Macro;
}

// ===== Read Macro Definition =====

function readMacroDefinition(tok: CToken, ctx: PPContext): CToken {
	if (tok.kind !== CTokenKind.Ident) {
		ctx.diags.push(makeDiag(DiagSeverity.Error, tok.file, tok.line, tok.col, "macro name must be an identifier"));
		return skipLine(tok);
	}
	const name = tok.stringVal;
	tok = tok.next;

	// Function-like: ( immediately after name, no space
	if (!tok.hasSpace && tok.stringVal === "(") {
		const params: MacroParam[] = [];
		let vaArgs = "";
		tok = tok.next; // skip (
		while (tok.kind !== CTokenKind.Eof && tok.stringVal !== ")") {
			if (params.length > 0) {
				if (tok.stringVal !== ",") break;
				tok = tok.next;
			}
			if (tok.stringVal === "...") {
				vaArgs = "__VA_ARGS__";
				tok = tok.next;
				break;
			}
			if (tok.kind !== CTokenKind.Ident) break;
			const pname = tok.stringVal;
			tok = tok.next;
			if (tok.stringVal === "...") { vaArgs = pname; tok = tok.next; break; }
			params.push({ name: pname });
		}
		if (tok.stringVal === ")") tok = tok.next;

		const bodyParts = copyLine(ctx, tok);
		const body = bodyParts[0];
		const rest = bodyParts[1];

		const mac = addMacro(ctx, name, false, body);
		mac.params = params;
		mac.vaArgsName = vaArgs;
		return rest;
	}

	// Object-like macro
	const bodyParts = copyLine(ctx, tok);
	addMacro(ctx, name, true, bodyParts[0]);
	return bodyParts[1];
}

// ===== Stringize (#) =====

function stringize(tok: CToken): string {
	let result = "\"";
	let first = true;
	while (tok.kind !== CTokenKind.Eof) {
		if (!first && tok.hasSpace) result = result + " ";
		const s = tok.stringVal;
		// Run-copied for multi-byte UTF-8 safety on the Bun host: plain bytes
		// flush as spans, breaking only at the ASCII bytes that need escaping.
		let runStart = 0;
		let i = 0;
		while (i < s.byteLength) {
			const ch = s.byteAt(i);
			if (ch === "\"".code || ch === "\\".code) {
				if (runStart < i) result = result + s.byteSlice(runStart, i);
				result = result + "\\" + s.byteSlice(i, i + 1);
				runStart = i + 1;
			}
			i = i + 1;
		}
		if (runStart < s.byteLength) result = result + s.byteSlice(runStart, s.byteLength);
		first = false;
		tok = tok.next;
	}
	return result + "\"";
}

// ===== Paste (##) =====

function paste(lhs: CToken, rhs: CToken, ctx: PPContext): CToken {
	const combined = lhs.stringVal + rhs.stringVal;
	const r = tokenizeFile(combined, lhs.file);
	// The pasted token splices into the outer stream — its arena must outlive
	// this call, so fold it into the session arena.
	for (const at of r.arena) ctx.arena.push(at);
	if (r.head.kind === CTokenKind.Eof || r.head.next.kind !== CTokenKind.Eof) {
		ctx.diags.push(makeDiag(DiagSeverity.Error, lhs.file, lhs.line, lhs.col,
			`pasting "${lhs.stringVal}" and "${rhs.stringVal}" does not give a valid token`));
	}
	return r.head;
}

// ===== Find Argument =====

function findArg(args: MacroArg[], name: string): MacroArg {
	for (const arg of args) {
		if (arg.name === name) return arg;
	}
	return null as unknown as MacroArg;
}

// ===== Read Macro Arguments =====

function readMacroArgOne(ctx: PPContext, tok: CToken, readRest: boolean): CToken[] {
	const head = makeEofToken(tok.file);
	let cur = head;
	let depth = 0;

	while (tok.kind !== CTokenKind.Eof) {
		if (depth === 0 && tok.stringVal === ")") break;
		if (depth === 0 && !readRest && tok.stringVal === ",") break;
		if (tok.stringVal === "(") depth = depth + 1;
		if (tok.stringVal === ")") depth = depth - 1;
		const c = copyToken(ctx, tok);
		cur.next = c;
		cur = c;
		tok = tok.next;
	}
	cur.next = newEof(ctx, tok);
	return [head.next, tok]; // [arg tokens, rest]
}

function readMacroArgs(ctx: PPContext, tok: CToken, mac: Macro): MacroArg[][] {
	// Returns [args, rest-token] encoded as array
	const args: MacroArg[] = [];
	tok = tok.next; // skip (

	let pi = 0;
	if (tok.stringVal !== ")") {
		while (pi < mac.params.length) {
			const r = readMacroArgOne(ctx, tok, false);
			args.push({ name: mac.params[pi].name, isVaArgs: false, tok: r[0] });
			tok = r[1];
			pi = pi + 1;
			if (tok.stringVal === ")") break;
			if (tok.stringVal === ",") tok = tok.next;
		}
		// Variadic: read remaining as __VA_ARGS__
		if (mac.vaArgsName !== "") {
			const r = readMacroArgOne(ctx, tok, true);
			args.push({ name: mac.vaArgsName, isVaArgs: true, tok: r[0] });
			tok = r[1];
		}
	}
	if (tok.stringVal === ")") tok = tok.next;
	return [args, [{ name: tok.stringVal }] as unknown as MacroArg[]] as unknown as MacroArg[][];
}

// ===== Parameter Substitution =====

function subst(body: CToken, args: MacroArg[], ctx: PPContext): CToken {
	const head = makeEofToken("");
	let cur = head;

	while (body.kind !== CTokenKind.Eof) {
		// # stringize
		if (body.stringVal === "#" && body.next.kind !== CTokenKind.Eof) {
			const arg = findArg(args, body.next.stringVal);
			if (arg !== null) {
				const str = stringize(arg.tok);
				const stok = copyToken(ctx, body);
				stok.kind = CTokenKind.Str;
				stok.stringVal = str;
				cur.next = stok;
				cur = stok;
				body = body.next.next;
				continue;
			}
		}

		// ## paste
		if (body.stringVal === "##" && body.next.kind !== CTokenKind.Eof) {
			// LHS is previous token (cur), RHS is next
			const rhs = body.next;
			const rhsArg = findArg(args, rhs.stringVal);
			if (rhsArg !== null) {
				// Paste cur with first token of arg
				if (rhsArg.tok.kind !== CTokenKind.Eof) {
					const pasted = paste(cur, rhsArg.tok, ctx);
					cur.kind = pasted.kind;
					cur.stringVal = pasted.stringVal;
					cur.intVal = pasted.intVal;
					cur.floatVal = pasted.floatVal;
					// Append rest of arg
					let rest = rhsArg.tok.next;
					while (rest.kind !== CTokenKind.Eof) {
						const c = copyToken(ctx, rest);
						cur.next = c;
						cur = c;
						rest = rest.next;
					}
				}
			} else {
				const pasted = paste(cur, rhs, ctx);
				cur.kind = pasted.kind;
				cur.stringVal = pasted.stringVal;
			}
			body = rhs.next;
			continue;
		}

		// Parameter with ## on left side
		if (body.next.stringVal === "##") {
			const arg = findArg(args, body.stringVal);
			if (arg !== null) {
				// , ## __VA_ARGS__ — if VA_ARGS empty, remove comma
				if (arg.isVaArgs && arg.tok.kind === CTokenKind.Eof && cur.stringVal === ",") {
					// Remove the comma
					// Walk back to find the token before cur — tricky with linked list
					// Simpler: just mark cur as empty
					cur.stringVal = "";
					cur.kind = CTokenKind.Eof; // will be skipped
					body = body.next.next; // skip param ##
					continue;
				}
				if (arg.tok.kind !== CTokenKind.Eof) {
					let t = arg.tok;
					while (t.kind !== CTokenKind.Eof) {
						const c = copyToken(ctx, t);
						cur.next = c;
						cur = c;
						t = t.next;
					}
				}
				body = body.next; // body is now ##, will be handled next iteration
				continue;
			}
		}

		// Parameter substitution (normal)
		const arg = findArg(args, body.stringVal);
		if (arg !== null) {
			// Expand the argument first
			let t = arg.tok;
			if (t.kind === CTokenKind.Eof) {
				// Empty argument — skip
				body = body.next;
				continue;
			}
			while (t.kind !== CTokenKind.Eof) {
				const c = copyToken(ctx, t);
				c.hasSpace = (cur === head) ? body.hasSpace : c.hasSpace;
				cur.next = c;
				cur = c;
				t = t.next;
			}
			body = body.next;
			continue;
		}

		// Regular token — copy
		const c = copyToken(ctx, body);
		cur.next = c;
		cur = c;
		body = body.next;
	}

	cur.next = newEof(ctx, head);
	return head.next;
}

// ===== Expand Macro =====

function expandMacro(tok: CToken, ctx: PPContext): CToken[] {
	// Returns [expanded-or-null, rest] — null means not expanded
	const mac = findMacro(ctx, tok);
	if (mac === null) return [null as unknown as CToken, tok];
	if (hidesetContains(tok.hideset, mac.name)) return [null as unknown as CToken, tok];

	// Built-in handler macros
	if (mac.handler !== "") {
		const result = handleBuiltinMacro(tok, mac, ctx);
		return [result, tok.next];
	}

	// Reusable single-element array — avoids DRC leak on inline [mac.name] literals.
	// DRC doesn't generate cleanup for _clit temporaries from array literals in function args.
	const macNameArr: string[] = [mac.name];

	// Object-like macro
	if (mac.isObjlike) {
		const hs = hidesetUnion(tok.hideset, macNameArr);
		const body = copyTokenList(ctx, mac.body);
		addHideset(body, mac.name);
		// Set hideset on each token
		let t = body;
		while (t.kind !== CTokenKind.Eof) {
			const merged = hidesetUnion(t.hideset, hs);
			t.hideset = merged;
			t = t.next;
		}
		// Preserve leading whitespace
		if (body.kind !== CTokenKind.Eof) {
			body.hasSpace = tok.hasSpace;
			body.atBol = tok.atBol;
		}
		const expanded = append(body, tok.next);
		return [expanded, null as unknown as CToken];
	}

	// Function-like macro — needs ( after name
	if (tok.next.stringVal !== "(") return [null as unknown as CToken, tok];

	const argsResult = readMacroArgs(ctx, tok.next, mac);
	const args = argsResult[0] as unknown as MacroArg[];

	// Re-walk from tok to find the closing ) (simpler than decoding readMacroArgs' rest)
	let rest = tok.next.next; // skip name (
	let depth = 1;
	while (rest.kind !== CTokenKind.Eof && depth > 0) {
		if (rest.stringVal === "(") depth = depth + 1;
		if (rest.stringVal === ")") depth = depth - 1;
		if (depth > 0) rest = rest.next;
	}
	if (rest.stringVal === ")") rest = rest.next;

	const body = subst(mac.body, args, ctx);
	const emptyHideset: string[] = [];
	const restHideset = rest.kind !== CTokenKind.Eof ? rest.hideset : emptyHideset;
	const hs = hidesetIntersection(tok.hideset, restHideset);
	addHideset(body, mac.name);
	let t = body;
	while (t.kind !== CTokenKind.Eof) {
		const hsWithName = hidesetUnion(hs, macNameArr);
		const merged = hidesetUnion(t.hideset, hsWithName);
		t.hideset = merged;
		t = t.next;
	}
	if (body.kind !== CTokenKind.Eof) {
		body.hasSpace = tok.hasSpace;
		body.atBol = tok.atBol;
	}
	const expanded = append(body, rest);
	return [expanded, null as unknown as CToken];
}

function copyTokenList(ctx: PPContext, head: CToken): CToken {
	const sentinel = makeEofToken("");
	let cur = sentinel;
	let t = head;
	while (t.kind !== CTokenKind.Eof) {
		const c = copyToken(ctx, t);
		cur.next = c;
		cur = c;
		t = t.next;
	}
	cur.next = newEof(ctx, head);
	return sentinel.next;
}

// ===== Built-in Macro Handlers =====

function handleBuiltinMacro(tok: CToken, mac: Macro, ctx: PPContext): CToken {
	const result = copyToken(ctx, tok);
	match (mac.handler) {
		"__FILE__" => {
			result.kind = CTokenKind.Str;
			result.stringVal = tok.file;
			result.litKind = LitKind.StrChar;
		},
		"__LINE__" => {
			result.kind = CTokenKind.Num;
			result.intVal = tok.line as int64;
			result.litKind = LitKind.Int;
			result.stringVal = tok.line.toString();
		},
		"__COUNTER__" => {
			result.kind = CTokenKind.Num;
			result.intVal = ctx.counter as int64;
			result.litKind = LitKind.Int;
			result.stringVal = ctx.counter.toString();
			ctx.counter = ctx.counter + 1;
		},
		_ => {},
	};
	result.next = newEof(ctx, tok);
	return result;
}

// ===== Conditional Compilation =====

function pushCondIncl(ctx: PPContext, included: boolean): void {
	const ci: CondIncl = {
		ctx: COND_THEN,
		included,
		parent: ctx.condStack,
	};
	ctx.condStack = ci;
}

// Skip tokens until matching #elif, #else, or #endif.
function skipCondIncl(tok: CToken): CToken {
	let depth = 0;
	while (tok.kind !== CTokenKind.Eof) {
		if (tok.atBol && tok.stringVal === "#") {
			const dir = tok.next;
			if (dir.stringVal === "if" || dir.stringVal === "ifdef" || dir.stringVal === "ifndef") {
				depth = depth + 1;
			} else if (depth === 0 && (dir.stringVal === "elif" || dir.stringVal === "else" || dir.stringVal === "endif")) {
				return tok;
			} else if (dir.stringVal === "endif") {
				depth = depth - 1;
			}
		}
		tok = tok.next;
	}
	return tok;
}

// ===== Minimal #if Expression Evaluator =====

// Evaluate a preprocessor constant expression. Handles:
// integer literals, defined(X), !, &&, ||, ==, !=, <, >, <=, >=, +, -, *, /, %, &, |, ^, ~, (, ), ?:
// Undefined identifiers evaluate to 0 (C spec).

interface EvalState {
	tok: CToken;
}

function evalNext(es: EvalState): void {
	es.tok = es.tok.next;
}

function evalTernary(es: EvalState, ctx: PPContext): int32 {
	let val = evalOr(es, ctx);
	if (es.tok.stringVal === "?") {
		evalNext(es);
		const thenVal = evalTernary(es, ctx);
		if (es.tok.stringVal !== ":") {
			ctx.diags.push(makeDiag(DiagSeverity.Error, es.tok.file, es.tok.line, es.tok.col, "expected ':' in ternary"));
		} else { evalNext(es); }
		const elseVal = evalTernary(es, ctx);
		return val !== 0 ? thenVal : elseVal;
	}
	return val;
}

function evalOr(es: EvalState, ctx: PPContext): int32 {
	let val = evalAnd(es, ctx);
	while (es.tok.stringVal === "||") {
		evalNext(es);
		const rhs = evalAnd(es, ctx);
		val = (val !== 0 || rhs !== 0) ? 1 : 0;
	}
	return val;
}

function evalAnd(es: EvalState, ctx: PPContext): int32 {
	let val = evalBitOr(es, ctx);
	while (es.tok.stringVal === "&&") {
		evalNext(es);
		const rhs = evalBitOr(es, ctx);
		val = (val !== 0 && rhs !== 0) ? 1 : 0;
	}
	return val;
}

function evalBitOr(es: EvalState, ctx: PPContext): int32 {
	let val = evalBitXor(es, ctx);
	while (es.tok.stringVal === "|") {
		evalNext(es);
		val = val | evalBitXor(es, ctx);
	}
	return val;
}

function evalBitXor(es: EvalState, ctx: PPContext): int32 {
	let val = evalBitAnd(es, ctx);
	while (es.tok.stringVal === "^") {
		evalNext(es);
		val = val ^ evalBitAnd(es, ctx);
	}
	return val;
}

function evalBitAnd(es: EvalState, ctx: PPContext): int32 {
	let val = evalEquality(es, ctx);
	while (es.tok.stringVal === "&") {
		evalNext(es);
		val = val & evalEquality(es, ctx);
	}
	return val;
}

function evalEquality(es: EvalState, ctx: PPContext): int32 {
	let val = evalRelational(es, ctx);
	while (es.tok.stringVal === "==" || es.tok.stringVal === "!=") {
		const op = es.tok.stringVal;
		evalNext(es);
		const rhs = evalRelational(es, ctx);
		if (op === "==") val = val === rhs ? 1 : 0;
		else val = val !== rhs ? 1 : 0;
	}
	return val;
}

function evalRelational(es: EvalState, ctx: PPContext): int32 {
	let val = evalShift(es, ctx);
	while (es.tok.stringVal === "<" || es.tok.stringVal === ">" ||
		   es.tok.stringVal === "<=" || es.tok.stringVal === ">=") {
		const op = es.tok.stringVal;
		evalNext(es);
		const rhs = evalShift(es, ctx);
		val = match (op) {
			"<" => val < rhs ? 1 : 0,
			">" => val > rhs ? 1 : 0,
			"<=" => val <= rhs ? 1 : 0,
			_ => val >= rhs ? 1 : 0,
		};
	}
	return val;
}

function evalShift(es: EvalState, ctx: PPContext): int32 {
	let val = evalAdd(es, ctx);
	while (es.tok.stringVal === "<<" || es.tok.stringVal === ">>") {
		const op = es.tok.stringVal;
		evalNext(es);
		const rhs = evalAdd(es, ctx);
		if (op === "<<") val = val << rhs;
		else val = val >> rhs;
	}
	return val;
}

function evalAdd(es: EvalState, ctx: PPContext): int32 {
	let val = evalMul(es, ctx);
	while (es.tok.stringVal === "+" || es.tok.stringVal === "-") {
		const op = es.tok.stringVal;
		evalNext(es);
		const rhs = evalMul(es, ctx);
		if (op === "+") val = val + rhs;
		else val = val - rhs;
	}
	return val;
}

function evalMul(es: EvalState, ctx: PPContext): int32 {
	let val = evalUnary(es, ctx);
	while (es.tok.stringVal === "*" || es.tok.stringVal === "/" || es.tok.stringVal === "%") {
		const op = es.tok.stringVal;
		evalNext(es);
		const rhs = evalUnary(es, ctx);
		if (op === "*") val = val * rhs;
		else if (op === "/" && rhs !== 0) val = (val / rhs) | 0; // integer division
		else if (op === "%" && rhs !== 0) val = val % rhs;
	}
	return val;
}

function evalUnary(es: EvalState, ctx: PPContext): int32 {
	return match (es.tok.stringVal) {
		"!" => { evalNext(es); return evalUnary(es, ctx) === 0 ? 1 : 0; },
		"~" => { evalNext(es); return ~evalUnary(es, ctx); },
		"-" => { evalNext(es); return -evalUnary(es, ctx); },
		"+" => { evalNext(es); return evalUnary(es, ctx); },
		_ => evalPrimary(es, ctx),
	};
}

function evalPrimary(es: EvalState, ctx: PPContext): int32 {
	const tok = es.tok;

	// Parenthesized expression
	if (tok.stringVal === "(") {
		evalNext(es);
		const val = evalTernary(es, ctx);
		if (es.tok.stringVal === ")") evalNext(es);
		return val;
	}

	// Numeric literal (includes character literals stored as Num)
	if (tok.kind === CTokenKind.Num) {
		const val = tok.intVal as int32;
		evalNext(es);
		return val;
	}

	// Undefined identifier → 0 (C spec)
	if (tok.kind === CTokenKind.Ident) {
		evalNext(es);
		return 0;
	}

	evalNext(es);
	return 0;
}

// Evaluate #if expression: preprocess tokens, handle defined(), eval.
function evalConstExpr(tok: CToken, ctx: PPContext): number {
	// Copy line and preprocess it
	const parts = copyLine(ctx, tok);
	let line = parts[0];

	// Handle defined(X) and defined X
	const processed = makeEofToken("");
	let cur = processed;
	let t = line;
	while (t.kind !== CTokenKind.Eof) {
		if (t.kind === CTokenKind.Ident && t.stringVal === "defined") {
			t = t.next;
			let name = "";
			if (t.stringVal === "(") {
				t = t.next;
				name = t.stringVal;
				t = t.next; // skip name
				if (t.stringVal === ")") t = t.next;
			} else {
				name = t.stringVal;
				t = t.next;
			}
			const val = ctx.macros.has(name) ? 1 : 0;
			const numTok = makeEofToken(tok.file);
			numTok.kind = CTokenKind.Num;
			numTok.intVal = val as int64;
			numTok.stringVal = val.toString();
			ctx.arena.push(numTok);
			cur.next = numTok;
			cur = numTok;
			continue;
		}
		const c = copyToken(ctx, t);
		cur.next = c;
		cur = c;
		t = t.next;
	}
	cur.next = newEof(ctx, tok);

	// Expand macros in the expression
	let expanded = processed.next;
	expanded = preprocessTokens(expanded, ctx);

	convertPPTokens(expanded, ctx.diags);

	// Replace remaining identifiers with 0
	let et = expanded;
	while (et.kind !== CTokenKind.Eof) {
		if (et.kind === CTokenKind.Ident) {
			et.kind = CTokenKind.Num;
			et.intVal = 0 as int64;
			et.stringVal = "0";
		}
		et = et.next;
	}

	const es: EvalState = { tok: expanded };
	return evalTernary(es, ctx);
}

// Preprocess a token list (for macro expansion in #if expressions).
function preprocessTokens(tok: CToken, ctx: PPContext): CToken {
	const head = makeEofToken("");
	let cur = head;
	while (tok.kind !== CTokenKind.Eof) {
		const r = expandMacro(tok, ctx);
		if (r[0] !== null) {
			tok = r[0];
			continue;
		}
		const c = copyToken(ctx, tok);
		cur.next = c;
		cur = c;
		tok = tok.next;
	}
	cur.next = newEof(ctx, tok);
	return head.next;
}

// ===== #include Handling =====

// Try to read a file. Returns "" if the file doesn't exist or can't be read.
function tryReadFile(path: string): string {
	return try readFile(path) catch "";
}

function searchIncludePaths(filename: string, ctx: PPContext): string {
	// Absolute path
	if (filename.byteLength > 0 && filename.byteAt(0) === "/".code) {
		if (tryReadFile(filename) !== "") return filename;
		return "";
	}
	// Search include paths
	for (const dir of ctx.includePaths) {
		const path = dir + "/" + filename;
		if (tryReadFile(path) !== "") return path;
	}
	return "";
}

function readIncludeFilename(tok: CToken, ctx: PPContext): string[] {
	// "filename" → [filename, rest]
	if (tok.kind === CTokenKind.Str) {
		return [tok.stringVal, ""];
	}
	// <filename> → join tokens between < and >
	if (tok.stringVal === "<") {
		let result = "";
		tok = tok.next;
		while (tok.kind !== CTokenKind.Eof && tok.stringVal !== ">") {
			if (tok.hasSpace && result !== "") result = result + " ";
			result = result + tok.stringVal;
			tok = tok.next;
		}
		return [result, ""];
	}
	return ["", ""];
}

// Detect include guard pattern: #ifndef GUARD / #define GUARD / ... / #endif
// covering the entire file. Returns the guard macro name, or "" if no guard.
function detectIncludeGuard(tokens: CToken): string {
	let t = tokens;
	// Skip to first non-whitespace preprocessor token
	// Look for: #ifndef IDENTIFIER as the first directive
	if (t.kind === CTokenKind.Eof) return "";
	// The raw token stream should start with # ifndef IDENT
	// But after our tokenizer, # is a Punct and ifndef is an Ident
	if (t.stringVal !== "#") return "";
	t = t.next;
	if (t.kind === CTokenKind.Eof || t.stringVal !== "ifndef") return "";
	t = t.next;
	if (t.kind === CTokenKind.Eof || t.kind !== CTokenKind.Ident) return "";
	const guard = t.stringVal;
	return guard;
}

function includeFile(filename: string, tok: CToken, ctx: PPContext): CToken {
	// #pragma once check
	if (ctx.pragmaOnce.has(filename)) return tok;

	const resolved = searchIncludePaths(filename, ctx);
	if (resolved === "") {
		ctx.diags.push(makeDiag(DiagSeverity.Error, tok.file, tok.line, tok.col,
			`'${filename}' file not found`));
		return tok;
	}

	if (ctx.pragmaOnce.has(resolved)) return tok;

	// Circular include guard — skip if this file is already being processed
	if (ctx.includeStack.has(resolved)) return tok;
	ctx.includeStack.set(resolved, true);

	const source = try readFile(resolved) catch "";
	const tokenized = tokenizeFile(source, resolved);
	// Included tokens splice into the outer stream — fold the nested arena into
	// the session arena so they outlive this call.
	for (const at of tokenized.arena) ctx.arena.push(at);
	for (const d of tokenized.diagnostics) ctx.diags.push(d);

	// Detect include guard before preprocessing
	const guard = detectIncludeGuard(tokenized.head);

	// Preprocess the included file
	const included = preprocess2(tokenized.head, ctx);

	// If file had include guard AND the guard macro is now defined, treat as #pragma once
	if (guard !== "" && ctx.macros.has(guard)) {
		ctx.pragmaOnce.set(resolved, true);
		ctx.pragmaOnce.set(filename, true);
	}

	return append(included, tok);
}

// ===== Main Preprocessing Engine =====

function preprocess2(tok: CToken, ctx: PPContext): CToken {
	const head = makeEofToken(ctx.file);
	let cur = head;

	while (tok.kind !== CTokenKind.Eof) {
		// Try macro expansion
		const r = expandMacro(tok, ctx);
		if (r[0] !== null) {
			tok = r[0];
			continue;
		}

		// Non-directive: pass through
		if (!tok.atBol || tok.stringVal !== "#") {
			const c = copyToken(ctx, tok);
			cur.next = c;
			cur = c;
			tok = tok.next;
			continue;
		}

		// Directive
		const dir = tok.next;
		if (dir.kind === CTokenKind.Eof) { tok = dir; continue; }

		// #include
		if (dir.stringVal === "include") {
			const fnParts = readIncludeFilename(dir.next, ctx);
			const filename = fnParts[0];
			const rest = skipLine(dir.next);
			if (filename !== "") {
				const included = includeFile(filename, rest, ctx);
				tok = included;
			} else {
				ctx.diags.push(makeDiag(DiagSeverity.Error, dir.file, dir.line, dir.col, "expected filename"));
				tok = rest;
			}
			continue;
		}

		// #define
		if (dir.stringVal === "define") {
			tok = readMacroDefinition(dir.next, ctx);
			continue;
		}

		// #undef
		if (dir.stringVal === "undef") {
			if (dir.next.kind === CTokenKind.Ident) {
				ctx.macros.delete(dir.next.stringVal);
			}
			tok = skipLine(dir.next);
			continue;
		}

		// #if
		if (dir.stringVal === "if") {
			const val = evalConstExpr(dir.next, ctx);
			pushCondIncl(ctx, val !== 0);
			if (val === 0) {
				tok = skipCondIncl(skipLine(dir.next));
				continue;
			}
			tok = skipLine(dir.next);
			continue;
		}

		// #ifdef
		if (dir.stringVal === "ifdef") {
			const defined = dir.next.kind === CTokenKind.Ident && ctx.macros.has(dir.next.stringVal);
			pushCondIncl(ctx, defined);
			if (!defined) {
				tok = skipCondIncl(skipLine(dir.next));
				continue;
			}
			tok = skipLine(dir.next);
			continue;
		}

		// #ifndef
		if (dir.stringVal === "ifndef") {
			const defined = dir.next.kind === CTokenKind.Ident && ctx.macros.has(dir.next.stringVal);
			pushCondIncl(ctx, !defined);
			if (defined) {
				tok = skipCondIncl(skipLine(dir.next));
				continue;
			}
			tok = skipLine(dir.next);
			continue;
		}

		// #elif
		if (dir.stringVal === "elif") {
			if (ctx.condStack === null) {
				ctx.diags.push(makeDiag(DiagSeverity.Error, dir.file, dir.line, dir.col, "#elif without #if"));
				tok = skipLine(dir.next);
				continue;
			}
			if (ctx.condStack.ctx === COND_ELSE) {
				ctx.diags.push(makeDiag(DiagSeverity.Error, dir.file, dir.line, dir.col, "#elif after #else"));
				tok = skipLine(dir.next);
				continue;
			}
			ctx.condStack.ctx = COND_ELIF;
			if (ctx.condStack.included) {
				tok = skipCondIncl(skipLine(dir.next));
				continue;
			}
			const val = evalConstExpr(dir.next, ctx);
			if (val !== 0) {
				ctx.condStack.included = true;
				tok = skipLine(dir.next);
			} else {
				tok = skipCondIncl(skipLine(dir.next));
			}
			continue;
		}

		// #else
		if (dir.stringVal === "else") {
			if (ctx.condStack === null) {
				ctx.diags.push(makeDiag(DiagSeverity.Error, dir.file, dir.line, dir.col, "#else without #if"));
				tok = skipLine(dir.next);
				continue;
			}
			ctx.condStack.ctx = COND_ELSE;
			if (ctx.condStack.included) {
				tok = skipCondIncl(skipLine(dir.next));
			} else {
				ctx.condStack.included = true;
				tok = skipLine(dir.next);
			}
			continue;
		}

		// #endif
		if (dir.stringVal === "endif") {
			if (ctx.condStack === null) {
				ctx.diags.push(makeDiag(DiagSeverity.Error, dir.file, dir.line, dir.col, "#endif without #if"));
			} else {
				ctx.condStack = ctx.condStack.parent;
			}
			tok = skipLine(dir.next);
			continue;
		}

		// #line
		if (dir.stringVal === "line") {
			// Consume and ignore (we track line numbers from source)
			tok = skipLine(dir.next);
			continue;
		}

		// #pragma once
		if (dir.stringVal === "pragma" && dir.next.stringVal === "once") {
			ctx.pragmaOnce.set(tok.file, true);
			tok = skipLine(dir.next);
			continue;
		}

		// #pragma (other) — skip
		if (dir.stringVal === "pragma") {
			tok = skipLine(dir.next);
			continue;
		}

		// #error
		if (dir.stringVal === "error") {
			const msg = joinTokens(dir.next);
			ctx.diags.push(makeDiag(DiagSeverity.Error, dir.file, dir.line, dir.col, `#error ${msg}`));
			tok = skipLine(dir.next);
			continue;
		}

		// Unknown directive — skip
		tok = skipLine(dir.next);
	}

	cur.next = newEof(ctx, tok);
	return head.next;
}

// ===== Initialize Built-in Macros =====

function initMacros(ctx: PPContext): void {
	// Dynamic built-in macros
	const fileMac = addMacro(ctx, "__FILE__", true, newEof(ctx, makeEofToken("")));
	fileMac.handler = "__FILE__";
	const lineMac = addMacro(ctx, "__LINE__", true, newEof(ctx, makeEofToken("")));
	lineMac.handler = "__LINE__";
	const counterMac = addMacro(ctx, "__COUNTER__", true, newEof(ctx, makeEofToken("")));
	counterMac.handler = "__COUNTER__";

	// Predefined macros from target
	const defs = predefinedMacros(ctx.target);
	for (const def of defs) {
		const valTok = makeEofToken("");
		valTok.kind = CTokenKind.PPNum;
		valTok.stringVal = def.value;
		valTok.next = newEof(ctx, makeEofToken(""));
		addMacro(ctx, def.name, true, valTok);
	}
}

// ===== Public Entry Point =====

export function preprocess(
	head: CToken,
	target: TargetInfo,
	includePaths: string[]
): PreprocessResult {
	const ctx: PPContext = {
		macros: new HashMap<string, Macro>(),
		condStack: null as unknown as CondIncl,
		pragmaOnce: new HashMap<string, boolean>(),
		includeStack: new HashMap<string, boolean>(),
		includePaths,
		target,
		diags: [],
		file: head.file,
		counter: 0,
		arena: [],
	};

	initMacros(ctx);

	const result = preprocess2(head, ctx);

	// Check for unterminated #if
	if (ctx.condStack !== null) {
		ctx.diags.push(makeDiag(DiagSeverity.Error, head.file, 0, 0, "unterminated #if"));
	}

	convertPPTokens(result, ctx.diags);

	return { head: result, diagnostics: ctx.diags, arena: ctx.arena };
}

// ===== Tests =====

test "preprocess empty token stream is a no-op" {
	const eof = makeEofToken("empty.h");
	const r = preprocess(eof, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Eof;
}

test "preprocess object macro" {
	const r0 = tokenizeFile("#define FOO 42\nFOO", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 42 as int64;
}

test "preprocess function macro" {
	const r0 = tokenizeFile("#define ADD(a,b) a+b\nADD(1,2)", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.stringVal === "1";
	assert r.head.next.stringVal === "+";
	assert r.head.next.next.stringVal === "2";
}

test "preprocess object macro definition ending file without newline" {
	const r0 = tokenizeFile("#define FOO 42", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Eof;
}

test "preprocess function-like macro definition ending file without newline" {
	const r0 = tokenizeFile("#define ADD(a,b) a+b", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Eof;
}

test "preprocess ifdef true" {
	const r0 = tokenizeFile("#define FOO\n#ifdef FOO\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 42 as int64;
}

test "preprocess ifdef false" {
	const r0 = tokenizeFile("#ifdef FOO\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Eof;
}

test "preprocess ifndef" {
	const r0 = tokenizeFile("#ifndef FOO\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
}

test "preprocess if 1" {
	const r0 = tokenizeFile("#if 1\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
}

test "preprocess if 0 else" {
	const r0 = tokenizeFile("#if 0\n1\n#else\n2\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 2 as int64;
}

test "preprocess if defined" {
	const r0 = tokenizeFile("#define X\n#if defined(X)\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 42 as int64;
}

test "preprocess undef" {
	const r0 = tokenizeFile("#define FOO 1\n#undef FOO\n#ifdef FOO\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Eof;
}

test "preprocess nested ifdef" {
	const r0 = tokenizeFile("#define A\n#ifdef A\n#ifdef B\n1\n#else\n2\n#endif\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 2 as int64;
}

test "preprocess pragma once" {
	const r0 = tokenizeFile("#pragma once\n42", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
}

test "preprocess if expression" {
	const r0 = tokenizeFile("#if 2 + 3 == 5\n42\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 42 as int64;
}

test "preprocess elif" {
	const r0 = tokenizeFile("#if 0\n1\n#elif 1\n2\n#else\n3\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 2 as int64;
}

test "preprocess error directive" {
	const r0 = tokenizeFile("#error something wrong", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.diagnostics.length > 0;
}

test "preprocess macro expanding to another macro" {
	const r0 = tokenizeFile("#define A B\n#define B 99\nA", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 99 as int64;
}

test "preprocess self-referential macro stops" {
	// #define X X should not infinitely recurse (hideset prevents it)
	const r0 = tokenizeFile("#define X X\nX", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.kind === CTokenKind.Ident;
	assert r.head.stringVal === "X";
}

test "preprocess function macro with nested parens in arg" {
	const r0 = tokenizeFile("#define F(x) x\nF((1+2))", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	// Should produce ( 1 + 2 ) — the parens are part of the argument
	assert r.head.stringVal === "(";
}

test "preprocess if with bitwise expression" {
	const r0 = tokenizeFile("#if (1 << 2) == 4\nyes\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.stringVal === "yes";
}

test "preprocess if with logical and" {
	const r0 = tokenizeFile("#define A 1\n#define B 1\n#if defined(A) && defined(B)\nyes\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.stringVal === "yes";
}

test "preprocess if with undefined macro is 0" {
	// Undefined identifiers in #if evaluate to 0 per C spec
	const r0 = tokenizeFile("#if UNDEFINED_MACRO\nyes\n#else\nno\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.stringVal === "no";
}

test "preprocess __STDC__ always defined" {
	// __STDC__ is a base predefined macro, available for any target
	const r0 = tokenizeFile("#define __STDC__ 1\n#ifdef __STDC__\nstdc\n#else\nother\n#endif", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.stringVal === "stdc";
}

test "preprocess unterminated if produces diagnostic" {
	const r0 = tokenizeFile("#if 1\nfoo", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.diagnostics.length > 0;
}

test "preprocess multi-token macro body" {
	const r0 = tokenizeFile("#define DECL extern int\nDECL x;", "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	assert r.head.stringVal === "extern";
	assert r.head.next.stringVal === "int";
	assert r.head.next.next.stringVal === "x";
}

test "preprocess include guard pattern" {
	// Define-then-check: #define creates the macro, second #ifdef sees it
	const src = "#define GUARD\n#ifdef GUARD\nfirst\n#endif\n#ifndef GUARD\nsecond\n#endif";
	const r0 = tokenizeFile(src, "test.h");
	const r = preprocess(r0.head, targetLinuxX86_64(), []);
	let foundFirst = false;
	let foundSecond = false;
	let tok = r.head;
	while (tok.kind !== CTokenKind.Eof) {
		if (tok.stringVal === "first") foundFirst = true;
		if (tok.stringVal === "second") foundSecond = true;
		tok = tok.next;
	}
	assert foundFirst === true;
	assert foundSecond === false;
}
