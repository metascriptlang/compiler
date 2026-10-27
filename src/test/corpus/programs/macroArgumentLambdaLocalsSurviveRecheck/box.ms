export function box<T>(v: T): [() => T, (n: T) => void] {
	let cur = v;
	return [(): T => cur, (n: T): void => { cur = n; }];
}
