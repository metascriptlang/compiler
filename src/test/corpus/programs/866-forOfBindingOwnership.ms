// @stdout: body 1 helper 1 inner 1
// note: a for-of binding borrows its element only when nothing can change the array while the binding is alive. It used to always borrow, so overwriting the element being visited, directly or through a helper, or replacing the array being iterated, freed what the binding still read.

class Box { n: int32; constructor(n: int32) { this.n = n; } }

function replaceFirst(arr: Box[]): void { arr[0] = new Box(3); }

function overwriteInBody(): string {
	const boxes: Box[] = [];
	boxes.push(new Box(1));
	boxes.push(new Box(2));
	let out = "";
	for (const b of boxes) {
		boxes[0] = new Box(3);
		const reuse = new Box(99);
		out = out + String(b.n) + ":" + String(reuse.n) + " ";
	}
	return out + String(boxes.length);
}

function overwriteInHelper(): string {
	const boxes: Box[] = [];
	boxes.push(new Box(1));
	boxes.push(new Box(2));
	let out = "";
	for (const b of boxes) {
		replaceFirst(boxes);
		const reuse = new Box(98);
		out = out + String(b.n) + ":" + String(reuse.n) + " ";
	}
	return out + String(boxes.length);
}

function replaceIterated(): string {
	const nested: Box[][] = [[new Box(1), new Box(2)]];
	let out = "";
	for (const b of nested[0]) {
		nested[0] = [new Box(4)];
		const reuse = new Box(97);
		out = out + String(b.n) + ":" + String(reuse.n) + " ";
	}
	return out + String(nested[0].length);
}

function pickIterable(flag: boolean): string {
	const xs: Box[] = [new Box(5), new Box(6)];
	const ys: Box[] = [new Box(7)];
	let sum = 0;
	for (const b of (flag ? xs : ys)) { sum = sum + b.n; }
	return String(sum) + " " + String(xs.length + ys.length);
}

const a = overwriteInBody();
const b = overwriteInHelper();
const c = replaceIterated();
console.log("body " + a.substring(0, 1) + " helper " + b.substring(0, 1) + " inner " + c.substring(0, 1));
console.log(a);
console.log(b);
console.log(c);
console.log(pickIterable(true));
console.log(pickIterable(false));
