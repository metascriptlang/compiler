// cparse — Integer constant expression evaluator
// Port of: ~/projects/chibicc parse.c const_expr / eval path.
//
// Used by:
//   1. enum values: enum { A = 1 << 3 }
//   2. array sizes: int buf[BUFSIZ]
//   3. bitfield widths: int x : 5
//
// Operates on post-preprocessed tokens (CTokenKind.Num, not PPNum).
// Identifiers resolve to previously-defined enum constants via lookup map.

import { CToken, CTokenKind } from "./token";

export interface EvalResult {
	value: int64;
	tok: CToken;    // token position after the evaluated expression
	ok: boolean;
	error: string;
}

interface CConstEvalState {
	tok: CToken;
	constants: Map<string, int64>;
	error: string;
}

function next(es: CConstEvalState): void {
	if (es.tok.kind !== CTokenKind.Eof) es.tok = es.tok.next;
}

// ===== Recursive descent (C operator precedence) =====

function evalTernary(es: CConstEvalState): int32 {
	let val = evalOr(es);
	if (es.tok.stringVal === "?") {
		next(es);
		const thenVal = evalTernary(es);
		if (es.tok.stringVal === ":") next(es);
		else es.error = "expected ':' in ternary";
		const elseVal = evalTernary(es);
		return val !== 0 ? thenVal : elseVal;
	}
	return val;
}

function evalOr(es: CConstEvalState): int32 {
	let val = evalAnd(es);
	while (es.tok.stringVal === "||") {
		next(es);
		const rhs = evalAnd(es);
		val = (val !== 0 || rhs !== 0) ? 1 : 0;
	}
	return val;
}

function evalAnd(es: CConstEvalState): int32 {
	let val = evalBitOr(es);
	while (es.tok.stringVal === "&&") {
		next(es);
		const rhs = evalBitOr(es);
		val = (val !== 0 && rhs !== 0) ? 1 : 0;
	}
	return val;
}

function evalBitOr(es: CConstEvalState): int32 {
	let val = evalBitXor(es);
	while (es.tok.stringVal === "|") {
		next(es);
		val = val | evalBitXor(es);
	}
	return val;
}

function evalBitXor(es: CConstEvalState): int32 {
	let val = evalBitAnd(es);
	while (es.tok.stringVal === "^") {
		next(es);
		val = val ^ evalBitAnd(es);
	}
	return val;
}

function evalBitAnd(es: CConstEvalState): int32 {
	let val = evalEquality(es);
	while (es.tok.stringVal === "&") {
		next(es);
		val = val & evalEquality(es);
	}
	return val;
}

function evalEquality(es: CConstEvalState): int32 {
	let val = evalRelational(es);
	while (es.tok.stringVal === "==" || es.tok.stringVal === "!=") {
		const op = es.tok.stringVal;
		next(es);
		const rhs = evalRelational(es);
		if (op === "==") val = val === rhs ? 1 : 0;
		else val = val !== rhs ? 1 : 0;
	}
	return val;
}

function evalRelational(es: CConstEvalState): int32 {
	let val = evalShift(es);
	while (es.tok.stringVal === "<" || es.tok.stringVal === ">" ||
		   es.tok.stringVal === "<=" || es.tok.stringVal === ">=") {
		const op = es.tok.stringVal;
		next(es);
		const rhs = evalShift(es);
		val = match (op) {
			"<" => val < rhs ? 1 : 0,
			">" => val > rhs ? 1 : 0,
			"<=" => val <= rhs ? 1 : 0,
			_ => val >= rhs ? 1 : 0,
		};
	}
	return val;
}

function evalShift(es: CConstEvalState): int32 {
	let val = evalAdd(es);
	while (es.tok.stringVal === "<<" || es.tok.stringVal === ">>") {
		const op = es.tok.stringVal;
		next(es);
		const rhs = evalAdd(es);
		if (op === "<<") val = val << rhs;
		else val = val >> rhs;
	}
	return val;
}

function evalAdd(es: CConstEvalState): int32 {
	let val = evalMul(es);
	while (es.tok.stringVal === "+" || es.tok.stringVal === "-") {
		const op = es.tok.stringVal;
		next(es);
		const rhs = evalMul(es);
		if (op === "+") val = val + rhs;
		else val = val - rhs;
	}
	return val;
}

function evalMul(es: CConstEvalState): int32 {
	let val = evalUnary(es);
	while (es.tok.stringVal === "*" || es.tok.stringVal === "/" || es.tok.stringVal === "%") {
		const op = es.tok.stringVal;
		next(es);
		const rhs = evalUnary(es);
		if (op === "*") val = val * rhs;
		else if (op === "/" && rhs !== 0) val = (val / rhs) | 0;
		else if (op === "%" && rhs !== 0) val = val % rhs;
	}
	return val;
}

function evalUnary(es: CConstEvalState): int32 {
	return match (es.tok.stringVal) {
		"!" => { next(es); return evalUnary(es) === 0 ? 1 : 0; },
		"~" => { next(es); return ~evalUnary(es); },
		"-" => { next(es); return -evalUnary(es); },
		"+" => { next(es); return evalUnary(es); },
		_ => evalPrimary(es),
	};
}

function evalPrimary(es: CConstEvalState): int32 {
	const tok = es.tok;

	// Parenthesized expression
	if (tok.stringVal === "(") {
		next(es);
		const val = evalTernary(es);
		if (es.tok.stringVal === ")") next(es);
		return val;
	}

	// Numeric literal
	if (tok.kind === CTokenKind.Num) {
		const val = tok.intVal as int32;
		next(es);
		return val;
	}

	// Character literal stored as Num by tokenizer
	// (already handled above since char literals have kind=Num)

	// Enum constant or other identifier → lookup
	if (tok.kind === CTokenKind.Ident || tok.kind === CTokenKind.Keyword) {
		const name = tok.stringVal;
		next(es);
		if (es.constants.has(name)) {
			return es.constants.get(name) as unknown as int32;
		}
		// Unknown identifier in const expr context — not necessarily an error
		// (could be a macro that expanded to nothing, or a forward ref)
		return 0;
	}

	// Hit something unexpected (comma, semicolon, etc.) — stop
	return 0;
}

// ===== Public API =====

// Evaluate a constant expression starting at `tok`. The `constants` map
// provides values for previously-defined enum constants (e.g., A=1 lets
// B=A|2 resolve). Returns the result with `tok` advanced past the expression.
export function evalConstExpr(
	tok: CToken,
	constants: Map<string, int64>
): EvalResult {
	const es: CConstEvalState = {
		tok,
		constants,
		error: "",
	};
	const val = evalTernary(es);
	if (es.error !== "") {
		return { value: 0 as int64, tok: es.tok, ok: false, error: es.error };
	}
	return { value: val as int64, tok: es.tok, ok: true, error: "" };
}

// ===== Tests =====

import { tokenizeFile, convertPPTokens } from "./tokenize";

function evalStr(source: string): EvalResult {
	const r = tokenizeFile(source, "eval.h");
	convertPPTokens(r.head, r.diagnostics);
	return evalConstExpr(r.head, new Map<string, int64>());
}

function evalWithConstants(source: string, constants: Map<string, int64>): EvalResult {
	const r = tokenizeFile(source, "eval.h");
	convertPPTokens(r.head, r.diagnostics);
	return evalConstExpr(r.head, constants);
}

test "eval integer literal" {
	const r = evalStr("42");
	assert r.ok === true;
	assert r.value === 42 as int64;
}

test "eval hex literal" {
	const r = evalStr("0xFF");
	assert r.ok === true;
	assert r.value === 255 as int64;
}

test "eval addition" {
	const r = evalStr("1 + 2");
	assert r.ok === true;
	assert r.value === 3 as int64;
}

test "eval shift left" {
	const r = evalStr("1 << 3");
	assert r.ok === true;
	assert r.value === 8 as int64;
}

test "eval bitwise or" {
	const r = evalStr("1 | 2 | 4");
	assert r.ok === true;
	assert r.value === 7 as int64;
}

test "eval complex bitwise" {
	const r = evalStr("(1 << 0) | (1 << 1) | (1 << 2)");
	assert r.ok === true;
	assert r.value === 7 as int64;
}

test "eval precedence: multiply before add" {
	const r = evalStr("2 + 3 * 4");
	assert r.ok === true;
	assert r.value === 14 as int64;
}

test "eval parentheses" {
	const r = evalStr("(2 + 3) * 4");
	assert r.ok === true;
	assert r.value === 20 as int64;
}

test "eval unary minus" {
	const r = evalStr("-1");
	assert r.ok === true;
	assert r.value === -1 as int64;
}

test "eval unary not" {
	const r = evalStr("!0");
	assert r.ok === true;
	assert r.value === 1 as int64;
}

test "eval ternary" {
	const r = evalStr("1 ? 10 : 20");
	assert r.ok === true;
	assert r.value === 10 as int64;
}

test "eval comparison" {
	const r = evalStr("5 > 3");
	assert r.ok === true;
	assert r.value === 1 as int64;
}

test "eval equality" {
	const r = evalStr("42 == 42");
	assert r.ok === true;
	assert r.value === 1 as int64;
}

test "eval enum constant lookup" {
	const constants = new Map<string, int64>();
	constants.set("FLAG_A", 1 as int64);
	constants.set("FLAG_B", 2 as int64);
	const r = evalWithConstants("FLAG_A | FLAG_B", constants);
	assert r.ok === true;
	assert r.value === 3 as int64;
}

test "eval shift and or pattern (common in errno.h)" {
	const r = evalStr("(3 << 26) | 1");
	assert r.ok === true;
	assert r.value === (201326593) as int64;
}

test "eval division truncates" {
	const r = evalStr("7 / 2");
	assert r.ok === true;
	assert r.value === 3 as int64;
}

test "eval modulo" {
	const r = evalStr("7 % 3");
	assert r.ok === true;
	assert r.value === 1 as int64;
}

test "eval bitwise complement" {
	const r = evalStr("~0");
	assert r.ok === true;
	assert r.value === -1 as int64;
}

test "eval logical and/or" {
	const r1 = evalStr("1 && 0");
	assert r1.value === 0 as int64;
	const r2 = evalStr("1 || 0");
	assert r2.value === 1 as int64;
}
