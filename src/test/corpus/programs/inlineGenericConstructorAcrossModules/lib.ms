let built: int32 = 0;

export function builtCount(): int32 {
	return built;
}

export class Holder<T> {
	items: T[];
	readonly length: number;

	@inline
	constructor(items: T[], length: number) {
		if (!(length >= 0)) throw new RangeError(`Invalid length: ${length}`);
		built += 1;
		this.items = items;
		this.length = length;
	}

	@inline
	static pair(a: T, b: T): Holder<T> {
		return new Holder<T>([a, b], 2);
	}
}

export class Names extends Holder<string> {
	label: string;

	@inline
	constructor(label: string, count: number) {
		const items: string[] = [];
		for (let i = 0; i < count; i++) items.push(`${label}${i}`);
		super(items, count);
		this.label = label;
	}
}
