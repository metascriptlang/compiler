// @stdout: a
// @stdout: b
// @stdout: 0 zero 0
// @stdout: a
// @stdout: b
// @stdout: 1 one 2
// @stdout: entries 0:x 1:y 2:z
// @stdout: hole y
// @stdout: owned alpha beta
// note: a for-of that destructures a generator's `yield [a, b]` binds each part in order, keeps each part's effect once,
// and owns a string part as the tuple did.

function tick(s: string, v: int32): int32 {
	console.log(s);
	return v;
}

const names: string[] = ["zero", "one"];

function* pairs(n: int32): Iterator<[int32, string, int32]> {
	for (let i: int32 = 0; i < n; i++) yield [tick("a", i), names[i], tick("b", i * 2)];
}

function* owned(): Iterator<[string, int32]> {
	yield [["al", "pha"].join(""), 1];
	yield [["be", "ta"].join(""), 2];
}

function main(): void {
	for (const [i, name, twice] of pairs(2)) console.log(`${i} ${name} ${twice}`);
	const xs: string[] = ["x", "y", "z"];
	let line = "entries";
	for (const [k, x] of xs.entries()) line += ` ${k}:${x}`;
	console.log(line);
	for (const [k, x] of xs.entries()) {
		if (k == 1) console.log(`hole ${x}`);
	}
	let words = "owned";
	for (const [w, _n] of owned()) words += ` ${w}`;
	console.log(words);
}

main();
