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
