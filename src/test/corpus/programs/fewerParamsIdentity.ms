// @stdout: closure true true false true
// @stdout: named true true false
// @stdout: distinct false true
// A value that fills a wider slot is the same function: `===` sees through the adapter on
// every backend, for a closure, a named function and an adapter adapted again.
interface Event { x: int32; }

let hits = 0;
function named(): void { hits += 10; }

function main(): void {
	const cb = (): void => { hits += 1; };
	const a: (e: Event) => void = cb;
	const b: (e: Event) => void = cb;
	const c: (e: Event, k: int32) => void = a;
	const same = a;
	console.log(`closure ${a === b} ${a === same} ${a !== b} ${c === a}`);
	const wide: (e: Event) => void = named;
	const zero: () => void = named;
	console.log(`named ${wide === zero} ${zero === named} ${wide !== zero}`);
	const other = (): void => {};
	const d: (e: Event) => void = other;
	console.log(`distinct ${a === d} ${a !== d}`);
}

main();
