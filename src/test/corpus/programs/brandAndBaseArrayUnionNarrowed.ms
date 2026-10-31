// @stdout: 3 3 3 3
// @stdout: 3 3 3 3
// @stdout: 3 3
type In = string | Buffer | uint8[];

function size(view: Readonly<Span<uint8>>): int32 { return view.length as int32; }
function viewed(data: In): int32 {
	if (typeof data == "string") return -1;
	return size(data);
}
function bound(data: In): int32 {
	if (typeof data == "string") return -1;
	const b: uint8[] = data;
	return b.length as int32;
}
function cast(data: In): int32 {
	if (typeof data == "string") return -1;
	return size(data as uint8[]);
}
function bytesOnly(data: Buffer | uint8[]): int32 { return size(data); }
function passedOn(data: In): int32 {
	if (typeof data == "string") return -1;
	return bytesOnly(data);
}
function notString(data: In): int32 {
	if (typeof data != "string") return size(data);
	return -1;
}

const plain: uint8[] = [1, 2, 3];
const buf = [1, 2, 3] as Buffer;
console.log(viewed(plain), viewed(buf), bound(plain), bound(buf));
console.log(cast(plain), cast(buf), passedOn(plain), passedOn(buf));
console.log(notString(plain), notString(buf));
