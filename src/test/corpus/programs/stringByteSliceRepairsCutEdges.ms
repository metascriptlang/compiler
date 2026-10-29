// @stdout: mixed 10
// @stdout: 0: _ 61 61.fffd 61.fffd 61.20ac 61.20ac.62 61.20ac.62.fffd 61.20ac.62.fffd 61.20ac.62.fffd 61.20ac.62.d83d.de00 61.20ac.62.d83d.de00.63
// @stdout: 1: _ fffd fffd 20ac 20ac.62 20ac.62.fffd 20ac.62.fffd 20ac.62.fffd 20ac.62.d83d.de00 20ac.62.d83d.de00.63
// @stdout: 2: _ fffd fffd.fffd fffd.fffd.62 fffd.fffd.62.fffd fffd.fffd.62.fffd fffd.fffd.62.fffd fffd.fffd.62.d83d.de00 fffd.fffd.62.d83d.de00.63
// @stdout: 3: _ fffd fffd.62 fffd.62.fffd fffd.62.fffd fffd.62.fffd fffd.62.d83d.de00 fffd.62.d83d.de00.63
// @stdout: 4: _ 62 62.fffd 62.fffd 62.fffd 62.d83d.de00 62.d83d.de00.63
// @stdout: 5: _ fffd fffd fffd d83d.de00 d83d.de00.63
// @stdout: 6: _ fffd fffd.fffd fffd.fffd.fffd fffd.fffd.fffd.63
// @stdout: 7: _ fffd fffd.fffd fffd.fffd.63
// @stdout: 8: _ fffd fffd.63
// @stdout: 9: _ 63
// @stdout: 10: _
// @stdout: two 2
// @stdout: 0: _ fffd e9
// @stdout: 1: _ fffd
// @stdout: 2: _
// @stdout: clamped fffd fffd _ 62.63
// note: byteSlice reads a cut inside a multibyte sequence as TextDecoder reads the same bytes, one U+FFFD per maximal subpart, on every backend. Expected lines come from node (TextDecoder).

function units(s: string): string {
	let out = "";
	for (let i = 0; i < s.length; i++) out += (i == 0 ? "" : ".") + s.charCodeAt(i).toString(16);
	return out == "" ? "_" : out;
}

function sweep(label: string, s: string): void {
	const n = s.byteLength;
	console.log(`${label} ${n}`);
	for (let a = 0; a <= n; a++) {
		let line = "";
		for (let b = a; b <= n; b++) line += (b == a ? "" : " ") + units(s.byteSlice(a, b));
		console.log(`${a}: ${line}`);
	}
}

sweep("mixed", "a€b😀c");
sweep("two", "é");
console.log(`clamped ${units("é".byteSlice(-3, 1))} ${units("é".byteSlice(1, 9))} ${units("abc".byteSlice(2, 1))} ${units("abc".byteSlice(1, 3))}`);
