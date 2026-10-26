// @stdout: signal=x7 updated=x7! assign=var reassign=w1 pick=p1 none=null

// A union holding a class, `null` and a function — the shape of a signal setter
// `T | ((prev: T) => T)` with `T = Class | null` — keeps its value across
// reassignment, and narrowing it back to `Class | null` yields the object, not
// the union's storage.
class Boxed {
	message: string;
	constructor(m: string) { this.message = m; }
}

class Cell<T> {
	private v: T;
	constructor(v: T) { this.v = v; }
	get(): T { return this.v; }
	set(n: T): void { this.v = n; }
}

function make<T>(initial: T): [() => T, (v: T | ((prev: T) => T)) => void] {
	const c = new Cell<T>(initial);
	return [
		() => c.get(),
		(v: T | ((prev: T) => T)) => {
			if (typeof v === "function") { c.set(v(c.get())); } else { c.set(v); }
		},
	];
}

type Opt = Boxed | null;
type SetLike = Opt | ((prev: Opt) => Opt);

function take(v: SetLike): string {
	if (v == null) return "null";
	if (typeof v === "function") return "fn";
	return (v as Boxed).message;
}

function pick(v: SetLike): Opt {
	if (typeof v === "function") return null;
	return v as Opt;
}

export function main(): void {
	const [get, set] = make<Boxed | null>(null);
	set(new Boxed("x7"));
	const first = (get() as Boxed).message;
	set((prev: Boxed | null) => new Boxed((prev as Boxed).message + "!"));
	const second = (get() as Boxed).message;

	const b = new Boxed("var");
	let y: SetLike = null;
	y = b;
	let w: SetLike = new Boxed("w0");
	w = new Boxed("w1");

	const p = pick(new Boxed("p1"));
	const q = pick(null);
	console.log("signal=" + first + " updated=" + second + " assign=" + take(y) + " reassign=" + take(w)
		+ " pick=" + (p as Boxed).message + " none=" + (q == null ? "null" : "set"));
}
main();
