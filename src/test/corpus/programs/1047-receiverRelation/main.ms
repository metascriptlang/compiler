// @stdout: abc! lit! v:x nil 14 10 5 2 5
// note: a method-call receiver is matched by the relation an ordinary call uses for its formal: a string literal into string, a value or null into `T | null`, an integer into number, and an alias by its target.
type Buffer = string;
type Count = int32;
function shout(this s: string): string { return s + "!"; }
function orNil(this s: string | null): string { return s == null ? "nil" : "v:" + s; }
function twice(this n: number): number { return n * 2; }
function bufferSize(this b: Buffer): number { return b.length; }
function countUp(this c: Count): int32 { return c + 1; }

const lit = "abc";
const s: string = "x";
let m: string | null = null;
const k = 7;
const b: Buffer = "hello";
const c: Count = 4;
console.log(`${lit.shout()} ${"lit".shout()} ${s.orNil()} ${m.orNil()} ${k.twice()} ${(5).twice()} ${b.bufferSize()} ${"zz".bufferSize()} ${c.countUp()}`);
