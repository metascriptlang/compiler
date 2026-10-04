// @stdout: deep=true,false,true,true,false,true arr=true,false,true,false,true,true,false nullable=true,false,true,true,false,true
// note: `==` and `!=` compare by value one level deeper than 665, 666 and 668: a nullable struct holding a struct with string and float fields, a struct holding a fixed array of structs holding fixed arrays, a fixed array of tuples and of floats, a nullable fixed array of structs and a nullable tuple holding a struct. Same output on every lane.

struct Leaf { tag: string; w: float64; }
struct Mid { leaf: Leaf; n: int32; }
struct Pairs { v: int32[2]; }
struct Grid { rows: Pairs[2]; }
type Entry = [int32, string];

function midMake(tag: string): Mid | null {
	return { leaf: { tag: tag, w: 0.5 }, n: 1 };
}

function main(): void {
	const m1: Mid | null = { leaf: { tag: "a" + "b", w: 0.5 }, n: 1 };
	const m2: Mid | null = { leaf: { tag: "ab", w: 0.5 }, n: 1 };
	const m3: Mid | null = { leaf: { tag: "ab", w: 0.25 }, n: 1 };
	const none: Mid | null = null;
	const plainMid: Mid = { leaf: { tag: "ab", w: 0.5 }, n: 1 };
	const deep = `${m1 == m2},${m1 == m3},${m1 != m3},${plainMid == m1},${none == m1},${midMake("ab") == m2}`;

	const g1: Grid = { rows: [{ v: [1, 2] }, { v: [3, 4] }] };
	const g2: Grid = { rows: [{ v: [1, 2] }, { v: [3, 4] }] };
	const g3: Grid = { rows: [{ v: [1, 2] }, { v: [3, 5] }] };
	const t1: Entry[2] = [[1, "x"], [2, "y" + ""]];
	const t2: Entry[2] = [[1, "x"], [2, "y"]];
	const t3: Entry[2] = [[1, "x"], [2, "z"]];
	const f1: float64[3] = [0.5, 1.5, 2.5];
	const f2: float64[3] = [0.5, 1.5, 2.0 + 0.5];
	const arr = `${g1 == g2},${g1 == g3},${t1 == t2},${t1 == t3},${t1 != t3},${f1 == f2},${f1 != f2}`;

	const o1: Leaf[2] | null = [{ tag: "p", w: 1.0 }, { tag: "q", w: 2.0 }];
	const o2: Leaf[2] | null = [{ tag: "p", w: 1.0 }, { tag: "q", w: 2.0 }];
	const o3: Leaf[2] | null = [{ tag: "p", w: 1.0 }, { tag: "r", w: 2.0 }];
	const tn1: [Leaf, int32] | null = [{ tag: "k", w: 3.0 }, 9];
	const tn2: [Leaf, int32] | null = [{ tag: "k", w: 3.0 }, 9];
	const tn3: [Leaf, int32] | null = null;
	const nul = `${o1 == o2},${o1 == o3},${o1 != o3},${tn1 == tn2},${tn1 == tn3},${tn3 == tn3}`;
	console.log(`deep=${deep} arr=${arr} nullable=${nul}`);
}

main();
