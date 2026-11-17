// @stdout: local 24691357802469135780
// @stdout: field 12345678901234567890 12345678901234567891
// @stdout: array 12345678901234567890 12345678901234567890 7 3
// @stdout: tuple 12345678901234567890 5
// @stdout: nullable 12345678901234567890 null
// @stdout: closure 12345678901234567891 12345678901234567891
// @stdout: map 12345678901234567890 9 2
// @stdout: class 24691357802469135780
// @stdout: nested 12345678901234567890 1 12345678901234567890
// @stdout: vec 12345678901234567890 2 12345678901234567890 3 2

interface Box { v: bigint; n: int32; }
struct Pair { left: bigint; right: bigint | null; }
struct Bag { items: Vec<bigint>; }
class Acc {
	total: bigint = 0n;
	add(x: bigint): void { this.total = this.total + x; }
}

function localCopy(a: bigint): bigint {
	const b = a;
	let c = a;
	c = b;
	return b + c;
}

function fieldCopy(a: bigint): string {
	const box: Box = { v: a, n: 1 };
	const other: Box = { v: box.v, n: 2 };
	other.v = other.v + 1n;
	return `${box.v} ${other.v}`;
}

function arrayShapes(a: bigint): string {
	const xs: bigint[] = [];
	xs.push(a);
	xs.push(a);
	xs.push(7n);
	const first = xs[0];
	xs[1] = first;
	const ys = [...xs];
	ys[2] = 3n;
	return `${xs[0]} ${xs[1]} ${xs[2]} ${ys[2]}`;
}

function tupleShape(a: bigint): string {
	const t: [bigint, int32] = [a, 5];
	const u = t;
	return `${u[0]} ${u[1]}`;
}

function nullableShape(a: bigint, pick: boolean): string {
	const m: bigint | null = pick ? a : null;
	const k = m;
	return k == null ? "null" : `${k}`;
}

function closureShape(a: bigint): () => bigint {
	return () => a + 1n;
}

function mapShape(a: bigint): string {
	const m = new Map<string, bigint>();
	m.set("a", a);
	m.set("b", a);
	m.set("b", 9n);
	const got = m.get("a");
	const other = m.get("b");
	return `${got == null ? 0n : got} ${other == null ? 0n : other} ${m.size}`;
}

function nestedShape(a: bigint): string {
	const pairs: Pair[] = [{ left: a, right: null }, { left: 1n, right: a }];
	const copy = pairs[1];
	const right = copy.right;
	return `${pairs[0].left} ${copy.left} ${right == null ? 0n : right}`;
}

function vecShape(a: bigint): string {
	const bag: Bag = { items: [a, a + 1n] };
	const bags: Bag[] = [];
	bags.push(bag);
	bags.push(bag);
	bags[1].items[0] = 2n;
	let v: Vec<bigint> = [a];
	const w = v;
	v.push(3n);
	return `${bags[0].items[0]} ${bags[1].items[0]} ${w[0]} ${v[1]} ${bag.items.length}`;
}

const seed = 12345678901234567890n;
console.log(`local ${localCopy(seed)}`);
console.log(`field ${fieldCopy(seed)}`);
console.log(`array ${arrayShapes(seed)}`);
console.log(`tuple ${tupleShape(seed)}`);
console.log(`nullable ${nullableShape(seed, true)} ${nullableShape(seed, false)}`);
const next = closureShape(seed);
console.log(`closure ${next()} ${next()}`);
console.log(`map ${mapShape(seed)}`);
const acc = new Acc();
acc.add(seed);
acc.add(seed);
console.log(`class ${acc.total}`);
console.log(`nested ${nestedShape(seed)}`);
console.log(`vec ${vecShape(seed)}`);
