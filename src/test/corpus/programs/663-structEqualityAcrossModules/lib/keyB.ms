export struct Key { a: uint64; b: uint64; }

export function sameKeyB(x: uint64, y: uint64): boolean {
	const p: Key = { a: 1, b: x };
	const q: Key = { a: 1, b: y };
	return p == q;
}
