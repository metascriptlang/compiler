// Parity program — a runtime converter applies at a typed slot, an argument,
// a return, `as U` and a nullable slot of its target; a generic formal and a
// condition keep the value as it is.
//
// @stdout: slot 41|arg 42|ret 43|as box#44|maybe 1.5|generic 45|cond yes
// @exit: 0

interface Box { n: int32; }
type Seconds = distinct float64;

converter boxToInt(b: Box): int32 { return b.n; }
converter boxToText(b: Box): string { return "box#" + String(b.n); }
converter toSeconds(x: float64): Seconds { return x as Seconds; }

function take(n: int32): int32 { return n; }
function read(b: Box): int32 { return b; }
function same<T>(v: T): T { return v; }

const slot: int32 = { n: 41 } as Box;
const arg = take({ n: 42 } as Box);
const ret = read({ n: 43 });
const box: Box = { n: 44 };
const text = box as string;
const x: float64 = 1.5;
const maybe: Seconds | null = x;
const kept = same({ n: 45 } as Box);
const cond = box ? "yes" : "no";

console.log(`slot ${slot}|arg ${arg}|ret ${ret}|as ${text}|maybe ${maybe != null ? maybe as float64 : 0}|generic ${kept.n}|cond ${cond}`);
