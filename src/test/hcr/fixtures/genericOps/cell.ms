export class Cell<T> {
	value: T;
	next: Cell<T> | null;
	constructor(value: T) {
		this.value = value;
		this.next = null;
	}
	onDestroy(): void { console.log("DROP"); }
}

export function capture<T>(value: T): [() => T, (value: T) => void] {
	const cell = new Cell<T>(value);
	return [() => cell.value, (next: T): void => { cell.value = next; }];
}
