// @stdout: member a,b, calls 1 | deeper c,d, calls 1 | string 363 calls 1 | index e,f, reads 1
// @xfail(raiser): the Raiser VM runs for-of itself and rejects a string iterable ('expected an array, got value kind String')
// note: a call inside the iterable path of a for-of runs once, before the loop, as TypeScript evaluates the iterable once and Nim's items puts any argument that is not a path of reads from a symbol in a temp. The lowering re-read a member path at each element, so the call ran again per element (C: 5 calls, JS: 3), and with the length check the loop read a call temp that was not assigned yet (C debug: member access within null pointer).

class Bag { items: string[] = []; name: string = ""; }
class Box { inner: Bag = new Bag(); }

let calls = 0;
let reads = 0;

function mk(): Bag {
	calls += 1;
	const b = new Bag();
	b.items.push("a");
	b.items.push("b");
	b.name = "xyz";
	return b;
}

function mkBox(): Box {
	calls += 1;
	const x = new Box();
	x.inner.items.push("c");
	x.inner.items.push("d");
	return x;
}

function slot(): int32 {
	reads += 1;
	return 0;
}

function member(): string {
	calls = 0;
	let seen = "";
	for (const n of mk().items) seen = seen + n + ",";
	return `member ${seen} calls ${calls}`;
}

function deeper(): string {
	calls = 0;
	let seen = "";
	for (const n of mkBox().inner.items) seen = seen + n + ",";
	return `deeper ${seen} calls ${calls}`;
}

function stringField(): string {
	calls = 0;
	let sum = 0;
	for (const ch of mk().name) sum = sum + (ch as int32);
	return `string ${sum} calls ${calls}`;
}

function indexed(): string {
	const bags: Bag[] = [new Bag()];
	bags[0].items.push("e");
	bags[0].items.push("f");
	let seen = "";
	for (const n of bags[slot()].items) seen = seen + n + ",";
	return `index ${seen} reads ${reads}`;
}

console.log(member() + " | " + deeper() + " | " + stringField() + " | " + indexed());
