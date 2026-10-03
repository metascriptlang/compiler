// @xfail(raiser): the Raiser std has no Array join, so the program stops at check: Property 'join' does not exist on type 'Array' (same on main a1b1368d)
// @stdout: order 1,2,3|mixed 1.5,7,-2,0.25|wide 14,0.5|pushed 4 9.5|nested 2 1,2 3|field 3 6|loop 0,1,2
// note: number[] and float64[] literals build element by element in source order, the same
//   path every other scalar literal takes; before, they went through a variadic runtime
//   constructor that SBF cannot link (guard solanaNumberArrayLiteral).

let calls = 0;
function next(): number {
	calls += 1;
	return calls;
}

struct Bag {
	items: number[];
}

function sum(values: number[]): number {
	let total = 0;
	for (const v of values) total += v;
	return total;
}

function main(): void {
	const out: string[] = [];
	const order: number[] = [next(), next(), next()];
	out.push(`order ${order.join(",")}`);
	const n: int32 = 7;
	const mixed: number[] = [1.5, n, -2, 0.25];
	out.push(`mixed ${mixed.join(",")}`);
	const wide: float64[] = [n * 2, 0.5];
	out.push(`wide ${wide.join(",")}`);
	const pushed: number[] = [1, 2, 3];
	pushed.push(9.5);
	out.push(`pushed ${pushed.length} ${pushed[3]}`);
	const nested: number[][] = [[1, 2], [3]];
	out.push(`nested ${nested.length} ${nested[0].join(",")} ${nested[1].join(",")}`);
	const bag: Bag = { items: [1, 2, 3] };
	out.push(`field ${bag.items.length} ${sum(bag.items)}`);
	const seen: string[] = [];
	for (let i = 0; i < 3; i += 1) {
		const one: number[] = [i];
		seen.push(`${one[0]}`);
	}
	out.push(`loop ${seen.join(",")}`);
	console.log(out.join("|"));
}
main();
