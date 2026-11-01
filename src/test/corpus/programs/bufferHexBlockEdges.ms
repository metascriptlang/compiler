// @stdout: fromString 6714 mismatches 0
// @stdout: write 140 mismatches 0
function digit(c: int32): int32 {
	if (c >= 48 && c <= 57) return c - 48;
	if (c >= 97 && c <= 102) return c - 87;
	if (c >= 65 && c <= 70) return c - 55;
	return -1;
}
function reference(s: string): string {
	let out = "";
	for (let i = 0; i + 1 < s.length; i += 2) {
		const hi = digit(s.charCodeAt(i));
		const lo = digit(s.charCodeAt(i + 1));
		if (hi < 0 || lo < 0) break;
		const v = hi * 16 + lo;
		out += (v < 16 ? "0" : "") + v.toString(16);
	}
	return out;
}
function body(pairs: int32): string {
	let s = "";
	for (let i = 0; i < pairs; i++) s += "aF09Cd7b".charAt(i % 8) + "0Ff9bA3E".charAt((i * 3) % 8);
	return s;
}
const bad: string[] = ["g", "G", "/", ":", "@", "`", " ", "é", "€"];
const lengths: int32[] = [15, 16, 17, 31, 32, 33, 47, 48, 64, 65];
let cases = 0;
let wrong = 0;
for (const pairs of lengths) {
	const h = body(pairs);
	for (let at = -1; at < h.length; at++) {
		for (const b of bad) {
			const s = at < 0 ? h : h.slice(0, at) + b + h.slice(at + 1);
			cases += 1;
			if (Buffer.fromString(s, "hex").toHex() != reference(s)) wrong += 1;
		}
	}
}
console.log(`fromString ${cases} mismatches ${wrong}`);
cases = 0;
wrong = 0;
for (const pairs of lengths) {
	const h = body(pairs);
	for (const room of [0, 1, 15, 16, 17, 33, 64]) {
		for (const start of [0, 3]) {
			const buf = Buffer.alloc(80);
			buf.fill(0x5a, 0, 80);
			const n = buf.write(h, start, room, "hex");
			const want = reference(h.slice(0, room * 2 > h.length ? h.length : room * 2));
			cases += 1;
			if (n * 2 != want.length || buf.toHex().slice(start * 2, start * 2 + want.length) != want) wrong += 1;
			if (buf.byteAt(start + n) != 0x5a && start + n < 80) wrong += 1;
		}
	}
}
console.log(`write ${cases} mismatches ${wrong}`);
