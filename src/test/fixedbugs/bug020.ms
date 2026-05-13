// bug020 — Inline arrow stored as a closure-typed value with a contextually
// known Result<T, E> return type was being checked with NO expected type,
// so calls like `Result.ok(42)` bound only T (from the value arg) and left
// E as an unsubstituted GenericParam. The lifter copied that half-resolved
// type onto the lifted FunctionDecl, codegen's `hasGenericParams` guard
// fired in declarations.ms, the body was silently dropped, and the linker
// blew up on the call-site reference.
//
// Symptom:    `error: use of undeclared identifier 'dollarfn_<scope>_N_'`
//             at the C link stage for any inline arrow whose contextually
//             expected return type was `Result<T, E>` with concrete T, E.
// Root cause: src/checker/checkExprPass.ms — checkAnonymousFunction
//             intentionally did NOT propagate the expected RETURN type
//             from the caller into the arrow's body inference. The comment
//             cited fear of generic contextual types (`() => T`) shadowing
//             the concrete inference. That guard was too aggressive: when
//             the expected return type is already CONCRETE (no GenericParam
//             children), propagating it gives the body the contextual info
//             it needs.
// Fix:        Propagate expectedType.typeReturn into explicitReturnType when
//             (a) no explicit annotation was written and (b) the contextual
//             return type contains no GenericParams. Guarded by
//             `hasGenericParams(expectedType.typeReturn)` so generic
//             callers still drive concrete inference from the body.

import { compileToC } from "../helpers";

test "bug020: inline arrow stored to const with Result<int32, string> return — body emitted" {
	const src = `
function create(): boolean {
	const fn: () => Result<int32, string> = () => Result.ok(42);
	return fn().ok;
}
function main(): void {
	const r = create();
	if (!r) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug020: inline arrow as object literal field returning Result<T, E> — body emitted" {
	const src = `
interface MyBuilder {
	listen: () => Result<int32, string>;
}

function create(): MyBuilder {
	return {
		listen: () => Result.ok(42),
	};
}

function main(): void {
	const b = create();
	const r = b.listen();
	if (!r.ok) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug020: inline arrow returning Result.err binds E from context" {
	const src = `
function create(): boolean {
	const fn: () => Result<int32, string> = () => Result.err("nope");
	return fn().ok;
}
function main(): void {
	const r = create();
	if (r) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug020: inline arrow with multi-statement body returning Result.ok works" {
	const src = `
function create(): boolean {
	const fn: () => Result<int32, string> = () => {
		const x = 42;
		return Result.ok(x);
	};
	return fn().ok;
}
function main(): void {
	const r = create();
	if (!r) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug020: multi-return-path body — each ReturnStmt uses contextual expected" {
	// Verifies the propagation reaches BOTH return paths via
	// ctx.currentFunction.symType.typeReturn (not just the last expression).
	const src = `
function create(flag: boolean): boolean {
	const fn: () => Result<int32, string> = () => {
		if (flag) {
			return Result.ok(42);
		}
		return Result.err("nope");
	};
	return fn().ok;
}
function main(): void {
	const r = create(true);
	if (!r) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug020: control — inline arrow returning boolean still works (no regression)" {
	const src = `
interface MyBuilder {
	listen: () => boolean;
}
function create(): MyBuilder {
	return { listen: () => true };
}
function main(): void {
	const b = create();
	if (!b.listen()) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// (No regression-guard test for generic contextual return propagation:
// MS currently has a separate type-checker limitation around generic
// callback param resolution that triggers an "Argument type mismatch in
// 'map' arg 1: got function, expected function" diagnostic regardless of
// this fix. Once that limitation is addressed, add an explicit guard here.)
