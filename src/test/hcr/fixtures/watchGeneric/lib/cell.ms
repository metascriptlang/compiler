export class Tag {
	name: string = "t";
}

let current: Tag | null = null;

export function currentTag(): Tag | null {
	return current;
}

export class Cell<T> {
	private value: T;
	private reads: int32 = 0;

	constructor(value: T) {
		this.value = value;
	}

	get(): T {
		const tag = currentTag();
		const label = "cell";
		if (tag !== null && label.length > 0) {
			console.log(this.reads);
		}
		this.reads += 1;
		return this.value;
	}
}
