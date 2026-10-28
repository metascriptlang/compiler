import { byteLength, byteAt, byteSlice } from "./bytes";

extern function scalarString(cp: number): string from "msStringFromCodePoint";

const HEX = "0123456789ABCDEF";

function isUnescaped(b: int32): boolean {
	if (b >= 48 && b <= 57) return true;
	if (b >= 65 && b <= 90) return true;
	if (b >= 97 && b <= 122) return true;
	return b == 45 || b == 95 || b == 46 || b == 33 || b == 126 || b == 42 || b == 39 || b == 40 || b == 41;
}

function hexDigit(b: int32): int32 {
	if (b >= 48 && b <= 57) return b - 48;
	if (b >= 65 && b <= 70) return b - 55;
	if (b >= 97 && b <= 102) return b - 87;
	return -1;
}

function escapedByte(s: string, at: int32, n: int32): int32 {
	if (at + 2 >= n || byteAt(s, at) != 37) throw new URIError("URI malformed");
	const hi = hexDigit(byteAt(s, at + 1));
	const lo = hexDigit(byteAt(s, at + 2));
	if (hi < 0 || lo < 0) throw new URIError("URI malformed");
	return hi * 16 + lo;
}

export function encodeURIComponent(s: string): string {
	const n = byteLength(s);
	let out = "";
	let run = 0;
	for (let i = 0; i < n; i++) {
		const b = byteAt(s, i);
		if (isUnescaped(b)) continue;
		if (i > run) out += byteSlice(s, run, i);
		out += "%" + HEX.byteSlice(b >> 4, (b >> 4) + 1) + HEX.byteSlice(b & 15, (b & 15) + 1);
		run = i + 1;
	}
	if (n > run) out += byteSlice(s, run, n);
	return out;
}

export function decodeURIComponent(s: string): string {
	const n = byteLength(s);
	let out = "";
	let i = 0;
	while (i < n) {
		if (byteAt(s, i) != 37) {
			let j = i + 1;
			while (j < n && byteAt(s, j) != 37) j++;
			out += byteSlice(s, i, j);
			i = j;
			continue;
		}
		const lead = escapedByte(s, i, n);
		i += 3;
		if (lead < 128) {
			out += scalarString(lead as number);
			continue;
		}
		let extra = 0;
		let cp = 0;
		let min = 0;
		if (lead >= 194 && lead <= 223) { extra = 1; cp = lead & 31; min = 128; }
		else if (lead >= 224 && lead <= 239) { extra = 2; cp = lead & 15; min = 2048; }
		else if (lead >= 240 && lead <= 244) { extra = 3; cp = lead & 7; min = 65536; }
		else throw new URIError("URI malformed");
		for (let k = 0; k < extra; k++) {
			const cont = escapedByte(s, i, n);
			if ((cont & 192) != 128) throw new URIError("URI malformed");
			cp = cp * 64 + (cont & 63);
			i += 3;
		}
		if (cp < min || cp > 1114111 || (cp >= 55296 && cp <= 57343)) throw new URIError("URI malformed");
		out += scalarString(cp as number);
	}
	return out;
}
