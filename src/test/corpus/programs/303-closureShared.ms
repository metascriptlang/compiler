// Parity program — sibling closures over ONE environment: getter/setter pairs
// must see each other's writes through the shared cell, not private copies.

type Getter = () => int64;
type Setter = (v: int64) => void;
type VoidFn = () => void;

interface Cell {
	get: Getter;
	set: Setter;
}

function makeCell(init: int64): Cell {
	let value = init;
	return {
		get: (): int64 => value,
		set: (v: int64): void => { value = v; },
	};
}

function main(): void {
	const a = makeCell(1);
	const b = makeCell(100);
	console.log("a0=" + a.get().toString());
	a.set(42);
	console.log("a1=" + a.get().toString());
	console.log("b0=" + b.get().toString());
	b.set(a.get() + 1);
	console.log("b1=" + b.get().toString());

	let trail = "";
	const says = (tag: string): VoidFn => (): void => { trail = trail + tag; };
	const x = says("x");
	const y = says("y");
	x(); y(); x();
	console.log("trail=" + trail);
}
main();
