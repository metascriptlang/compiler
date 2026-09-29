// @xfail(raiser): struct == compares by reference on raiser (card 2026-09-29-raiser-struct-equality-by-reference)
// @stdout: top=true,false,false,true str=true,false field=true,false nested=true,false generic=true,false
// note: `==` and `!=` on two fixed arrays `T[N]` compare them element by element: bytes, strings, structs holding a fixed array, a fixed-array field of a struct and of a generic struct instance. Same output on every backend.

struct Cell { a: uint8; s: string; }

struct Line { v: int32[2]; }

struct Row { id: int32; cells: Cell[2]; }

struct Buf<T> { v: T[2]; n: int32; }

function main(): void {
	const a: uint8[4] = [1, 2, 3, 4];
	const b: uint8[4] = [1, 2, 3, 4];
	const c: uint8[4] = [1, 2, 3, 5];
	const s1: string[2] = ["x", "y"];
	const s2: string[2] = ["x", "y" + ""];
	const s3: string[2] = ["x", "z"];
	const r1: Row = { id: 1, cells: [{ a: 1, s: "p" }, { a: 2, s: "q" }] };
	const r2: Row = { ...r1 };
	const r3: Row = { id: 1, cells: [{ a: 1, s: "p" }, { a: 2, s: "r" }] };
	const l1: Line[2] = [{ v: [1, 2] }, { v: [3, 4] }];
	const l2: Line[2] = [{ v: [1, 2] }, { v: [3, 4] }];
	const l3: Line[2] = [{ v: [1, 2] }, { v: [3, 5] }];
	const g1: Buf<int32> = { v: [1, 2], n: 1 };
	const g2: Buf<int32> = { v: [1, 2], n: 1 };
	const g3: Buf<int32> = { v: [1, 3], n: 1 };
	console.log(`top=${a == b},${a == c},${a != b},${a != c} str=${s1 == s2},${s1 == s3}`
		+ ` field=${r1 == r2},${r1 == r3} nested=${l1 == l2},${l1 == l3}`
		+ ` generic=${g1 == g2},${g1 == g3}`);
}

main();
