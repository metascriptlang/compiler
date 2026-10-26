export function* evens(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i += 2) {
		yield i;
	}
}

export function* labelled<T>(this it: Iterator<T>, tag: string): Iterator<string> {
	for (const x of it) {
		yield tag + x.toString();
	}
}

let made: int32 = 0;

export function madeCount(): int32 {
	return made;
}

export function* counting(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		made += 1;
		yield i;
	}
}
