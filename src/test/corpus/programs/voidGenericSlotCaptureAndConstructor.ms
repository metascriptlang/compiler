// @stdout: ran|nested 7 true|built true 2|pair 2 true
// @exit: 0
// note: a generic parameter instantiated as void has no runtime slot: a closure that reads it captures nothing and reads the null carrier, two captured parameters with one of them void read in a nested closure, and a constructor whose parameter is void runs its argument once and passes nothing.

function later<P>(f: (props: P) => string, props: P): () => string {
	return (): string => f(props);
}

function show(props: void): string {
	return "ran";
}

function nested<A, B>(a: A, b: B, f: (a: A, b: B) => string): () => () => string {
	return (): () => string => (): string => f(a, b);
}

function shown(n: number, v: void): string {
	return `nested ${n} ${v === undefined}`;
}

let effects = 0;
function nothing(): void {
	effects += 1;
}

class Box<D> {
	data: D;
	constructor(data: D) {
		this.data = data;
	}
}

class Pair<K, D> {
	key: K;
	data: D;
	constructor(key: K, data: D) {
		this.key = key;
		this.data = data;
	}
}

function main(): void {
	const run = later<void>(show, undefined);
	const deep = nested<number, void>(7, undefined, shown);
	const b = new Box<void>(nothing());
	const p = new Pair<number, void>(2, nothing());
	console.log(`${run()}|${deep()()}|built ${b !== null} ${effects}|pair ${p.key} ${p.data === undefined}`);
}
main();
