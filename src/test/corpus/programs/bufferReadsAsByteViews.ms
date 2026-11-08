// @stdout: 60 10 3 20 3
// @stdout: 30 3 2
// note: a Buffer reaches every read-only byte view parameter without a copy; an owned uint8[] is a spread of it.
function sum(bytes: Readonly<Span<uint8>>): int32 {
	let total = 0;
	for (let i = 0; i < bytes.length; i++) total += bytes[i];
	return total;
}
function first(bytes: Readonly<Span<uint8>>): uint8 { return bytes[0]; }
function count(view: Readonly<Span<uint8>>): int32 { return view.length as int32; }

const raw: uint8[] = [10, 20, 30];
const buf = Buffer.from(raw);
console.log(sum(buf), first(buf), count(buf), buf[1], buf.length);
const wide: uint8[] = [...buf];
console.log(wide[2], wide.length, buf.subarray(1, 3).length);
