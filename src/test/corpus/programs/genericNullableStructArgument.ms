// @stdout: 1111|110110|y q d inner|10
// note: a struct that travels by pointer reaches a generic `C | null` parameter as the instance's own nullable carrier.
struct Box { name: string; title: string; }
struct Triple { a: string; b: string; c: string; }
struct Item { label: string; inner: Box; }
function take<C>(value: C | null): int32 { return value === null ? 0 : 1; }
function pair<C>(a: C, b: C | null): int32 { return b === null ? 0 : 1; }
function pick<C>(value: C | null, fallback: C): C { return value === null ? fallback : value; }
function num<T>(a: T, b: T | null): int32 { return b === null ? 0 : 1; }
const box: Box = { name: "x", title: "y" };
const nb: Box | null = { name: "p", title: "q" };
const none: Box | null = null;
const triple: Triple | null = { a: "1", b: "2", c: "3" };
const item: Item | null = { label: "l", inner: { name: "inner", title: "t" } };
console.log(String(take<Box>(nb)) + String(take(nb)) + String(take(triple)) + String(take(item)));
console.log(String(pair(box, box)) + String(pair(box, nb)) + String(pair(box, none)) + String(take(item)) + String(take<Box>(box)) + String(take(none)));
const dflt: Box = { name: "d", title: "d" };
const fromItem: Item = { label: "f", inner: dflt };
console.log(pick(box, dflt).title + " " + pick(nb, dflt).title + " " + pick(none, dflt).title + " " + pick(item, fromItem).inner.name);
const i: int32 = 3;
console.log(String(num(1.5, i)) + String(num<number>(2.5, null)));
