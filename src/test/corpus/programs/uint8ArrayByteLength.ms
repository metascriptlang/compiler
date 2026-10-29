// @stdout: plain 3 7 true true 2 30 3

function byteLength(this a: uint8[]): number { return a.length * 10; }

function measure(a: uint8[]): number {
	const m: number = a.byteLength;
	return m;
}

const lit: uint8[] = [1, 2, 3];
let grown: uint8[] = [];
grown.push(9);
grown.push(8);
const n: number = lit.byteLength;
const total = lit.byteLength + grown.byteLength * 2;
console.log(`plain ${n} ${total} ${lit.byteLength == 3} ${grown.byteLength < lit.byteLength} ${measure(grown)} ${lit.byteLength()} ${lit.length}`);
