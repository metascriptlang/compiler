// bug102 — `static const/let/var`: per-site storage class (Nim `{.global.}` / sfGlobal)
//
// Symptom:    no way to give a declaration inside a function or method body
//             storage at module scope. A macro expanding at an EXPRESSION
//             position (checkExprPass replaces the node in place) has no
//             statement context to hoist a decl into, so any per-site
//             singleton — memo cache, compiled pattern, render template —
//             is rebuilt on every call.
// Reference:  `sfGlobal` (astdef.nim:48) is set two ways: automatically for a
//             variable owned by a module (semstmts.nim:1117/1131/1161/1175)
//             and by hand via `{.global.}` on a variable inside a proc. One
//             flag, position-independent. `genSingleVar` (ccgstmts.nim:365)
//             routes the STORAGE to file scope; the INITIALIZER is a separate
//             decision (potentialValueInit, ccgstmts.nim:319-325) and lands in
//             the current proc unless it is a deep-const non-GC value — which
//             is why `once` (system.nim:2859) composes a guard flag ON TOP.
// Design:     `SymbolFlag.Global` already IS `sfGlobal` (six consumers wired,
//             see docs/NIM-REF.md last section) — stamp it, do not add a
//             second flag. `static const` implies run-once (MS has a runtime
//             `const`, Nim does not, so Nim needs `{.global.}` + `once` by
//             hand); `static let`/`static var` keep Nim's per-call init.
//             An initializer reading a param or enclosing local is a
//             fail-loud checker error, never first-call-wins.

import { compileToC } from "../helpers";

test "bug102: static const in a function body compiles" {
	const c = compileToC(`
let builds: int32 = 0;
function mk(): int32 { builds = builds + 1; return builds; }
function get(): int32 {
	static const t = mk();
	return t;
}
function main(): void { console.log((get() + get()).toString()); }
`);
	assert c.ok;
}

test "bug102: static let in a function body compiles" {
	const c = compileToC(`
let builds: int32 = 0;
function mk(): int32 { builds = builds + 1; return builds; }
function get(): int32 {
	static let t = mk();
	return t;
}
function main(): void { console.log((get() + get()).toString()); }
`);
	assert c.ok;
}

// `static var` is rejected rather than silently miscompiled. `varHoist` rebuilds
// a `var` declaration as a hoisted decl plus a bare assignment WITHOUT carrying
// the original symbol (the "lowered decls always carry their symbol" class), so
// the slot would be emitted as an untyped frame local while every read resolved
// to the module-scope name. Plain `var n = 0` — no `static` — already shows the
// same symbol loss today, so this is not the storage class's bug to fix here.
test "bug102: static var is rejected while var decls still drop their symbol" {
	const c = compileToC(`
function bump(): int32 {
	static var n = 0;
	n = n + 1;
	return n;
}
function main(): void { console.log(bump().toString()); }
`);
	assert !c.ok;
	assert c.error.contains("static var");
	assert c.error.contains("static let");
}

// NOTE: "the slot lives at module scope, not in the frame" is proved at RUNTIME
// by src/test/corpus/programs — if the slot were a frame local the initializer
// would re-run per call and the build counter would climb. Asserting it here by
// the ordering of substrings in the emitted C would pin formatting, not
// semantics, so it deliberately is not done in this file.

// `static const` runs its initializer once, so it needs a guard; `static let`
// keeps Nim's `{.global.}` semantics (storage moved, initializer per call) and
// must NOT get one. The differential is the load-bearing assertion — either
// half alone would pass a codegen that guards everything or nothing.
test "bug102: static const gets a run-once guard, static let does not" {
	const withConst = compileToC(`
let builds: int32 = 0;
function mk(): int32 { builds = builds + 1; return builds; }
function get(): int32 {
	static const t = mk();
	return t;
}
function main(): void { console.log(get().toString()); }
`);
	assert withConst.ok;
	assert withConst.value.contains("__once");

	const withLet = compileToC(`
let builds: int32 = 0;
function mk(): int32 { builds = builds + 1; return builds; }
function get(): int32 {
	static let t = mk();
	return t;
}
function main(): void { console.log(get().toString()); }
`);
	assert withLet.ok;
	assert !withLet.value.contains("__once");
}

// An RC-typed slot is what exposes scope cleanup. The analyzer registers every
// owned local for scope-exit destroy; module-scope storage must be routed away
// from that list (the reference decides this at the declaration, sending a
// global's destroy to a program-exit list rather than the scope's). Without it
// the analyzer also detaches the initializer, so the guard never appears — which
// is why this asserts on a string-typed slot: the int-typed case above needs no
// cleanup and passes even when the routing is missing.
test "bug102: an RC-typed static const still gets its run-once guard" {
	const c = compileToC(`
let builds: int32 = 0;
function mk(tag: string): string { builds = builds + 1; return tag + builds.toString(); }
function get(): string {
	static const s = mk("S");
	return s;
}
function main(): void { console.log(get() + get()); }
`);
	assert c.ok;
	assert c.value.contains("__once");
}

// Two sites declaring the same source name must not collide at module scope.
// Nim mangles by unique symbol ID rather than source name (`t__g_u87`).
test "bug102: two functions declaring `static const t` do not collide" {
	const c = compileToC(`
function a(): int32 {
	static const t = 1;
	return t;
}
function b(): int32 {
	static const t = 2;
	return t;
}
function main(): void { console.log((a() + b()).toString()); }
`);
	// That the two slots are actually DISTINCT is proved at runtime (a() must
	// return 1 and b() must return 2 — a collision would let one clobber the
	// other). Here we only pin that both sites engaged the storage class:
	// counting name occurrences in the C would count each slot's decl, its
	// assignment and its reads, which says nothing about collision.
	assert c.ok;
	assert c.value.contains("__static");
}

// Fail-loud: a run-once initializer that reads a parameter would silently bind
// the singleton to whichever caller arrived first. Reject instead.
test "bug102: static const initializer reading a param is a checker error" {
	const c = compileToC(`
function f(n: int32): int32 {
	static const t = n + 1;
	return t;
}
function main(): void { console.log(f(1).toString()); }
`);
	assert !c.ok;
	// "computed once" is unique to the checker diagnostic — asserting a bare
	// "static" would also be satisfied by the parse error a compiler without
	// this feature emits, i.e. it would pass for the wrong reason.
	assert c.error.contains("computed once");
	assert c.error.contains("parameter");
}

test "bug102: static const initializer reading an enclosing local is a checker error" {
	const c = compileToC(`
function f(): int32 {
	let k: int32 = 3;
	static const t = k + 1;
	return t;
}
function main(): void { console.log(f().toString()); }
`);
	assert !c.ok;
	assert c.error.contains("computed once");
	assert c.error.contains("local");
}
