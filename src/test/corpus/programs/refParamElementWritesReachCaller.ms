// @stdout: one 10 | cell 10 | row 7/1 | refCell 7 | refRead 9 | refRow 7/1 | at 9 | whole 7 | value 7 | read 6
// note: a write to an element of a ref array parameter, through one index or two, with = or +=, reaches the caller's Vec or T[]; reads through two indices of a ref T[][] see the caller's array.

function setOne(ref g: Vec<int32>): void {
	g[1] = 7;
}

function addOne(ref g: Vec<int32>): void {
	g[1] += 3;
}

function setAt(ref g: Vec<int32>, i: int32, x: int32): void {
	g[i] = x;
}

function setRow(ref g: Vec<Vec<int32>>): void {
	g[1] = [7];
}

function setCell(ref g: Vec<Vec<int32>>): void {
	g[1][0] = 7;
}

function addCell(ref g: Vec<Vec<int32>>): void {
	g[1][0] += 3;
}

function readCell(ref g: Vec<Vec<int32>>): int32 {
	return g[1][0] + g[1].length;
}

function setRefCell(ref g: int32[][]): void {
	g[1][0] = 7;
}

function setRefRow(ref g: int32[][]): void {
	g[1] = [7];
}

function readRefCell(ref g: int32[][]): int32 {
	return g[1][0] + g[1].length;
}

function wholeWrite(ref g: Vec<int32>): void {
	g = [1, 7];
}

function valueParam(g: int32[][]): void {
	g[1][0] = 7;
}

function main(): void {
	let a: Vec<int32> = [1, 4];
	setOne(a);
	addOne(a);
	let b: Vec<Vec<int32>> = [[1, 2, 3], [4, 5]];
	setCell(b);
	addCell(b);
	const cell = b[1][0];
	setRow(b);
	let c: int32[][] = [[1, 2, 3], [4, 5]];
	setRefCell(c);
	const refCell = c[1][0];
	const refRead = readRefCell(c);
	setRefRow(c);
	let d: Vec<int32> = [0, 0, 0];
	setAt(d, 2, 9);
	let e: Vec<int32> = [1, 4];
	wholeWrite(e);
	let f: int32[][] = [[1], [4, 5]];
	valueParam(f);
	let h: Vec<Vec<int32>> = [[1], [4, 5]];
	const parts: string[] = [];
	parts.push(`one ${a[1]}`);
	parts.push(`cell ${cell}`);
	parts.push(`row ${b[1][0]}/${b[1].length}`);
	parts.push(`refCell ${refCell}`);
	parts.push(`refRead ${refRead}`);
	parts.push(`refRow ${c[1][0]}/${c[1].length}`);
	parts.push(`at ${d[2]}`);
	parts.push(`whole ${e[1]}`);
	parts.push(`value ${f[1][0]}`);
	parts.push(`read ${readCell(h)}`);
	console.log(parts.join(" | "));
}

main();
