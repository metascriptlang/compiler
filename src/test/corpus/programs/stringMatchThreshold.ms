// @stdout: nine=0,3,5,6,8,-1,-1,-1,4 eight=0,3,5,6,-1,-1,-1,-1,4
// note: a string match with nine arms (hash switch) and one with eight (if-chain) pick the same arm for a literal key, a key built at run time, a key sharing a hash bucket with another arm, the empty string, and a prefix or extension of an arm.

function nine(s: string): int32 {
	return match (s) {
		"a0" => 0,
		"a1" => 1,
		"a2" => 2,
		"a3" => 3,
		"a4" => 4,
		"Aa" => 5,
		"B@" => 6,
		"a7" => 7,
		"a8" => 8,
		_ => -1,
	};
}

function eight(s: string): int32 {
	return match (s) {
		"a0" => 0,
		"a1" => 1,
		"a2" => 2,
		"a3" => 3,
		"a4" => 4,
		"Aa" => 5,
		"B@" => 6,
		"a7" => 7,
		_ => -1,
	};
}

function build(a: string, b: string): string {
	return a + b;
}

const keys: string[] = ["a0", build("a", "3"), "Aa", build("B", "@"), build("a", "8"), "", "a", "a00", build("a", "4")];
const n: int32[] = [];
const e: int32[] = [];
for (const k of keys) {
	n.push(nine(k));
	e.push(eight(k));
}
console.log(`nine=${n.join(",")} eight=${e.join(",")}`);
