// @stdout: generic-down-conv num=7 str=s made=9 cloned=7 entry=42/hi null=ok sum=4950

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	get(): T { return this.v; }
	clone(): Box<T> { return new Box<T>(this.v); }
}

class Entry<T> {
	key: unknown;
	read: () => T;
	constructor(key: unknown, read: () => T) { this.key = key; this.read = read; }
}

class Key { name: string; constructor(name: string) { this.name = name; } }

function make<T>(v: T): Box<T> {
	return new Box<T>(v);
}

function lookup<T>(entries: unknown[], key: Key, fallback: T): T {
	for (const e of entries) {
		const entry = e as Entry<T>;
		if (entry.key === key) return entry.read();
	}
	return fallback;
}

function nullPasses(): string {
	const empty: unknown | null = null;
	const b = empty as Box<number> | null;
	return b == null ? "ok" : "bad";
}

function sum(): number {
	const parked: unknown[] = [];
	for (let i = 0; i < 100; i += 1) parked.push(new Box<number>(i));
	let total: number = 0;
	for (const p of parked) total += (p as Box<number>).get();
	return total;
}

function main(): void {
	const n: unknown = new Box<number>(7);
	const s: unknown = new Box<string>("s");
	const made: unknown = make<number>(9);
	const cloned: unknown = (n as Box<number>).clone();
	const numKey = new Key("n");
	const strKey = new Key("s");
	const numbers: unknown[] = [new Entry<number>(numKey, (): number => 42)];
	const strings: unknown[] = [new Entry<string>(strKey, (): string => "hi")];
	const entry = `${lookup<number>(numbers, numKey, 0)}/${lookup<string>(strings, strKey, "")}`;
	console.log(`generic-down-conv num=${(n as Box<number>).v} str=${(s as Box<string>).v} made=${(made as Box<number>).v} cloned=${(cloned as Box<number>).get()} entry=${entry} null=${nullPasses()} sum=${sum()}`);
}
main();
