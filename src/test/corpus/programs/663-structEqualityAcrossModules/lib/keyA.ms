export struct Key { a: uint8; }

export function sameKeyA(x: uint8, y: uint8): boolean {
	const p: Key = { a: x };
	const q: Key = { a: y };
	return p == q;
}
