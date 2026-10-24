function closeSource<T>(it: Iterator<T>): void {
	if (it.return != null) it.return();
}

function limitError(limit: number): Error | null {
	if (limit != limit || limit <= -1) return new Error(`${limit} must be positive`);
	return null;
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
	const bad = limitError(limit);
	if (bad != null) {
		closeSource(it);
		throw bad;
	}
	return takeLazy(it, limit);
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
	const bad = limitError(limit);
	if (bad != null) {
		closeSource(it);
		throw bad;
	}
	return dropLazy(it, limit);
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

export type Undersized = "only-full" | "allow-partial";

function sizeError(size: number, name: string): Error | null {
	if (size % 1 != 0) return new Error(`${name} must be an integer`);
	if (size < 1 || size > 4294967295) return new RangeError(`${name} must be between 1 and 4294967295`);
	return null;
}

function* chunksLazy<T>(it: Iterator<T>, size: number): Iterator<T[]> {
	let buffer: T[] = [];
	for (const x of it) {
		buffer.push(x);
		if (buffer.length == size) {
			yield buffer;
			buffer = [];
		}
	}
	if (buffer.length > 0) yield buffer;
}

export function chunks<T>(this it: Iterator<T>, size: number): Iterator<T[]> {
	const bad = sizeError(size, "chunkSize");
	if (bad != null) {
		closeSource(it);
		throw bad;
	}
	return chunksLazy(it, size);
}

function* windowsLazy<T>(it: Iterator<T>, size: number, partial: boolean): Iterator<T[]> {
	const buffer: T[] = [];
	for (const x of it) {
		if (buffer.length == size) buffer.shift();
		buffer.push(x);
		if (buffer.length == size) yield buffer.slice(0);
	}
	if (partial && buffer.length > 0 && buffer.length < size) yield buffer.slice(0);
}

export function windows<T>(
	this it: Iterator<T>,
	size: number,
	undersized?: Undersized,
): Iterator<T[]> {
	const bad = sizeError(size, "windowSize");
	if (bad != null) {
		closeSource(it);
		throw bad;
	}
	return windowsLazy(it, size, undersized == "allow-partial");
}

function* cycleLazy<T>(it: Iterator<T>): Iterator<T> {
	const seen: T[] = [];
	for (const x of it) {
		seen.push(x);
		yield x;
	}
	if (seen.length == 0) return;
	while (true) {
		for (let i = 0; i < seen.length; i++) yield seen[i];
	}
}

export function cycle<T>(this it: Iterator<T>): Iterator<T> {
	return cycleLazy(it);
}

function* stepByLazy<T>(it: Iterator<T>, step: number): Iterator<T> {
	let skipped = 0;
	for (const x of it) {
		if (skipped == 0) yield x;
		skipped = skipped + 1 == step ? 0 : skipped + 1;
	}
}

export function stepBy<T>(this it: Iterator<T>, step: number): Iterator<T> {
	const bad = sizeError(step, "step");
	if (bad != null) {
		closeSource(it);
		throw bad;
	}
	return stepByLazy(it, step);
}

function* scanLazy<T, U>(it: Iterator<T>, fn: (acc: U, x: T, i: number) => U, init: U): Iterator<U> {
	let acc = init;
	let i: number = 0;
	for (const x of it) {
		acc = fn(acc, x, i);
		i += 1;
		yield acc;
	}
}

export function scan<T, U>(
	this it: Iterator<T>,
	fn: (acc: U, x: T, i: number) => U,
	init: U,
): Iterator<U> {
	return scanLazy(it, fn, init);
}

export function sum(this it: Iterator<number>): number {
	let total: number = 0;
	for (const x of it) total += x;
	return total;
}

export function sum(this it: Iterator<int32>): int32 {
	let total: int32 = 0;
	for (const x of it) total += x;
	return total;
}
