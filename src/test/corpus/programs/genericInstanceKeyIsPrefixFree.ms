// @stdout: 1 object|2 number|2|2
// @stdout: f1 1 x
// @stdout: f2 2 y
// @stdout: 1 x 2 | 1 y 3
// @stdout: int32 true | 7 false
// note: generic instances whose type arguments differ only in how nested tuples, unions or function parameters group their members are distinct instances with distinct bodies; they once shared one mangled name (one body on C, a duplicate declaration on JS). Tuples whose members group differently, or whose member is a string literal spelled like a type, once shared one C struct name.
type Pair = [string, int32];
type Nested = [int32, [string]];
type Fn1 = (a: [int32], b: string) => void;
type Fn2 = (a: [int32, string]) => void;

function show<A, B>(items: B[]): string { return `${items.length} ${typeof items[0]}`; }
function two<T>(x: T): number { return 2; }
function keep<F>(f: F): F { return f; }

function main(): void {
	const xs: Pair[] = [["a", 1]];
	const ys: int32[] = [1, 2];
	const a = show<[int32], Pair>(xs);
	const b = show<Nested, int32>(ys);

	const u1: [boolean | int32, string] = [true, "x"];
	const u2: [boolean | int32 | string] = ["y"];
	const c = two<[boolean | int32, string]>(u1);
	const d = two<[boolean | int32 | string]>(u2);
	console.log(`${a}|${b}|${c}|${d}`);

	const f1: Fn1 = (p, s) => { console.log(`f1 ${p[0]} ${s}`); };
	const f2: Fn2 = (p) => { console.log(`f2 ${p[0]} ${p[1]}`); };
	keep(f1)([1], "x");
	keep(f2)([2, "y"]);

	const g: [int32, [string, int32]] = [1, ["x", 2]];
	const h: [int32, [string], int32] = [1, ["y"], 3];
	console.log(`${g[0]} ${g[1][0]} ${g[1][1]} | ${h[0]} ${h[1][0]} ${h[2]}`);
	const l: ["int32", boolean] = ["int32", true];
	const n: [int32, boolean] = [7, false];
	console.log(`${l[0]} ${l[1]} | ${n[0]} ${n[1]}`);
}
main();
