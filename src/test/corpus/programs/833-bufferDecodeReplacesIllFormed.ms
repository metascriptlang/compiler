// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: E2 19 C7 01 88 0F 39 EB 2B 0A -> 10 [fffd 19 fffd 1 fffd f 39 fffd 2b a]
// note: each line is the UTF-16 view of one decode, so every backend must replace ill-formed UTF-8 the way TextDecoder does.

function hex2(n: int32): string {
	const digits = "0123456789ABCDEF";
	return digits.charAt(n >> 4) + digits.charAt(n & 15);
}

function decodeLine(bytes: int32[], encoding: string): string {
	const buf = Buffer.alloc(bytes.length);
	let shown = "";
	for (let i: int32 = 0; i < bytes.length; i++) {
		buf.set(i, bytes[i]);
		shown = shown + (i > 0 ? " " : "") + hex2(bytes[i]);
	}
	const s = buf.toStringEncoded(encoding, 0, bytes.length);
	let units = "";
	for (let i: int32 = 0; i < s.length; i++) {
		units = units + (i > 0 ? " " : "") + s.charCodeAt(i).toString(16);
	}
	return `${shown} -> ${s.length} [${units}]`;
}

function main(): void {
	console.log(decodeLine([0xE2, 0x19, 0xC7, 0x01, 0x88, 0x0F, 0x39, 0xEB, 0x2B, 0x0A], "utf-8"));
	console.log(decodeLine([0xE2, 0x82], "utf-8"));
	console.log(decodeLine([0xE2, 0x82, 0xAC, 0x21], "utf-8"));
	console.log(decodeLine([0xF0, 0x9F, 0x98], "utf-8"));
	console.log(decodeLine([0xF0, 0x9F, 0x98, 0x80], "utf-8"));
	console.log(decodeLine([0xC0, 0xAF, 0xE0, 0x80, 0xAF], "utf-8"));
	console.log(decodeLine([0xED, 0xA0, 0x80], "utf-8"));
	console.log(decodeLine([0xF4, 0x90, 0x80, 0x80], "utf-8"));
	console.log(decodeLine([0xFF, 0xFE, 0x41], "utf8"));
	console.log(decodeLine([0xEF, 0xBB, 0xBF, 0x42], "utf-8"));
	console.log(decodeLine([0x41, 0xE9, 0xFF], "latin1"));
	console.log(decodeLine([0x41, 0xE9, 0xFF], "ascii"));
	const cut = Buffer.alloc(3);
	cut.set(0, 0x7A);
	cut.set(1, 0xC3);
	cut.set(2, 0x0A);
	const text = cut.toStringEncoded("utf-8", 0, 3);
	console.log(`trim ${text.slice(0, text.length - 1).length} ${text.endsWith("\n")}`);
}

main();
