let trace = "";
let indexReads = 0;

function firstRow(): int32 {
	indexReads += 1;
	return 0;
}

function windowOf(s: Readonly<Span<int32>>): void {
	for (const x of s[1..3]) trace += "span " + x.toString() + ";";
}

const v: Vec<int32> = [1, 2, 3, 4];
for (const x of v[1..3]) trace += "vec " + x.toString() + ";";
const a: int32[] = [5, 6, 7];
for (const x of a[0...1]) trace += "array " + x.toString() + ";";
const fixed: int32[3] = [8, 9, 10];
for (const x of fixed[1..3]) trace += "sized " + x.toString() + ";";
const rows: int32[][] = [[3, 4, 5], [1, 2]];
for (const x of rows[firstRow()][1..3]) trace += "row " + x.toString() + ";";
windowOf(v);

const expected = "vec 2;vec 3;array 5;array 6;sized 9;sized 10;row 4;row 5;span 2;span 3;";
console.log(trace + " index reads " + indexReads.toString());
if (trace != expected || indexReads != 1) throw new Error("expected " + expected + " with one index read");
