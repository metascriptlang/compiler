// @stdout: 60 10 3 3 20 3
// @stdout: 30 3 2
function sum(bytes: uint8[]): int32 {
	let total = 0;
	for (let i = 0; i < bytes.length; i++) total += bytes[i];
	return total;
}
function first(bytes: Readonly<uint8[]>): uint8 { return bytes[0]; }
function count(view: Readonly<Span<uint8>>): int32 { return view.length as int32; }
function lengths<T>(items: T[]): int32 { return items.length as int32; }

const raw: uint8[] = [10, 20, 30];
const buf = raw as Buffer;
console.log(sum(buf), first(buf), count(buf), lengths(buf), buf[1], buf.length);
const wide: uint8[] = buf;
console.log(wide[2], [...buf].length, buf[1..3].length);
