// @stdout: true true true 42
// @stdout: true 42 st 10
// note: an arrow with fewer parameters than its function slot binds the type parameter from its
// return type alone, through a function and through generic class methods.
class Cell<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

function build<T>(compute: (prev: T | null) => T): () => T {
	let seen: T | null = null;
	return (): T => {
		const cell = new Cell<T>(compute(seen));
		seen = cell.value;
		return cell.value;
	};
}

class Owner {
	name: string;
	constructor(name: string) { this.name = name; }
	memo<T>(compute: (prev: T | null) => T): () => T {
		let seen: T | null = null;
		return (): T => {
			const cell = new Cell<T>(compute(seen));
			seen = cell.value;
			return cell.value;
		};
	}
	static make<T>(compute: (prev: T | null, n: int32) => T): T { return compute(null, 1); }
}

class Store<S> {
	state: S;
	constructor(state: S) { this.state = state; }
	derive<T>(compute: (s: S, prev: T | null) => T): T { return compute(this.state, null); }
}

const annotated = build((): boolean => true);
const bare = build(() => true);
const explicit = build<boolean>((): boolean => true);
const counted = build(() => 2 * 21);
console.log(`${annotated()} ${bare()} ${explicit()} ${counted()}`);

const o = new Owner("o");
const a = o.memo((): boolean => true);
const b = o.memo(() => 2 * 21);
const c = Owner.make(() => "st");
const st = new Store<int32>(5);
const d = st.derive((s) => s * 2);
console.log(`${a()} ${b()} ${c} ${d}`);
