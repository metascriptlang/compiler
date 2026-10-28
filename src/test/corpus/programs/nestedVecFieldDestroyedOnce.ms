// @stdout: call 1: 2
// @stdout: call 2: 2
// @stdout: call 3: 2
// note: a struct's destroy hook destroys each inner Vec of its Vec<Vec<int32>> field and then the outer Vec, releasing each inner Vec once, so the next call reuses that memory cleanly.

struct Table { rows: Vec<Vec<int32>>; }

function makeTable(): Table {
	return { rows: [[3, 4]] };
}

function firstRowLength(): int32 {
	const t = makeTable();
	const row = t.rows[0];
	return row.length;
}

for (let i: int32 = 1; i <= 3; i++) console.log(`call ${i}: ${firstRowLength()}`);
