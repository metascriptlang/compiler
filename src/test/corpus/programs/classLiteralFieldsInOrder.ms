// @stdout: order abc 1 2 3 | nested 5 6 true true | name 7 8 | await 9 10 true | omitted 4 0 2
// note: a class-typed literal evaluates its values left to right into an instance of its class, a literal inside a value builds its own instance, a local spelled like a generated name keeps its value, and a value that awaits still builds the instance.
class P { x: int32; y: int32; z: int32; }
class Pair { left: P; right: P; }
class Q { a: int32; b: int32 = 2; c: int32; }

let trace = "";
function step(tag: string, v: int32): int32 { trace += tag; return v; }

const p: P = { x: step("a", 1), y: step("b", 2), z: step("c", 3) };
const pair: Pair = { left: { x: 5, y: 0, z: 0 }, right: { x: 6, y: 0, z: 0 } };
function named($o: int32, $o1: int32): P { return { x: $o, y: $o1, z: 0 }; }
const n = named(7, 8);
async function later(v: int32): Promise<int32> { return v; }
const w: P = { x: await later(9), y: 10, z: 0 };
const q: Q = { a: 4 };
console.log(`order ${trace} ${p.x} ${p.y} ${p.z} | nested ${pair.left.x} ${pair.right.x} ${pair.left instanceof P} ${pair instanceof Pair} | name ${n.x} ${n.y} | await ${w.x} ${w.y} ${w instanceof P} | omitted ${q.a} ${q.c} ${q.b}`);
