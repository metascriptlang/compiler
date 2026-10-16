// @stdout: slot=3,t tagged={"kind":"a","x":1},{"kind":"b","y":"q"} field={"u":"t","d":{"kind":"b","y":"q"}}
// @exit: 0
// Parity program: the text of a slot union of primitives and of a string-tagged union is its
// active variant on every backend, as a value and as a struct field.

type NamedU = int32 | string;
type Du = { kind: "a", x: int32 } | { kind: "b", y: string };
struct Holder { u: NamedU; d: Du; }

function num(n: int32): NamedU { return n; }
function str(s: string): NamedU { return s; }
function da(): Du { return { kind: "a", x: 1 }; }
function db(): Du { return { kind: "b", y: "q" }; }

function main(): void {
	const h: Holder = { u: str("t"), d: db() };
	console.log(`slot=${num(3)},${str("t")} tagged=${da()},${db()} field=${h}`);
}
main();
