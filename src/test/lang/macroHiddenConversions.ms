import { Node } from "std/meta";

type SourceAccessor<T> = distinct (() => T);

export function valueOf<T>(this a: SourceAccessor<T>): T { return a(); }

export macro firstSourceExpr(n: Node): Node { return n.jsxChildren[0].jsxExpr; }

test "macro callable source: a const JSX alias re-checked through a macro calls the accessor once" {
	let calls: int32 = 0;
	const c = (() => { calls = calls + 1; return 7; }) as SourceAccessor<int32>;
	const view = <p>{c()}</p>;
	const v: int32 = firstSourceExpr(view);
	assert v === 7;
	assert calls == 1;
}

test "macro callable source: a string accessor survives the same path" {
	const s = (() => "hi") as SourceAccessor<string>;
	const view = <p>{s()}</p>;
	const v: string = firstSourceExpr(view);
	assert v === "hi";
}

test "macro callable source: an implicit read inside the const JSX is called exactly once" {
	let calls: int32 = 0;
	const c = (() => { calls = calls + 1; return 5; }) as SourceAccessor<int32>;
	const view = <p>{c * 2}</p>;
	const v: int32 = firstSourceExpr(view);
	assert v === 10;
	assert calls == 1;
}

enum Tone { Low, High }

function eqMaybe(m: int32 | null, v: int32): boolean { return m == v; }

function eqTone(m: Tone | null, v: Tone): boolean { return m == v; }

function eqText(m: string | null, v: string): boolean { return m == v; }

function idMaybe<T>(x: T): T | null { return x; }

function withDefault(x: int32 | null = 5, y: int32 = 5): boolean { return x == y; }

function seven(): int32 { return 7; }

function callOr(f: (() => int32) | null): int32 { return f != null ? f() : -1; }

function callIt(f: () => int32): int32 { return f(); }

template viaMaybe(x: int32): boolean { return eqMaybe(x, x); }

template viaTone(t: Tone): boolean { return eqTone(t, t); }

template viaText(s: string): boolean { return eqText(s, s); }

template viaThunk(): int32 { return callOr(seven) + callIt(seven); }

test "macro hidden carriers: template payloads survive repeated expansion with distinct values" {
	for (const value of [0, 3, -4]) {
		assert viaMaybe(value), value.toString();
	}
}

test "macro hidden carriers: enum and string payloads through a template" {
	assert viaTone(Tone.High);
	assert viaTone(Tone.Low);
	assert viaText("ok");
}

test "macro hidden carriers: neighbours stay green across direct call, generic instantiation, default parameter" {
	assert eqMaybe(3, 3);
	assert !eqMaybe(null, 3);
	const g = idMaybe<int32>(9);
	assert g == 9;
	assert withDefault();
	assert withDefault(6, 6);
	assert !withDefault(null, 6);
}

test "macro hidden carriers: a named function meeting a closure slot through a template wraps once" {
	assert viaThunk() == 14;
	assert callOr(null) == -1;
}

test "macro hidden carriers: module-level nullable consts keep their values" {
	assert modulePayload == 11;
	assert modulePayload != null;
	assert moduleFn != null;
	assert callOr(moduleFn) == 7;
}

const modulePayload: int32 | null = 11;

const moduleFn: (() => int32) | null = seven;
