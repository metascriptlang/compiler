let built: int32 = 0;

function counted(n: number): number {
	built += 1;
	return n;
}

export function builtCount(): int32 {
	return built;
}

export class Store {
	bytes: number[] = [];
}

export class View {
	held: number;
	store: Store | null;

	@inline
	constructor(held: number, store: Store | null) {
		this.held = held;
		this.store = store;
	}
}

export class Sized extends View {
	label: string;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<number[]>);
	constructor(store: Store);
	@inline
	constructor(source: number | Readonly<number[]> | Store = 0) {
		if (typeof source == "number") {
			if (!(source >= 0)) throw new RangeError(`Invalid length: ${source}`);
			super(counted(source), null);
			this.label = "length";
		} else if (source instanceof Store) {
			super(source.bytes.length, source);
			this.label = "store";
		} else {
			super(source.length, null);
			this.label = "array";
		}
	}

	@inline
	static of(n: number): Sized {
		return new Sized(n + 1);
	}
}
