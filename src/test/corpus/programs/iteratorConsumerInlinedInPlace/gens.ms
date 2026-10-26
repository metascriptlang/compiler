export function* count(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		yield i;
	}
}

function shut(it: Iterator<int32>): void {
	if (it.return != null) it.return();
}

function* firstN(it: Iterator<int32>, n: int32): Iterator<int32> {
	let left = n;
	for (const x of it) {
		if (left < 1) return;
		left -= 1;
		yield x;
	}
}

export function firsts(it: Iterator<int32>, n: int32): Iterator<int32> {
	if (n < 0) {
		shut(it);
		throw new Error("negative " + n.toString());
	}
	return firstN(it, n);
}

export function total(it: Iterator<int32>): int32 {
	let t: int32 = 0;
	for (const x of it) t += x;
	return t;
}

let consumed: int32 = 0;

export function consumedCount(): int32 {
	return consumed;
}

export function tally(it: Iterator<int32>): int32 {
	let n: int32 = 0;
	for (const x of it) n += 1;
	consumed += n;
	return n;
}
