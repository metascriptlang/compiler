// @stdout: top=true,false,false,true empty=true,false str=true,false field=true,false,true nested=true,false generic=true,false ref=false,true
// note: `==` and `!=` on two `Vec<T>` compare length, then element by element: ints, strings, a `Vec` field of a struct, a `Vec` of `Vec`, a `Vec` field of a generic struct instance. A `T[]` stays a reference and compares by identity. Same output on every backend.

struct Run { units: int32; }

struct Line { text: string; runs: Vec<Run>; }

struct Buf<T> { v: Vec<T>; n: int32; }

function main(): void {
	const a: Vec<int32> = [1, 2, 3];
	const b: Vec<int32> = [1, 2, 3];
	const c: Vec<int32> = [1, 2];
	const e1: Vec<int32> = [];
	const e2: Vec<int32> = [];
	const s1: Vec<string> = ["x", "y"];
	const s2: Vec<string> = ["x", "y" + ""];
	const s3: Vec<string> = ["x", "z"];
	const l1: Line = { text: "a", runs: [{ units: 1 }] };
	const l2: Line = { text: "a", runs: [{ units: 1 }] };
	const l3: Line = { text: "a", runs: [{ units: 2 }] };
	const l4: Line = { text: "a", runs: [] };
	const l5: Line = { text: "a", runs: [] };
	const n1: Vec<Vec<int32>> = [[1], [2, 3]];
	const n2: Vec<Vec<int32>> = [[1], [2, 3]];
	const n3: Vec<Vec<int32>> = [[1], [2, 4]];
	const g1: Buf<int32> = { v: [1, 2], n: 1 };
	const g2: Buf<int32> = { v: [1, 2], n: 1 };
	const g3: Buf<int32> = { v: [1, 3], n: 1 };
	const r1: int32[] = [1];
	const r2: int32[] = [1];
	console.log(`top=${a == b},${a == c},${a != b},${a != c} empty=${e1 == e2},${e1 == a} str=${s1 == s2},${s1 == s3}`
		+ ` field=${l1 == l2},${l1 == l3},${l4 == l5} nested=${n1 == n2},${n1 == n3}`
		+ ` generic=${g1 == g2},${g1 == g3} ref=${r1 == r2},${r1 == r1}`);
}

main();
