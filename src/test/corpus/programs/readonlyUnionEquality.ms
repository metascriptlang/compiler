// @stdout: bold=true,false,false,true cmp=true,false,true,false,false,true lit=true,true,false eq=true,false mix=true,true
// note: `===` on a nullable literal union and on `number | string | null` binds nullableEquals' T to the whole union, so Readonly<T | null> is the union itself: a literal on either side, both operands nullable, a string-literal union weight, a dimension-style `number | string | null`, and the generic Readonly<T | null> called with a union directly.

type FontWeight = "100" | "bold" | "normal" | "900";
type StyleValue = number | string | null;

function isBold(w: FontWeight | null): boolean { return w === "bold" || w === "900"; }
function cmp(v: StyleValue, p: StyleValue): boolean { return v === p; }
function litRight(w: FontWeight | null): boolean { return w === "bold"; }
function litLeft(w: FontWeight | null): boolean { return "100" === w; }
function same<T>(a: Readonly<T | null>, b: Readonly<T | null>): boolean { return a == null ? b == null : (b != null && a == b); }

let prev: StyleValue = null;
function changed(v: StyleValue): boolean {
	if (v === prev) { return false; }
	prev = v;
	return true;
}

const none: FontWeight | null = null;
const bold: FontWeight | null = "bold";
const nine: FontWeight | null = "900";
const hundred: FontWeight | null = "100";
const n: StyleValue = 1;
const s: StyleValue = "a";
const nul: StyleValue = null;

console.log(`bold=${isBold(bold)},${isBold(none)},${isBold(hundred)},${isBold(nine)}`
	+ ` cmp=${cmp(n, 1)},${cmp(n, s)},${cmp(nul, nul)},${cmp(nul, s)},${cmp(s, nul)},${cmp(s, "a")}`
	+ ` lit=${litRight(bold)},${litLeft(hundred)},${litLeft(none)}`
	+ ` eq=${same<string | number>("a", "a")},${same<string | number>("a", 1)}`
	+ ` mix=${changed(n)},${changed(s)}`);
