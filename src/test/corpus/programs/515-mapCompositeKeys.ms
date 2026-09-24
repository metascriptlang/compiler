// @xfail(raiser): raiser runtime error: attempt to access a nil address
// Parity program — Map keyed by an enum or a value struct hashes the key by value: an enum by
// its ordinal, a struct by folding each field's hash. A class key keeps its identity. Rides on
// two checker rules: an enum value takes extension methods, and among tied generic extensions
// the more specialized receiver wins.
//
// @skip-js: the JS Map compares struct keys by reference, not by value
// @stdout: enum=true,false label=green struct=true,2,false,2 param=true nested=7 class=true,false spec=box,any
// @exit: 0

enum Color { Red, Green, Blue }

struct Pos { x: int32; y: string; }

struct Tile { at: Pos; tint: Color; weight: float64; }

class Handle { id: int32 = 0; }

struct Box<E> { item: E; }

function label(this c: Color): string { return c == Color.Green ? "green" : "other"; }

function kind<T>(this v: T): string { return "any"; }

function kind<E>(this b: Box<E>): string { return "box"; }

function holds(m: Map<Pos, int32>, k: Pos): boolean { return m.has(k); }

function main(): void {
	const byColor = new Map<Color, int32>();
	byColor.set(Color.Green, 1);

	const byPos = new Map<Pos, int32>();
	byPos.set({ x: 1, y: "a" }, 1);
	byPos.set({ x: 1, y: "b" }, 2);
	const a: Pos = { x: 1, y: "a" };
	const b: Pos = { x: 1, y: "b" };

	const byTile = new Map<Tile, int32>();
	byTile.set({ at: { x: 2, y: "z" }, tint: Color.Blue, weight: 1.5 }, 7);

	const h1 = new Handle();
	const h2 = new Handle();
	const byHandle = new Map<Handle, int32>();
	byHandle.set(h1, 1);

	const box: Box<int32> = { item: 3 };
	console.log(`enum=${byColor.has(Color.Green)},${byColor.has(Color.Red)} label=${Color.Green.label()} struct=${byPos.has(a)},${byPos.get(b) ?? -1},${byPos.has({ x: 2, y: "a" })},${byPos.size} param=${holds(byPos, a)} nested=${byTile.get({ at: { x: 2, y: "z" }, tint: Color.Blue, weight: 1.5 }) ?? -1} class=${byHandle.has(h1)},${byHandle.has(h2)} spec=${box.kind()},${(5 as int32).kind()}`);
}

main();
