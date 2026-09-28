// @stdout: unknown-slots arr=2 lit=2 map=m field=r2 box=b2 cap=cap await=40
// @xfail(raiser): the Raiser VM has no host bridge for msMapFatal and stops with 'expected an object, got value kind Array'

class Node {
	name: string;
	constructor(name: string) { this.name = name; }
}

class Holder {
	host: unknown;
	constructor(h: unknown) { this.host = h; }
}

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

function arrayPush(): int32 {
	let n = 0 as int32;
	for (let i = 0; i < 500; i += 1) {
		const arr: unknown[] = [];
		arr.push(new Node("a1"));
		arr.push(new Node("a2"));
		arr.length = 1;
		arr.push(new Node("a3"));
		n = arr.length as int32;
	}
	return n;
}

function arrayLiteral(): int32 {
	let n = 0 as int32;
	for (let i = 0; i < 500; i += 1) {
		const arr: unknown[] = [new Node("l1"), new Node("l2")];
		n = arr.length as int32;
	}
	return n;
}

function nameOf(u: unknown): string {
	return (u as Node).name;
}

function mapSetGet(): string {
	let seen = "";
	for (let i = 0; i < 500; i += 1) {
		const m = new Map<string, unknown>();
		m.set("k", new Node("m"));
		m.set("k", new Node("m"));
		const g = m.get("k");
		if (g != null) seen = nameOf(g);
	}
	return seen;
}

function reassignField(): string {
	let seen = "";
	for (let i = 0; i < 500; i += 1) {
		const h = new Holder(new Node("r1"));
		h.host = new Node("r2");
		seen = (h.host as Node).name;
	}
	return seen;
}

function genericBox(): string {
	let seen = "";
	for (let i = 0; i < 500; i += 1) {
		const b = new Box<unknown>(new Node("b1"));
		b.v = new Node("b2");
		seen = (b.v as Node).name;
	}
	return seen;
}

function closureCapture(): string {
	let seen = "";
	for (let i = 0; i < 500; i += 1) {
		const u: unknown = new Node("cap");
		const f = (): string => (u as Node).name;
		seen = f();
	}
	return seen;
}

async function make(i: int32): Promise<unknown> {
	return new Node("p" + i.toString());
}

async function awaitAll(): Promise<int32> {
	let n = 0 as int32;
	for (let i = 0; i < 40; i += 1) {
		const u = await make(i as int32);
		if ((u as Node).name.length > 1) n += 1;
	}
	return n;
}

async function main(): Promise<void> {
	const a = arrayPush();
	const l = arrayLiteral();
	const m = mapSetGet();
	const f = reassignField();
	const b = genericBox();
	const c = closureCapture();
	const w = await awaitAll();
	console.log(`unknown-slots arr=${a} lit=${l} map=${m} field=${f} box=${b} cap=${c} await=${w}`);
}
main();
