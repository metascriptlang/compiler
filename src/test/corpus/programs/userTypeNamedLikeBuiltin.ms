// @stdout: vec:2 arc:7 locked:x cursor:1

class Vec<T> {
	items: T[] = [];
	add(v: T): void { this.items.push(v); }
	size(): int32 { return this.items.length; }
}

class Arc<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

class Locked<T> {
	inner: T;
	constructor(inner: T) { this.inner = inner; }
}

interface Cursor<T> { at: T; }

const v = new Vec<int32>();
v.add(1);
v.add(2);
const a: Arc<int32> = new Arc<int32>(7);
const l: Locked<string> = new Locked<string>("x");
const c: Cursor<int32> = { at: 1 };
console.log(`vec:${v.size()} arc:${a.value} locked:${l.inner} cursor:${c.at}`);
