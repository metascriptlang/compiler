// @stdout: a1 b1 c1 | 6
// @stdout: a2 b2 c2 | 6
// @stdout: a3 b3 c3 | 6
// note: a Vec<Vec<string>> field read inside a loop is released once per inner Vec by its struct's destroy hook, so the next call allocates on a clean heap.

struct Lines { rows: Vec<Vec<string>>; }

function makeLines(n: int32): Lines {
	return { rows: [[`a${n}`], [`b${n}`, `c${n}`]] };
}

function render(n: int32): string {
	const lines = makeLines(n);
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		const row = lines.rows[1];
		total = total + row.length;
	}
	return `${lines.rows[0][0]} ${lines.rows[1][0]} ${lines.rows[1][1]} | ${total}`;
}

for (let n: int32 = 1; n <= 3; n++) console.log(render(n));
