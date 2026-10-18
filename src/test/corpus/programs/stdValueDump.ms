// @stdout: plain={"x":1,"y":"a\"q"} generic={"item":3} nestedGeneric={"item":{"x":1,"y":"a\"q"}} arrays={"id":1,"fixed":[1,2,3],"names":["u","v"]} nullable={"id":1,"n":5},{"id":2,"n":null} tuple=[1,"a"] result={"ok":true,"value":1},{"ok":false,"error":"bad"} enum={"c":1,"d":2.5,"b":true} chain={"label":"a","next":{"label":"b","next":null}} forms={"x":1,"y":"a\"q"}|{"x":1,"y":"a\"q"}|{"x":1,"y":"a\"q"} user=custom
// @exit: 0
// Parity program: the text of a value type without a user `toString` is one generic std routine
// that folds the type's fields on every backend: a struct, a generic struct instance, a fixed
// array and a `T[]` field, a nullable field printed as its value, a tuple, a `Result`, an enum
// field as its ordinal, and a self-referential class to full depth with null ending the walk. The
// interpolation and `x.toString()` forms agree, and a user `toString` wins.

struct P { x: int32; y: string; }
struct Box<T> { item: T; }
struct Arrays { id: int32; fixed: int32[3]; names: string[]; }
struct Nullable { id: int32; n: int32 | null; }
enum Color { Red, Green }
struct Mixed { c: Color; d: float64; b: boolean; }
class Chain { label: string = ""; next: Chain | null = null; }
struct Label { text: string; }

function toString(this l: Label): string { return "custom"; }

function main(): void {
	const a: P = { x: 1, y: "a\"q" };
	const generic: Box<int32> = { item: 3 };
	const nested: Box<P> = { item: a };
	const arrays: Arrays = { id: 1, fixed: [1, 2, 3], names: ["u", "v"] };
	const present: Nullable = { id: 1, n: 5 };
	const absent: Nullable = { id: 2, n: null };
	const tuple: [int32, string] = [1, "a"];
	const ok: Result<int32, string> = Result.ok(1);
	const bad: Result<int32, string> = Result.err("bad");
	const mixed: Mixed = { c: Color.Green, d: 2.5, b: true };
	const first = new Chain();
	first.label = "a";
	first.next = new Chain();
	first.next.label = "b";
	const label: Label = { text: "t" };
	console.log(`plain=${a} generic=${generic} nestedGeneric=${nested} arrays=${arrays} nullable=${present},${absent} tuple=${tuple} result=${ok},${bad} enum=${mixed} chain=${first} forms=${a}|${a.toString()}|${String(a)} user=${label}`);
}
main();
