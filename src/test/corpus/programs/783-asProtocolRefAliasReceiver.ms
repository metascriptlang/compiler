// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// Parity program — `v as U`, a typed slot and an argument read through a converter
// when the receiver is a named alias of `Ref<match-union>`, the shape of
// `JsonValue`: a local alias, a parsed JSON value, and a member read through
// `getDynamicField`.
//
// @stdout: local fromU 7|json abc 42 true|member Ann 30|slots Ann 30 Ann|miss [] 0
// @exit: 0

import { parseJson, JsonValue } from "std/serialize/json";

enum K { A, B }
type UData = match (kind: K) {
	K.A => { s: string },
	K.B => { n: int32 },
};
type U = Ref<UData>;

converter uToText(v: U): string { return "fromU"; }
converter uToInt32(v: U): int32 { return 7; }

function local(v: U): string {
	const s = v as string;
	const n = v as int32;
	return `${s} ${n}`;
}

function scalars(a: JsonValue, b: JsonValue, c: JsonValue): string {
	const s = a as string;
	const n = b as int32;
	const f = c as boolean;
	return `${s} ${n} ${f}`;
}

function member(v: JsonValue): string {
	const name = v.name as string;
	const age = v.age as int32;
	return `${name} ${age}`;
}

function echo(s: string): string { return s; }

function slots(v: JsonValue): string {
	const name: string = v.name;
	const age: int32 = v.age;
	return `${name} ${age} ${echo(v.name)}`;
}

function miss(v: JsonValue): string {
	const s = v.age as string;
	const n = v.name as int32;
	return `[${s}] ${n}`;
}

const u: U = { kind: K.A, s: "x" };
const a = parseJson("\"abc\"");
const b = parseJson("42");
const c = parseJson("true");
const o = parseJson("{\"name\":\"Ann\",\"age\":30}");
if (a.ok && b.ok && c.ok && o.ok) {
	console.log(`local ${local(u)}|json ${scalars(a.value, b.value, c.value)}|member ${member(o.value)}|slots ${slots(o.value)}|miss ${miss(o.value)}`);
}
