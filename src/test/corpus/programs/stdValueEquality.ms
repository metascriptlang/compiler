// @stdout: result=true,false,true,false opt=true,false,true,false generic=true,false closure=true,false nested=true,false user=true,true text=custom
// @exit: 0
// Parity program: `==` and `!=` on a value type is one generic std routine that folds the type's
// fields on every backend. A `Result` compares like an Option (both ok with equal values, or both
// err with equal errors), a nullable value payload compares through its carrier against another
// carrier or a bare payload, a closure field compares by function and environment, and a user
// `==` or `toString` for a type wins over the std routine.

struct Pair { a: int32; b: string; }
struct Box<T> { item: T; }
struct Row { id: int32; cells: int32[3]; tag: [int32, string]; }
struct Maybe { id: int32; n: Pair | null; }
struct Held { f: () => int32; k: int32; }
struct Money { cents: int32; }
struct Label { text: string; }

function `==`(x: Money, y: Money): boolean { return x.cents / 100 == y.cents / 100; }
function toString(this l: Label): string { return "custom"; }

function same<T>(x: T, y: T): boolean { return x == y; }

function main(): void {
	const ok1: Result<int32, string> = Result.ok(1);
	const ok2: Result<int32, string> = Result.ok(1);
	const ok3: Result<int32, string> = Result.ok(2);
	const er1: Result<int32, string> = Result.err("e");
	const er2: Result<int32, string> = Result.err("e");
	const er3: Result<int32, string> = Result.err("f");
	const part0 = `result=${ok1 == ok2},${ok1 == ok3},${er1 == er2},${ok1 == er1}`;

	const n1: int32 | null = 4;
	const n2: int32 | null = 4;
	const n3: int32 | null = null;
	const p1: Pair | null = { a: 1, b: "x" };
	const p2: Pair | null = { a: 1, b: "x" };
	const p3: Pair | null = null;
	const part1 = `opt=${n1 == n2},${n1 == n3},${p1 == p2},${p1 != p2}`;

	const b1: Box<Pair> = { item: { a: 1, b: "x" } };
	const b2: Box<Pair> = { item: { a: 1, b: "x" } };
	const b3: Box<Pair> = { item: { a: 2, b: "x" } };
	const part2 = `generic=${same(b1, b2)},${same(b1, b3)}`;

	const g = (): int32 => 1;
	const h = (): int32 => 2;
	const f1: Held = { f: g, k: 1 };
	const f2: Held = { f: g, k: 1 };
	const f3: Held = { f: h, k: 1 };
	const part3 = `closure=${f1 == f2},${f1 == f3}`;

	const r1: Row = { id: 1, cells: [1, 2, 3], tag: [7, "t"] };
	const r2: Row = { id: 1, cells: [1, 2, 3], tag: [7, "t"] };
	const r3: Row = { id: 1, cells: [1, 2, 4], tag: [7, "t"] };
	const part4 = `nested=${r1 == r2},${r1 == r3}`;

	const m1: Money = { cents: 150 };
	const m2: Money = { cents: 199 };
	const m3: Money = { cents: 250 };
	const l1: Label = { text: "a" };
	const part5 = `user=${m1 == m2},${m1 != m3} text=${l1}`;
	console.log(part0 + " " + part1 + " " + part2 + " " + part3 + " " + part4 + " " + part5);
}
main();
