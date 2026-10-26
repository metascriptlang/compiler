// @stdout: tail=7,other ifElse=zero,small,big nested=2,1,0 maybe=hit,none bare=early|late loop=1+3+ ret=13,1,99 arrow=10,20,10 path=.f[]
// note: a block arm of a match used as a value gives its last expression, through a trailing if/else or a nested match; `return` always leaves the function, so in a returned match or an arrow body it returns the function's value and in a bound match a bare `return;` exits early.

function tail(v: int32): string {
	const s = match (v) {
		0 => {
			const n = 3 + 4;
			`${n}`
		},
		_ => { "other" },
	};
	return s;
}

function size(v: int32): string {
	const s: string = match (v) {
		0 => "zero",
		_ => {
			if (v < 10) { "small" } else { "big" }
		},
	};
	return s;
}

function nested(a: int32, b: boolean): int32 {
	const r = match (a) {
		0 => {
			const flag = !b;
			match (flag) {
				true => 1,
				false => 2,
			}
		},
		_ => 0,
	};
	return r;
}

function find(key: string): string | null {
	const found: string | null = match (key) {
		"a" => {
			const v = "hit";
			v
		},
		_ => { null },
	};
	return found;
}

let log = "";
function bare(v: int32): void {
	const s = match (v) {
		0 => {
			log = log + "early|";
			return;
		},
		_ => "late",
	};
	log = log + s;
}

function loop(): string {
	let out = "";
	for (let i: int32 = 0; i < 5; i++) {
		const s = match (i) {
			0 | 2 => { continue; },
			4 => { break; },
			_ => { `${i}` },
		};
		out = out + s + "+";
	}
	return out;
}

function ret(v: int32): int32 {
	return match (v) {
		0 | 1 => {
			if (v == 0) return 13;
			1
		},
		_ => 99,
	};
}

const pick = (v: int32): int32 => match (v) {
	0 => { return 10; },
	_ => { 20 },
};

function apply(f: (n: int32) => int32, n: int32): int32 {
	return f(n);
}

enum Kind { Leaf, Box, List, Pair }
class T { kind: Kind = Kind.Leaf; inner: T | null = null; kids: T[] = []; names: string[] = []; }
function path(t: T | null, seen: T[]): string | null {
	if (t == null || seen.includes(t)) return null;
	if (t.kind == Kind.Leaf) return "";
	seen.push(t);
	return match (t.kind) {
		Kind.Box => path(t.inner, seen),
		Kind.List => {
			const p = path(t.inner, seen);
			p == null ? null : "[]" + p
		},
		Kind.Pair => {
			for (let i = 0; i < t.kids.length; i += 1) {
				const p = path(t.kids[i], seen);
				if (p != null) return (i < t.names.length ? "." + t.names[i] : "[" + i + "]") + p;
			}
			return null;
		},
		_ => null,
	};
}
const leaf = new T();
const list = new T(); list.kind = Kind.List; list.inner = leaf;
const pair = new T(); pair.kind = Kind.Pair; pair.kids = [list]; pair.names = ["f"];

bare(0);
bare(1);
console.log(`tail=${tail(0)},${tail(1)} ifElse=${size(0)},${size(3)},${size(30)} nested=${nested(0, false)},${nested(0, true)},${nested(5, true)} maybe=${find("a") ?? "none"},${find("b") ?? "none"} bare=${log} loop=${loop()} ret=${ret(0)},${ret(1)},${ret(2)} arrow=${pick(0)},${pick(1)},${apply((n: int32): int32 => match (n) { 1 => match (n + 1) { 2 => 10, _ => 0 }, _ => 0 }, 1)} path=${path(pair, [])}`);
