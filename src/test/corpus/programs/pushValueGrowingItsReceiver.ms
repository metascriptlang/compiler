// @stdout: 40: 42/99/633954 42/99/633954 42/99/633954 42/99/633954 42/first/last 42/880
// note: a push evaluates its value before it checks the receiver's capacity, so a value whose evaluation pushes into that same receiver never overflows the storage the check sized; each line is k pushes made by the value, then the pushed value, into a module-level Vec, a local T[] (through a ref parameter), a row of each, a string Vec and a class T[].

class Leaf {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

let flat: Vec<int32> = [];
let rows: Vec<Vec<int32>> = [];
let words: Vec<string> = [];
let fillCount: int32 = 0;

function fillFlat(): int32 {
	for (let j: int32 = 0; j < fillCount; j++) flat.push(j);
	return 99;
}

function fillRow(): int32 {
	for (let j: int32 = 0; j < fillCount; j++) rows[0].push(j);
	return 99;
}

function fillWords(): string {
	for (let j: int32 = 0; j < fillCount; j++) words.push(`w${j}`);
	return "last";
}

function fillShared(ref values: int32[]): int32 {
	for (let j: int32 = 0; j < fillCount; j++) values.push(j);
	return 99;
}

function fillSharedRow(ref values: int32[][]): int32 {
	for (let j: int32 = 0; j < fillCount; j++) values[0].push(j);
	return 99;
}

function fillLeaves(ref values: Leaf[]): Leaf {
	for (let j: int32 = 0; j < fillCount; j++) values.push(new Leaf(j));
	return new Leaf(99);
}

function checksum(values: Span<int32>): int32 {
	let sum: int32 = 0;
	for (let i = 0; i < values.length; i++) sum = (sum * 31 + values[i] + i) % 1000003;
	return sum;
}

function report(values: Span<int32>): string {
	return `${values.length}/${values[values.length - 1]}/${checksum(values)}`;
}

function leafSum(values: Leaf[]): int32 {
	let sum: int32 = 0;
	for (let i = 0; i < values.length; i++) sum = sum + values[i].v;
	return sum;
}

function main(): void {
	for (let k: int32 = 0; k <= 40; k++) {
		fillCount = k;
		flat = [1];
		flat.push(fillFlat());
		let shared: int32[] = [1];
		shared.push(fillShared(shared));
		rows = [[1]];
		rows[0].push(fillRow());
		let sharedRows: int32[][] = [[1]];
		sharedRows[0].push(fillSharedRow(sharedRows));
		words = ["first"];
		words.push(fillWords());
		let leaves: Leaf[] = [new Leaf(1)];
		leaves.push(fillLeaves(leaves));
		const text = `${words.length}/${words[0]}/${words[words.length - 1]}`;
		console.log(`${k}: ${report(flat)} ${report(shared)} ${report(rows[0])} ${report(sharedRows[0])} ${text} ${leaves.length}/${leafSum(leaves)}`);
	}
}

main();
