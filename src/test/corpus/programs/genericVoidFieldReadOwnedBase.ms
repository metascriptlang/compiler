// @stdout: made 1
// @stdout: arg 1
// @stdout: made 2
// @stdout: loop 1000 3

struct Box<T> { v: T; name: string; items: int32[]; }
let taken = 0;
function take<T>(x: T): void { taken += 1; }
let made = 0;
function mk(): Box<void> {
	made += 1;
	return { v: null, name: "n" + String(made), items: [made, made + 1] };
}

const w = mk().v;
console.log("made " + String(made));
take(mk().v);
console.log("arg " + String(taken));
console.log("made " + String(made));
let total = 0;
for (let i = 0; i < 1000; i += 1) {
	const x = mk().v;
	total += 1;
}
const boxes: Box<void>[] = [mk()];
for (let i = 0; i < 1000; i += 1) {
	const y = boxes[0].v;
}
console.log("loop " + String(total) + " " + String(boxes[0].items.length + 1));
