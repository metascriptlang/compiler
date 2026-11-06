// @stdout: early 103 3 2
// @stdout: else 103 3 2
// @stdout: ternary 103 3 2
// @stdout: union 103 5
// @stdout: mixed 7 6 5
// @stdout: plain 1 9
// @exit: 0
// note: a typeof test on a parameter typed by a type parameter keeps its TypeScript meaning in every instance: an instance bound to one type takes only the branch that type reaches (the other branch, checked once against the constraint, would read a never there), and a union binding tests at run time.

type ByteInput = string | Uint8Array | Readonly<Span<uint8>>;

function size(b: Readonly<Span<uint8>>): int32 {
	return b.length as int32;
}

function early<B extends ByteInput>(b: B): int32 {
	if (typeof b == "string") return 100 + size(b.asBytes());
	return size(b);
}

function withElse<B extends ByteInput>(b: B): int32 {
	if (typeof b != "string") {
		return size(b);
	} else {
		return 100 + size(b.asBytes());
	}
}

function ternary<B extends ByteInput>(b: B): int32 {
	return typeof b == "string" ? 100 + size(b.asBytes()) : size(b);
}

function mixed<K extends ByteInput, D extends ByteInput>(k: K, d: D): int32 {
	const kn = typeof k == "string" ? size(k.asBytes()) : size(k);
	const dn = typeof d == "string" ? size(d.asBytes()) : size(d);
	return kn + dn;
}

function plain<T extends string | number>(x: T): number {
	if (typeof x == "number") return x;
	return x.length;
}

function pick(flag: boolean): string | Uint8Array {
	return flag ? "abc" : new Uint8Array(5);
}

const bytes: uint8[] = [1, 2];
const typed = new Uint8Array(3);
console.log(`early ${early("hé")} ${early(typed)} ${early(bytes)}`);
console.log(`else ${withElse("hé")} ${withElse(typed)} ${withElse(bytes)}`);
console.log(`ternary ${ternary("hé")} ${ternary(typed)} ${ternary(bytes)}`);
console.log(`union ${early(pick(true))} ${early(pick(false))}`);
console.log(`mixed ${mixed("abcd", typed)} ${mixed(typed, typed)} ${mixed(bytes, "hé")}`);
console.log(`plain ${plain(1)} ${plain("123456789")}`);
