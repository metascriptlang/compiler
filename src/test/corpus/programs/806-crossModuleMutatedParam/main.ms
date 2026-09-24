// @xfail(raiser): raiser runtime error: cannot evaluate 'shapes' at comptime: symbol kind is Module
// @stdout: mutparam 12 1 11 22 16
// note: a callee that reassigns a struct or closure parameter takes it by pointer in C (the declaring module's mutatedParams). An importer used to read a per-module copy of the symbol whose mutatedParams was 0, declared the callee by value and passed the argument by value: C built and died with SIGBUS, JS was right. The namespace call is the same callee reached through `import * as`.
import { P, bump, twice } from "./shapes";
import * as shapes from "./shapes";

const p: P = { x: 1, y: 10 };
const r = bump(p);
const t = twice((n: int32): int32 => n + 5);
const q: P = { x: 20, y: 1 };
const nr = shapes.bump(q);
const nt = shapes.twice((n: int32): int32 => n * 4);
console.log(`mutparam ${r} ${p.x} ${t} ${nr} ${nt}`);
