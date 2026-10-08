// @stdout: 4 2|1.5 0.5|3 2.5|8 14 9.5|1 2 3
// note: an operand or argument whose type comes from its slot is typed once the slot is known.
// A float literal arm of a ternary beside a float32 arm takes float32 (CK-135 applied to the
// join); an object literal operand takes the parameter type of the declared operators that
// match the other operand; an object literal argument of an overloaded extension waits for the
// winner; a string literal picks the overload whose literal parameter type it is.
import { Vec4, Mat4, Grid } from "./lib";

const out: string[] = [];
const a: float32 = 0.5;
const b: float32 = 4.0;
function f(p: int32): float32 { return (p == 0 ? 1.0 : a) * b; }
function g(p: int32): float32 { return p == 0 ? a : (p == 1 ? 1.5 : 2.5); }
out.push(`${f(0)} ${f(1)}`);
out.push(`${g(1)} ${g(0)}`);

const m: Mat4 = { s: 2.0 };
const clip: Vec4 = { x: 1.5, y: a, z: a, w: 1.0 } * m;
const sum: float32 = m + { x: 0.0, y: 0.0, z: 0.0, w: 0.5 };
out.push(`${clip.x} ${sum}`);

const grid: Grid = { index: 0 };
out.push(`${grid.put({ view: 7, w: 8.0 })} ${grid.put(2, { x: 9.0, tile: { view: 11, w: 12.0 } })} ${grid.put(1, { x: 0.0, tile: { view: 1, w: 8.5 } })}`);

function pick(key: "x"): int32 { return 1; }
function pick(key: "y"): int32 { return 2; }
function pick(key: "z" | "w"): int32 { return 3; }
out.push(`${pick("x")} ${pick("y")} ${pick("w")}`);
console.log(out.join("|"));
