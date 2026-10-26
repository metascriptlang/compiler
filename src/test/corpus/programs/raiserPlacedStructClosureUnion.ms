// @stdout: 1 12 9
// note: a struct held in a union beside a function is the struct's cell, released and moved by the cell rows, so a struct passed to the union, a function passed to it and a generic instance of the union all leave nothing live at exit. Second axis: the union is a generic alias instantiated by the caller.
struct Payload { a: int32; b: int32; }
type Setter<T> = T | ((value: T) => T);

class Box {
	value: Payload;
	constructor(value: Payload) { this.value = value; }
}

function put(box: Box, next: Payload | ((value: Payload) => Payload)): void {
	if (typeof next === "function") { box.value = next(box.value); } else { box.value = next; }
}

function apply<T>(current: T, next: Setter<T>): T {
	if (typeof next === "function") { return next(current); }
	return next;
}

function widen(value: Payload): Payload { return { a: value.a, b: 9 }; }

function run(): string {
	const initial: Payload = { a: 1, b: 2 };
	const box = new Box(initial);
	put(box, initial);
	const first = box.value.a;
	put(box, (value: Payload): Payload => ({ a: value.a + 11, b: value.b }));
	const second = box.value.a;
	const widened = apply<Payload>(initial, widen);
	return first.toString() + " " + second.toString() + " " + widened.b.toString();
}

console.log(run());
