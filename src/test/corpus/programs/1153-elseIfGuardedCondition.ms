// @stdout: 1 2 1 2 1 3 2
// note: an `else if` whose condition holds a call on the right of `&&` or `||` is evaluated only when the earlier branches are not taken, for a free function call, a method call and an else-if one level deeper.

function same(a: int32, b: int32): boolean { return a == b; }

class Key {
	v: int32;
	constructor(v: int32) { this.v = v; }
	is(n: int32): boolean { return this.v == n; }
}

function free(slot: int32, entries: int32[]): int32 {
	if (slot == -2) {
		return 1;
	} else if (entries[slot] == 5 && same(slot, 0)) {
		return 2;
	}
	return 0;
}

function method(slot: int32, entries: int32[], key: Key): int32 {
	if (slot == -2) {
		return 1;
	} else if (entries[slot] == 5 && key.is(5)) {
		return 2;
	}
	return 0;
}

function deeper(slot: int32, entries: int32[]): int32 {
	if (slot == -2) {
		return 1;
	} else if (slot == -3) {
		return 3;
	} else if (entries[slot] == 5 || same(entries[slot], 6)) {
		return 2;
	}
	return 0;
}

const entries: int32[] = [5, 6, 7];
const key = new Key(5);
console.log(`${free(-2, entries)} ${free(0, entries)} ${method(-2, entries, key)} ${method(0, entries, key)} ${deeper(-2, entries)} ${deeper(-3, entries)} ${deeper(1, entries)}`);
