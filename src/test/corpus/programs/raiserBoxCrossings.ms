// @stdout: 10 s4 -1 5 3 10 7
// note: a value that crosses between a plain register class and a Dyn register must keep its meaning: a number | null local assigned in a loop, a string | number union passed to a function and returned, a T | undefined field read into a Dyn register, a ref parameter written through its address, and the same union read and written by a closure made inside a method.

function pick(v: string | number): string | number { return v; }

function sumTo(n: number): number {
	let acc: number | null = null;
	for (let i = 0; i < n; i++) { acc = (acc == null ? 0 : acc) + i; }
	return acc == null ? -1 : acc;
}

class Holder { v: number | undefined = undefined; }

function bump(ref n: number): void { n = n + 1; }

class Acc {
	total: number | null = null;
	run(): number {
		const add = (k: number): void => { this.total = (this.total == null ? 0 : this.total) + k; };
		for (let i = 1; i <= 4; i++) add(i);
		return this.total == null ? -1 : this.total;
	}
}

const h = new Holder();
const first = h.v == undefined ? -1 : h.v;
h.v = 5;
const second = h.v == undefined ? -1 : h.v;
let k: number = 1;
bump(k);
bump(k);
const word: string | number = pick(7);
console.log(`${sumTo(5)} ${pick("s")}${pick(4)} ${first} ${second} ${k} ${new Acc().run()} ${word}`);
