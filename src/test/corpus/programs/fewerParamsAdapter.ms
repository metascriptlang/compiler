// @stdout: apply a! a! hits 6
// @stdout: pair x drop y first generic 5 2,3 nested z! slot 1
// A function value with fewer parameters than the slot it fills: a named function, a bound
// arrow, a capturing closure, a generic instance and an already adapted value, through a
// nullable slot, a plain declaration, an argument, an object field and a generic callback.
interface Event { x: int32; label: string; }
interface Handlers { onPress: ((event: Event) => void) | null; }

function one(s: string): string { return s + "!"; }
function apply(f: (s: string, i: number) => string): string { return f("a", 1); }
function fire(h: ((event: Event) => void) | null): void { if (h != null) h({ x: 2, label: "fired" }); }
function ident<T>(x: T): T { return x; }
function each3(f: (x: int32, i: int32, all: int32[]) => int32): int32 { return f(5, 0, [5]); }
function len(s: string): int32 { return s.length; }

function main(): void {
	let hits = 0;
	const callback = (): void => { hits += 1; };
	const slot: ((event: Event) => void) | null = callback;
	const plain: (event: Event) => void = callback;
	const handlers: Handlers = { onPress: callback };
	if (slot != null) slot({ x: 1, label: "slot" });
	plain({ x: 1, label: "plain" });
	fire(callback);
	fire(slot);
	fire(plain);
	if (handlers.onPress != null) handlers.onPress({ x: 3, label: "field" });
	console.log(`apply ${apply((s: string): string => s + "!")} ${apply(one)} hits ${hits}`);

	const prefix = "pair ";
	let seen = "";
	const pair = (a: string): void => { seen = prefix + a; };
	const two: (a: string, b: string) => void = pair;
	two("x", "dropped");
	let current = (a: string): void => { seen = seen + " drop " + a; };
	const held: (a: string, b: Event) => void = current;
	current = (a: string): void => { seen = seen + " replaced " + a; };
	held("y", { x: 0, label: "ignored" });
	const kept = "first";

	const words = ["a", "bb", "ccc"];
	const lengths = words.map(len).slice(1).join(",");
	const once: (a: string) => string = one;
	const twice: (a: string, b: int32) => string = once;
	const thrice: (a: string, b: int32, c: boolean) => string = twice;
	let slotCount = 0;
	const counted: ((event: Event, k: int32) => void) | null = slot != null ? slot : null;
	if (counted != null) { counted({ x: 0, label: "again" }, 7); slotCount = hits - 6; }
	console.log(`${seen} ${kept} generic ${each3(ident)} ${lengths} nested ${thrice("z", 1, true)} slot ${slotCount}`);
}

main();
