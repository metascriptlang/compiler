export class P { name: string; constructor(name: string) { this.name = name; } }

export class Cell<T> {
	value: T;
	up: Unowned<P> | null;
	constructor(value: T, up: P) { this.value = value; this.up = up; }
}

export class Quick<T> {
	value: T;
	up: Unowned<P> | null;

	@inline
	constructor(value: T, up: P) { this.value = value; this.up = up; }
}

export class Base {
	item: P;
	up: Unowned<P> | null;
	constructor(item: P, up: P) { this.item = item; this.up = up; }
}

export function built(tag: string): string {
	const owner = new P("lib-" + tag);
	const c = new Cell<P>(new P(tag), owner);
	return c.value.name + "/" + c.up!.name;
}
