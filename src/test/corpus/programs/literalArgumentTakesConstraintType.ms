// @stdout: 200 2 3 3 -5 6
// @exit: 0

type ByteInput = string | Uint8Array | Readonly<Span<uint8>>;

function byte<D extends uint8>(d: D): int64 { return d as int64; }
function vec<D extends uint8[]>(d: D): int64 { return d.length; }
function view<D extends Readonly<Span<uint8>>>(d: D): int64 { return d.length; }
function input<D extends ByteInput>(d: D): int64 { return typeof d == "string" ? d.asBytes().length : d.length; }
function signed<D extends int8>(d: D): int64 { return d as int64; }
function sum<D extends uint16[]>(d: D): int64 {
	let total: int64 = 0;
	for (const x of d) total += x as int64;
	return total;
}

console.log(byte(200), vec([1, 2]), view([1, 2, 3]), input([97, 98, 99]), signed(-5), sum([1, 2, 3]));
