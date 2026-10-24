export function toString<T>(this arr: T[]): string {
	let out = "";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) out += ",";
		const item = arr[i];
		if (item != null) out += `${item}`;
	}
	return out;
}

export function lastIndexOf<T>(this arr: Vec<T>, value: T, fromIndex: int32 = -1): number {
	let i = fromIndex < 0 ? arr.length + fromIndex : fromIndex;
	if (i >= arr.length) i = arr.length - 1;
	while (i >= 0) {
		if (arr[i] == value) return i;
		i = i - 1;
	}
	return -1;
}

export function findIndex<T>(this arr: Vec<T>, fn: (x: T, i: number) => boolean): number {
	let i = 0;
	while (i < arr.length) {
		if (fn(arr[i], i)) return i;
		i = i + 1;
	}
	return -1;
}

export function findLastIndex<T>(this arr: Vec<T>, fn: (x: T, i: number) => boolean): number {
	let i = arr.length - 1;
	while (i >= 0) {
		if (fn(arr[i], i)) return i;
		i = i - 1;
	}
	return -1;
}

export function filter<T>(this arr: Vec<T>, fn: (x: T, i: number) => boolean): T[] {
	const out: T[] = [];
	let i = 0;
	while (i < arr.length) {
		if (fn(arr[i], i)) out.push(arr[i]);
		i = i + 1;
	}
	return out;
}

export function some<T>(this arr: Vec<T>, fn: (x: T, i: number) => boolean): boolean {
	return arr.findIndex(fn) >= 0;
}

export function find<T>(this arr: Vec<T>, fn: (x: T, i: number) => boolean): T | null {
	const i = arr.findIndex(fn);
	return i >= 0 ? arr[i] : null;
}

export function spliceStart(start: number, n: int64): int64 {
	if (start != start || start <= -(n as number)) return 0;
	if (start >= (n as number)) return n;
	const s = start as int64;
	return s < 0 ? s + n : s;
}

export function spliceCount(deleteCount: number, room: int64): int64 {
	if (deleteCount != deleteCount || deleteCount <= 0) return 0;
	if (deleteCount >= (room as number)) return room;
	return deleteCount as int64;
}

export function every<T>(this arr: Vec<T>, fn: (x: T, i: number) => boolean): boolean {
	const n = arr.length;
	for (let i = 0; i < n && i < arr.length; i += 1) {
		if (!fn(arr[i], i)) return false;
	}
	return true;
}

export function reduce<T, U>(this arr: Vec<T>, fn: (acc: U, x: T, i: number) => U, init: U): U {
	const n = arr.length;
	let acc = init;
	for (let i = 0; i < n && i < arr.length; i += 1) {
		acc = fn(acc, arr[i], i);
	}
	return acc;
}

export function reduce<T>(this arr: Vec<T>, fn: (acc: T, x: T, i: number) => T): T {
	const n = arr.length;
	if (n == 0) throw new Error("Reduce of empty array with no initial value");
	let acc = arr[0];
	for (let i = 1; i < n && i < arr.length; i += 1) {
		acc = fn(acc, arr[i], i);
	}
	return acc;
}

export function* values<T>(this arr: T[]): Iterator<T> {
	for (let i = 0; i < arr.length; i += 1) yield arr[i];
}

export function* keys<T>(this arr: T[]): Iterator<number> {
	for (let i = 0; i < arr.length; i += 1) yield i;
}

export function* entries<T>(this arr: T[]): Iterator<[number, T]> {
	for (let i = 0; i < arr.length; i += 1) yield [i, arr[i]];
}
