// @stdout: ab|ab|ab|ab
// @stdout: a�b€|a�b€|a�b€|a�b€
// @stdout: x=a�b€
// @stdout: 97,98
function bytes(values: number[]): Buffer {
	when (js) { return Buffer.fromArray(values); } else {
		const raw: uint8[] = [];
		for (const v of values) raw.push(v as uint8);
		return raw as Buffer;
	}
}
const ascii = bytes([0x61, 0x62]);
const bad = bytes([0x61, 0xff, 0x62, 0xe2, 0x82, 0xac]);
console.log(`${ascii}|${String(ascii)}|${"" + ascii}|${ascii.toString()}`);
console.log(`${bad}|${String(bad)}|${"" + bad}|${bad.toString()}`);
let acc = "x=";
acc += bad;
console.log(acc);
const plain: uint8[] = [0x61, 0x62];
console.log(`${plain}`);
