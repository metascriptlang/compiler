// @stdout: value true value true value true value value value
// @exit: 0
// note: a local holding null passed into a generic `T | fn` parameter with `T = Ref | null` reaches the callee as the carrier it expects, for a class, an interface, an array and a method, on every backend.

class Box { v: int32 = 1; }
interface Item { v: int32; }

function kind<T>(first: T | ((prev: T | null) => T)): string {
	if (typeof first === "function") { return "fn"; }
	return "value";
}

function pick<T>(first: T | ((prev: T | null) => T)): boolean {
	return first === null;
}

class Holder {
	kind<T>(first: T | ((prev: T | null) => T)): string {
		if (typeof first === "function") { return "fn"; }
		return "value";
	}
}

const n: Box | null = null;
const item: Item | null = null;
const list: int32[] | null = null;
const h = new Holder();
const parts: string[] = [
	kind<Box | null>(n),
	pick<Box | null>(n).toString(),
	kind<Item | null>(item),
	pick<Item | null>(item).toString(),
	kind<int32[] | null>(list),
	pick<int32[] | null>(list).toString(),
	h.kind<Box | null>(n),
	pick<Box | null>(new Box()).toString() == "false" ? "value" : "bad",
	kind<Box | null>(null),
];
console.log(parts.join(" "));
