// @stdout: x 1 a none | y y | b
// note: an alias whose union already holds null is the same type as that alias with `| null` added, so a value or a callback crosses between them: in a direct assignment, a callback for a generic `T | null` parameter, a two-member alias, and an alias imported from another module.

import { Shown } from "./alias";

type V = number | string | null;
type S = string | null;

function run<T>(compute: (prev: T | null) => T): T { return compute(null); }
function show(v: V): string { return v === null ? "none" : `${v}`; }

const a: V = 1;
const b: V | null = a;
const c: V = b;
const n: V | null = null;
const fromRun = run<V>((last: V): V => last === null ? "x" : last);
const parts: string[] = [`${fromRun} ${show(c)} ${run<S>((last: S): S => "a")} ${show(n)}`];
const s: S | null = "y";
const back: S = s;
const shown: Shown | null = "y";
parts.push(`${back} ${run<Shown>((last: Shown): Shown => shown)}`);
const keep: (prev: S | null) => S = (prev: S): S => "b";
parts.push(`${keep(null)}`);
console.log(parts.join(" | "));
