// @stdout: static 1 2 flat 10 20 calls 11 22 recursive 3 6 modules 31 42 cross 2 4
// @exit: 0

import { first } from "./first";
import { second } from "./second";

struct A { x: int32; }
struct B { y: int32; }

function tag(this typeof A): uint64 { return 1; }
function tag(this typeof B): uint64 { return 2; }
function id(value: A): uint64 { return 10; }
function id(value: B): uint64 { return 20; }

@comptime function valueOf(value: int32): int32 { return value + 1; }
@comptime function valueOf(value: string): int32 { return value.length + 20; }

function total(value: int32): int32 {
	if (value == 0) return 0;
	return 1 + total(value - 1);
}
function total(value: string): int32 {
	if (value.length == 0) return 0;
	return 2 + total(value.slice(1));
}

function choose(value: int32): int32 { return choose("ok"); }
function choose(value: string): int32 { return value.length; }

const a: uint64 = @comptime { return A.tag(); };
const b: uint64 = @comptime { return B.tag(); };
const c: uint64 = @comptime { const value: A = { x: 1 }; return id(value); };
const d: uint64 = @comptime { const value: B = { y: 1 }; return id(value); };
const e = valueOf(10);
const f = valueOf("ab");
const g: int32 = @comptime { return total(3); };
const h: int32 = @comptime { return total("abc"); };
const i: int32 = @comptime { return first(); };
const j: int32 = @comptime { return second(); };
const k: int32 = @comptime { return choose(1); };
const l: int32 = @comptime { return choose("abcd"); };
console.log(`static ${a.toString()} ${b.toString()} flat ${c.toString()} ${d.toString()} calls ${e} ${f} recursive ${g} ${h} modules ${i} ${j} cross ${k} ${l}`);
