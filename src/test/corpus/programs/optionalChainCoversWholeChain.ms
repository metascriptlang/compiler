// @stdout: method=2,-1,5,-1 arg=-1,5 prop=7,-1 deep=-1,1,10 text=none,cee nested=-1,2 once=-1,2,2 held=set,null
// note: `a?.b.c(1).d` tests `a` once and skips every property read, call and method call after the `?.` when `a` holds null, as in TS: the whole chain is one null test and its type is the last link's type or null. A method keeps its receiver, a receiver expression with an effect runs once, and `a?.b?.c` tests twice.

class Box { v: int32 = 2; val(): int32 { return this.v; } add(n: int32): int32 { return this.v + n; } }
class Leaf { n: int32; label: string = "cee"; constructor(n: int32) { this.n = n; } more(): int32 { return this.n * 10; } }
class Mid { leaf: Leaf | null = null; make(n: int32): Leaf { return new Leaf(n); } }
class Top { mid: Mid = new Mid(); none: Mid | null = null; }

interface Inner { c: int32 }
interface Outer { b: Inner }

let evaluated = 0;
function boxOrNull(on: boolean): Box | null { evaluated = evaluated + 1; return on ? new Box() : null; }
function topOrNull(on: boolean): Top | null { return on ? new Top() : null; }
function outerOrNull(on: boolean): Outer | null { return on ? { b: { c: 7 } } : null; }

const noBox = boxOrNull(false);
const aBox = boxOrNull(true);
const method = `${aBox?.val() ?? -1},${noBox?.val() ?? -1},${aBox?.add(3) ?? -1},${noBox?.add(3) ?? -1}`;
evaluated = 0;
const arg = `${noBox?.add(3) ?? -1},${aBox?.add(3) ?? -1}`;

const noOuter = outerOrNull(false);
const anOuter = outerOrNull(true);
const prop = `${anOuter?.b.c ?? -1},${noOuter?.b.c ?? -1}`;

const noTop = topOrNull(false);
const aTop = topOrNull(true);
const deep = `${noTop?.mid.make(1).n ?? -1},${aTop?.mid.make(1).n ?? -1},${aTop?.mid.make(1).more() ?? -1}`;
const text = `${noTop?.mid.make(1).label ?? "none"},${aTop?.mid.make(1).label ?? "none"}`;
const nested = `${aTop?.none?.make(2).n ?? -1},${aTop?.mid?.make(2).n ?? -1}`;
const once = `${boxOrNull(false)?.val() ?? -1},${boxOrNull(true)?.val() ?? -1},${evaluated}`;
const heldBox = aBox?.add(1);
const heldNone = noBox?.add(1);
const held = `${heldBox === null ? "null" : "set"},${heldNone === null ? "null" : "set"}`;

console.log(`method=${method} arg=${arg} prop=${prop} deep=${deep} text=${text} nested=${nested} once=${once} held=${held}`);
