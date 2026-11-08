// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: filter 2 4 6
// @stdout: slice 2 3
// @stdout: sort 6 5 4 3 2 1
// @stdout: concat 1 2 3 4 5 6 1
// @stdout: map 10,20,30,40,50,60
// @stdout: find 4, indexOf 2, includes yes
// @stdout: reverse 6 5 4 3 2 1
// @stdout: splice 6 3 2 1
// @stdout: shift 6, left 3 2 1
// @stdout: nullable 1 2 3
// @stdout: nested 1 4 | 2 3
// @stdout: local 5 6
// @stdout: destroyed 6
// @stdout: kept 1 of 2, destroyed 8
// note: an array of Unowned<T> counts its own elements wherever it is held: a local, a parameter, a return value, a nullable field and an array of such arrays, and every copy Array's methods make (filter, slice, sort, concat) and every element they remove (splice, shift) keeps them on the Unowned count, so the targets are destroyed when their strong holders go.
class N { id: int32; constructor(id: int32) { this.id = id; } }
let destroyed = 0;
function onDestroy(this n: N): void { destroyed++; }

class H {
	ups: Unowned<N>[] = [];
	maybe: Unowned<N>[] | null = null;
	grid: Unowned<N>[][] = [];
}

function ids(xs: Unowned<N>[]): string {
	let s = "";
	for (const n of xs) s = s + n.id.toString() + " ";
	return s.trim();
}

function evens(h: H): Unowned<N>[] {
	return h.ups.filter((n: N): boolean => n.id % 2 == 0);
}

function run(): void {
	const ns: N[] = [];
	for (let i: int32 = 1; i <= 6; i++) ns.push(new N(i));
	const h = new H();
	for (const n of ns) h.ups.push(n);
	console.log("filter " + ids(evens(h)));
	console.log("slice " + ids(h.ups.slice(1, 3)));
	const sorted = h.ups.slice();
	sorted.sort((a: N, b: N): number => b.id - a.id);
	console.log("sort " + ids(sorted));
	console.log("concat " + ids(h.ups.concat(h.ups.slice(0, 1))));
	console.log("map " + h.ups.map((n: N): int32 => n.id * 10).join(","));
	const found = h.ups.find((n: N): boolean => n.id == 4);
	console.log("find " + (found != null ? found.id : 0).toString() + ", indexOf " + h.ups.indexOf(ns[2]).toString() + ", includes " + (h.ups.includes(ns[5]) ? "yes" : "no"));
	h.ups.reverse();
	console.log("reverse " + ids(h.ups));
	h.ups.splice(1, 2);
	console.log("splice " + ids(h.ups));
	const first = h.ups.shift();
	console.log("shift " + (first != null ? first.id : 0).toString() + ", left " + ids(h.ups));
	h.maybe = [ns[0], ns[1]];
	const maybe = h.maybe;
	if (maybe != null) {
		maybe.push(ns[2]);
		console.log("nullable " + ids(maybe));
	}
	h.maybe = null;
	h.grid.push([ns[0]]);
	h.grid.push([ns[1], ns[2]]);
	h.grid[0].push(ns[3]);
	console.log("nested " + ids(h.grid[0]) + " | " + ids(h.grid[1]));
	const local: Unowned<N>[] = [ns[4]];
	local.push(ns[5]);
	console.log("local " + ids(local));
}

function survivor(): Unowned<N>[] {
	const a = new N(7);
	const b = new N(8);
	const xs: Unowned<N>[] = [a, b];
	return xs.filter((n: N): boolean => n.id == 8);
}

run();
console.log("destroyed " + destroyed.toString());
const kept = survivor();
console.log("kept " + kept.length.toString() + " of 2, destroyed " + destroyed.toString());
