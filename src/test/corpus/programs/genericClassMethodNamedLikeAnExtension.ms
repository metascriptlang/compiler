// @stdout: 6 6 7 box3 free 8
// note: a generic class's own method wins over an extension of the same name that every type has (std's `hash<T>`, a user `tag<T>`), with or without parameters and when called inside another generic function, as it does on a plain class.

class Table<K> {
	n: int32 = 5;
	hash(i: int32): int32 { return this.n + i; }
}

class Counter<K> {
	n: int32 = 5;
	hash(): int32 { return this.n + 1; }
}

function tag<T>(this x: T): string { return "free"; }

class Box<K> {
	n: int32 = 2;
	tag(i: int32): string { return `box${this.n + i}`; }
}

class Plain {
	n: int32 = 7;
	hash(i: int32): int32 { return this.n + i; }
}

function probe<K>(t: Table<K>): int32 { return t.hash(2); }

const t = new Table<int32>();
const c = new Counter<string>();
const b = new Box<string>();
console.log(`${t.hash(1)} ${c.hash()} ${probe(new Table<string>())} ${b.tag(1)} ${(7 as int32).tag()} ${new Plain().hash(1)}`);
