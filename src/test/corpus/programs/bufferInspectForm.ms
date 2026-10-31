// @stdout: <Buffer 61 62 63>
// @stdout: { b: <Buffer 61 62 63> }
// @stdout: , b: <Buffer 61 62 63> }
// @stdout: <Buffer >
// @stdout: <Buffer 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01>
// @stdout: <Buffer 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 ... 1 more byte>
// @stdout: <Buffer ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ... 10 more bytes>
// @stdout: label <Buffer 61 62 63>
interface Holder { name: string; b: Buffer }
function bytes(values: number[]): Buffer {
	when (js) { return Buffer.fromArray(values); } else {
		const raw: uint8[] = [];
		for (const v of values) raw.push(v as uint8);
		return raw as Buffer;
	}
}
function filled(n: int32, value: number): Buffer {
	const values: number[] = [];
	for (let i = 0; i < n; i++) values.push(value);
	return bytes(values);
}
const small = bytes([0x61, 0x62, 0x63]);
console.log(small);
console.log({ b: small });
const h: Holder = { name: "h", b: small };
console.log(h);
console.log([small]);
console.log(filled(0, 0));
console.log(filled(50, 1));
console.log(filled(51, 1));
console.log(filled(60, 171));
console.log("label", small);
