// @stdout: buf 3 1 6
// @stdout: info 2 7
// @stdout: tag 4 c
// @stdout: refs 9 5 5
// @stdout: box 8 owner 7
// @xfail(raiser): a struct field Readonly<Span<char>> built from a string stops the Raiser with 'expected an array, got value kind String', the same on the installed msc; card 2026-11-01-raiser-a-struct-field-view-of-a-string-is-not-an-array
struct Buf { data: Readonly<Span<uint8>>; base: int64; size: int32; }
struct Info { data: Readonly<Span<uint8>>; cff: Buf; n: int32; }
struct Tok { text: Readonly<Span<char>>; }
struct Chunk { bytes: Readonly<Span<uint8>>; n: int32; }
struct Box<T> { v: Readonly<Span<T>>; n: int32; }

function newBuf(data: Readonly<Span<uint8>>): Buf { return { data: data, base: 0, size: data.length as int32 }; }
function rangeOf(this b: Buf, size: int32): Buf {
	if (size < 0) { return newBuf(b.data); }
	return { data: b.data, base: b.base + 1, size: size };
}
function initInfo(data: Readonly<Span<uint8>>, n: int32): Info | null {
	let info: Info = { data: data, cff: newBuf(data), n: n };
	if (n == 0) { return null; }
	info.cff = newBuf(data).rangeOf(2);
	return info;
}
function tag(b: Tok, label: string): Tok { return label.length > 0 ? b : b; }
function copied(t: Tok): Tok { return { ...t }; }
function advance(this ref c: Chunk, k: int32): void { c.n += k; }
function first(b: Box<uint8>): int32 { return b.v[0] as int32; }
function swapTo(c: Chunk, xs: Readonly<Span<uint8>>): int32 { let d: Chunk = { bytes: xs, n: c.n }; d.advance(1); return d.bytes[0] as int32; }
class Owner {
	data: uint8[] = [];
	constructor() { for (let i = 0; i < 4; i++) this.data.push((7 + i) as uint8); }
	view(): Chunk { return { bytes: this.data, n: 1 }; }
}

function run(): void {
	const bytes: uint8[] = [5, 6, 7];
	const b = newBuf(bytes).rangeOf(1);
	console.log("buf", newBuf(bytes).size, b.size, b.data[1]);
	const info = initInfo(bytes, 1);
	if (info != null) console.log("info", info.cff.size, info.data[2]);
	const s = "abcd".repeat(1);
	const t = copied(tag({ text: s }, "x"));
	console.log("tag", t.text.length, t.text[2]);
	const other: uint8[] = [9, 8];
	let r: Chunk = { bytes: bytes, n: 2 };
	r.advance(3);
	console.log("refs", swapTo(r, other), r.bytes[0], r.n);
	const o = new Owner();
	const v = o.view();
	console.log("box", first({ v: other, n: 1 }) - 1, "owner", v.bytes[0]);
}
run();
