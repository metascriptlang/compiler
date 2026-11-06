// @stdout: 3 4 3 4 2 5 3 4 203 ok

type ByteInput = string | Uint8Array | Readonly<Span<uint8>>;

function total(d: Readonly<Span<uint8>>): int64 {
	return d.length;
}

function pick(flag: boolean, a: uint8[], u: Uint8Array): int64 {
	return total(flag ? a : u);
}

function held(flag: boolean, a: uint8[], u: Uint8Array): int64 {
	const s: Readonly<Span<uint8>> = flag ? a : u;
	return total(s);
}

function narrowed(x: string | Uint8Array): int64 {
	return total(typeof x == "string" ? x.asBytes() : x);
}

function generic<K extends ByteInput>(data: K): int64 {
	return total(typeof data == "string" ? data.asBytes() : data);
}

function pair<A extends ByteInput, B extends ByteInput>(a: A, b: B): int64 {
	return generic(a) * 100 + generic(b);
}

function either(flag: boolean): string | Uint8Array {
	return flag ? "abc" : new Uint8Array(4);
}

const a: uint8[] = [1, 2, 3];
const u = new Uint8Array(4);
console.log(pick(true, a, u), pick(false, a, u), held(true, a, u), held(false, a, u),
	narrowed("xy"), narrowed(new Uint8Array(5)),
	generic(either(true)), generic(either(false)), pair("ab", a), "ok");
