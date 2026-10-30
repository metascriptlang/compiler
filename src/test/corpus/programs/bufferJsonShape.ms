// @stdout: {"type":"Buffer","data":[97,98]}
// @stdout: {"b":{"type":"Buffer","data":[97,98]}}
// @stdout: {"type":"Buffer","data":[]}
// @stdout: {"name":"h","b":{"type":"Buffer","data":[97,98]}}
interface Holder { name: string; b: Buffer }
function bytes(values: number[]): Buffer {
	when (js) { return Buffer.fromArray(values); } else {
		const raw: uint8[] = [];
		for (const v of values) raw.push(v as uint8);
		return raw as Buffer;
	}
}
const b = bytes([0x61, 0x62]);
const empty = bytes([]);
console.log(JSON.stringify(b));
console.log(JSON.stringify({ b: b }));
console.log(JSON.stringify(empty));
const h: Holder = { name: "h", b: b };
console.log(JSON.stringify(h));
