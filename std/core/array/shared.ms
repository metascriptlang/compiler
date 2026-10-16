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
