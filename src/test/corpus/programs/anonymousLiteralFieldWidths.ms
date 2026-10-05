// Parity program — object literals whose fields differ in type are distinct anonymous types, and an
// array, conditional or return of them widens each field to hold every value, as TypeScript prints.
//
// @stdout: 11 4294967295 | 4294967295 11 | 4294967295 11 | 11 5 4294967295 6 | 11 18446744073709551615 | 11 1.5 || 11 4294967295 | 200 18446744073709551615 | 2 2.5 | 7 hi | 11 4294967295 | 11 5 4294967295 6 | 4294967295 1 | 11 4294967295

class Foo { x: int32 = 7; }
class Bar { y: string = "hi"; }

function pick(c: boolean) {
	return c ? { low: 11 } : { low: 4294967295 };
}

function ret(c: boolean) {
	if (c) return { low: 11, tag: 5 };
	return { low: 4294967295, tag: 6 };
}

const k: uint8 = 200;
const u: uint64 = 18446744073709551615;
const last = [{ low: 11 }, { low: 4294967295 }];
const first = [{ low: 4294967295 }, { low: 11 }];
const middle = [{ low: 1 }, { low: 4294967295 }, { low: 11 }];
const nested = [{ p: { low: 11, tag: 5 } }, { p: { low: 4294967295, tag: 6 } }];
const unsigned = [{ v: 11 }, { v: u }];
const fraction = [{ low: 11 }, { low: 1.5 }];
const a = { low: 11 };
const b = { low: 4294967295 };
const narrow = { v: k };
const wide = { v: u };
const ints = { v: [1, 2] };
const floats = { v: [1.5, 2.5] };
const foo = { v: new Foo() };
const bar = { v: new Bar() };
const h: int64[] = [4294967295];
const spread = [...h, 1];
const tail: int32[] = [11];
const widened = [...tail, 4294967295];
console.log(`${last[0].low} ${last[1].low} | ${first[0].low} ${first[1].low} | ${middle[1].low} ${middle[2].low} | ${nested[0].p.low} ${nested[0].p.tag} ${nested[1].p.low} ${nested[1].p.tag} | ${unsigned[0].v} ${unsigned[1].v} | ${fraction[0].low} ${fraction[1].low} || ${a.low} ${b.low} | ${narrow.v} ${wide.v} | ${ints.v[1]} ${floats.v[1]} | ${foo.v.x} ${bar.v.y} | ${pick(true).low} ${pick(false).low} | ${ret(true).low} ${ret(true).tag} ${ret(false).low} ${ret(false).tag} | ${spread[0]} ${spread[1]} | ${widened[0]} ${widened[1]}`);
