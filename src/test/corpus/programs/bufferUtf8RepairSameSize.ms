// @stdout: fffd.41./4 fffd.fffd.fffd./9 61.fffd.62./5
// note: Buffer's UTF-8 decode replaces a malformed prefix with U+FFFD even when the replacement is as long as the bytes it replaces (F0 9F 98 is three bytes, so is U+FFFD), as node does.

function codes(bytes: number[]): string {
	const s = Buffer.fromArray(bytes).toStringEncoded("utf8", 0, bytes.length);
	let o = "";
	for (let i = 0; i < s.length; i++) o += s.charCodeAt(i).toString(16) + ".";
	return `${o}/${s.asBytes().length}`;
}
console.log(`${codes([0xF0, 0x9F, 0x98, 0x41])} ${codes([0xF0, 0x9F, 0x98, 0xE2, 0x82, 0xFF])} ${codes([0x61, 0xE2, 0x82, 0x62])}`);
