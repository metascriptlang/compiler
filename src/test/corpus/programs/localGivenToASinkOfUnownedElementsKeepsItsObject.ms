// @stdout: ca cab xb 2 | kc k 1 | pq 2
// note: a local handed at its last use to a `sink` parameter whose slot is an Unowned element (`splice` on an array of Unowned elements, a generic function that pushes its `sink` parameter into one) keeps its object to the end of its scope, so the edges the array now holds still read it: with a nullable Unowned element, with elements removed by the same call, and through a user function. Before a local outlived its last read the value moved into the call, the callee stored only the edge and released it, and the next read stopped with "an Unowned<N> edge was read after its N was destroyed".
class N { name: string; constructor(name: string) { this.name = name; } }
class H { ups: Unowned<N>[] = []; maybe: (Unowned<N> | null)[] = []; }

function put<T>(arr: T[], sink v: T): void { arr.push(v); }

function names(ups: Unowned<N>[]): string {
	let s = "";
	for (const n of ups) s = s + n.name;
	return s;
}

function spliced(): string {
	const a = new N("a");
	const b = new N("b");
	const c = new N("c");
	const x = new N("x");
	const h = new H();
	h.ups = [a];
	h.ups.splice(0, 0, c);
	const first = names(h.ups);
	h.ups.splice(2, 0, b);
	const second = names(h.ups);
	h.ups.splice(0, 2, x);
	return `${first} ${second} ${names(h.ups)} ${h.ups.length}`;
}

function nullable(): string {
	const k = new N("k");
	const c = new N("c");
	const h = new H();
	h.maybe = [k];
	h.maybe.splice(1, 0, c);
	const both = h.maybe[0]!.name + h.maybe[1]!.name;
	h.maybe.splice(1, 1);
	return `${both} ${h.maybe[0]!.name} ${h.maybe.length}`;
}

function user(): string {
	const p = new N("p");
	const q = new N("q");
	const h = new H();
	put(h.ups, p);
	put(h.ups, q);
	return `${names(h.ups)} ${h.ups.length}`;
}

console.log(`${spliced()} | ${nullable()} | ${user()}`);
