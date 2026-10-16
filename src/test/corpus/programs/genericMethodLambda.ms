// @stdout: 7 true 9
// @stdout: ab 3
// @stdout: 24 x5
// @stdout: start
// note: a lambda inside a method that declares its own type parameters runs on every backend,
// static or not, never called, with two type parameters and one nesting level deeper.
class Owner {
	name: string;
	constructor(name: string) { this.name = name; }
	wrap<T>(v: T): () => T {
		return (): T => v;
	}
	memo<T>(compute: () => T): () => T {
		return (): T => compute();
	}
	unused<T>(v: T): int32 {
		const f = (): int32 => 1;
		const g = (): T => v;
		return f();
	}
	both<A, B>(a: A, b: B, join: (x: A, y: B) => string): () => string {
		return (): string => join(a, b);
	}
	static nest<T>(v: T, n: int32): () => () => string {
		return (): () => string => {
			const inner = (): string => String(v) + String(n);
			return inner;
		};
	}
	static count<T>(xs: T[]): () => int32 {
		return (): int32 => xs.length as int32;
	}
}
const o = new Owner("o");
const w = o.wrap<int32>(7);
const m = o.memo((): boolean => true);
const sq = o.wrap(9);
console.log(String(w()) + " " + String(m()) + " " + String(sq()));
const j = o.both<string, int32>("ab", 3, (x: string, y: int32): string => x + " " + String(y));
console.log(j());
const c = Owner.count<string>(["a", "b"]);
const nested = Owner.nest<string>("x", 5);
const c4 = Owner.count([1, 2, 3, 4]);
console.log(String(c()) + String(c4()) + " " + nested()());
console.log("start");
