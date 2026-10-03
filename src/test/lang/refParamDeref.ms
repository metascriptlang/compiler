struct Reader670 { bytes: uint8[]; offset: int32; }
struct Box670 { v: int32; }
struct HoldsRef670 { r: Ref<Box670>; n: int32; }
struct HoldsPtr670 { p: Ptr<Box670>; n: int32; }
struct Names670 { names: string[]; n: int32; }
struct Inner670 { xs: int32[]; }
struct Outer670 { inner: Inner670; tag: int32; }

function next(this ref reader: Reader670): uint8 {
	const value = reader.bytes[reader.offset];
	reader.offset += 1;
	return value;
}
function remaining(this ref reader: Reader670): int32 { return reader.bytes.length - reader.offset; }
function nextPlain(ref reader: Reader670): uint8 {
	const value = reader.bytes[reader.offset];
	reader.offset += 1;
	return value;
}
function throughRef(ref h: HoldsRef670): int32 { return h.r.v + h.n; }
function throughPtr(ref h: HoldsPtr670): int32 { return h.p[].v + h.n; }
function derefParam(ref p: Ptr<Box670>): int32 { return p[].v; }
function firstName(this ref h: Names670): string { return h.names[0]; }
function measure(ref arr: int32[]): int32 { return arr.length * 10 + arr[1]; }
function twoReads(): int32 {
	let reader: Reader670 = { bytes: [4, 5, 6], offset: 0 };
	const first = nextPlain(reader) as int32;
	const second = nextPlain(reader) as int32;
	return first * 100 + second * 10 + reader.offset;
}
function sumAndMark(ref o: Outer670): int32 {
	let s = 0;
	for (let i = 0; i < o.inner.xs.length; i++) { s += o.inner.xs[i]; }
	o.inner.xs[0] = 100;
	return s + o.tag;
}

test "refParamDeref: a this ref receiver indexes and measures its array field" {
	let reader: Reader670 = { bytes: [4, 5, 6], offset: 0 };
	assert reader.next() == 4;
	assert reader.remaining() == 2;
}

test "refParamDeref: a plain ref parameter indexes its array field" {
	assert twoReads() == 452;
}

const shared670: Ref<Box670> = { v: 5 };
let held670: HoldsRef670 = { r: shared670, n: 1 };

test "refParamDeref: Ref and Ptr fields read through a ref parameter" {
	assert throughRef(held670) == 6;
	let box: Box670 = { v: 7 };
	let hp: HoldsPtr670 = { p: box as Ptr<Box670>, n: 2 };
	assert throughPtr(hp) == 9;
	let p: Ptr<Box670> = box as Ptr<Box670>;
	assert derefParam(p) == 7;
}

test "refParamDeref: a string array field and a ref array parameter" {
	let h: Names670 = { names: ["a", "b"], n: 1 };
	assert h.firstName() == "a";
	let xs: int32[] = [3, 4];
	assert measure(xs) == 24;
}

test "refParamDeref: a nested array field through a ref parameter reads and writes" {
	let o: Outer670 = { inner: { xs: [1, 2, 3] }, tag: 10 };
	assert sumAndMark(o) == 16;
	assert o.inner.xs[0] == 100;
}
