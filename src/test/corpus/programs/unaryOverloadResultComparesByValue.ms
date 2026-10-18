// @stdout: true|true|true|true|false|true
// @exit: 0

struct V {
	x: float32;
}

struct Flags {
	bits: int32;
}

function `-`(this a: V): V { return { x: -a.x }; }
function `+`(this a: V, b: V): V { return { x: a.x + b.x }; }
function `!`(this f: Flags): Flags { return { bits: f.bits == 0 ? 1 : 0 }; }

const v: V = { x: 1.0 };
const n = -v;
const f: Flags = { bits: 5 };
const minus = -v == { x: -1.0 } as V;
const local = n == { x: -1.0 } as V;
const binary = v + v == { x: 2.0 } as V;
const nested = -(-v) == v;
const differs = -v != { x: -1.0 } as V;
const bang = { bits: 0 } as Flags == !f;
console.log(`${minus}|${local}|${binary}|${nested}|${differs}|${bang}`);
