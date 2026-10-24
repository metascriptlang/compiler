function closeSource<T>(it: Iterator<T>): void {
	if (it.return != null) it.return();
}

function checkedLimit<T>(it: Iterator<T>, limit: number): number {
	if (limit != limit || limit <= -1) {
		closeSource(it);
		throw new Error(`${limit} must be positive`);
	}
	return limit;
}

export function* map<T, U>(this it: Iterator<T>, fn: (x: T, i: number) => U): Iterator<U> {
	let i: number = 0;
	for (const x of it) {
		yield fn(x, i);
		i += 1;
	}
}

export function* filter<T>(this it: Iterator<T>, fn: (x: T, i: number) => boolean): Iterator<T> {
	let i: number = 0;
	for (const x of it) {
		const keep = fn(x, i);
		i += 1;
		if (keep) yield x;
	}
}

function* takeLazy<T>(it: Iterator<T>, limit: number): Iterator<T> {
	let left = limit;
	if (left < 1) {
		closeSource(it);
		return;
	}
	for (const x of it) {
		yield x;
		left -= 1;
		if (left < 1) return;
	}
}

export function take<T>(this it: Iterator<T>, limit: number): Iterator<T> {
	return takeLazy(it, checkedLimit(it, limit));
}

function* dropLazy<T>(it: Iterator<T>, limit: number): Iterator<T> {
	let left = limit;
	for (const x of it) {
		if (left >= 1) {
			left -= 1;
			continue;
		}
		yield x;
	}
}

export function drop<T>(this it: Iterator<T>, limit: number): Iterator<T> {
	return dropLazy(it, checkedLimit(it, limit));
}

export function* flatMap<T, U>(
	this it: Iterator<T>,
	fn: (x: T, i: number) => Iterator<U>,
): Iterator<U> {
	let i: number = 0;
	for (const x of it) {
		const inner = fn(x, i);
		i += 1;
		for (const y of inner) yield y;
	}
}

export function* flatMap<T, U>(this it: Iterator<T>, fn: (x: T, i: number) => U[]): Iterator<U> {
	let i: number = 0;
	for (const x of it) {
		const inner = fn(x, i);
		i += 1;
		for (const y of inner) yield y;
	}
}

export function reduce<T, U>(
	this it: Iterator<T>,
	fn: (acc: U, x: T, i: number) => U,
	init: U,
): U {
	let acc = init;
	let i: number = 0;
	for (const x of it) {
		acc = fn(acc, x, i);
		i += 1;
	}
	return acc;
}

export function reduce<T>(this it: Iterator<T>, fn: (acc: T, x: T, i: number) => T): T {
	const first = it.next();
	if (first.done) throw new Error("Reduce of a done iterator with no initial value");
	let acc = first.value;
	let i: number = 1;
	for (const x of it) {
		acc = fn(acc, x, i);
		i += 1;
	}
	return acc;
}

export function toArray<T>(this it: Iterator<T>): T[] {
	const out: T[] = [];
	for (const x of it) out.push(x);
	return out;
}

export function forEach<T>(this it: Iterator<T>, fn: (x: T, i: number) => void): void {
	let i: number = 0;
	for (const x of it) {
		fn(x, i);
		i += 1;
	}
}

export function some<T>(this it: Iterator<T>, fn: (x: T, i: number) => boolean): boolean {
	let i: number = 0;
	for (const x of it) {
		if (fn(x, i)) return true;
		i += 1;
	}
	return false;
}

export function every<T>(this it: Iterator<T>, fn: (x: T, i: number) => boolean): boolean {
	let i: number = 0;
	for (const x of it) {
		if (!fn(x, i)) return false;
		i += 1;
	}
	return true;
}

export function find<T>(this it: Iterator<T>, fn: (x: T, i: number) => boolean): T | null {
	let i: number = 0;
	for (const x of it) {
		if (fn(x, i)) return x;
		i += 1;
	}
	return null;
}
