// @stdout: from ascii utf8=686921 UTF-8=686921 latin1=686921 Binary=686921 ascii=686921 ucs2=680069002100 UTF16LE=680069002100 utf-16le=680069002100 ucs-2=680069002100
// @stdout: write ascii utf8=3 006869210000000000000000 UTF-8=3 006869210000000000000000 latin1=3 006869210000000000000000 Binary=3 006869210000000000000000 ascii=3 006869210000000000000000 ucs2=6 006800690021000000000000 UTF16LE=6 006800690021000000000000 utf-16le=6 006800690021000000000000 ucs-2=6 006800690021000000000000
// @stdout: from latin utf8=636166c3a9 UTF-8=636166c3a9 latin1=636166e9 Binary=636166e9 ascii=636166e9 ucs2=630061006600e900 UTF16LE=630061006600e900 utf-16le=630061006600e900 ucs-2=630061006600e900
// @stdout: write latin utf8=5 00636166c3a9000000000000 UTF-8=5 00636166c3a9000000000000 latin1=4 00636166e900000000000000 Binary=4 00636166e900000000000000 ascii=4 00636166e900000000000000 ucs2=8 00630061006600e900000000 UTF16LE=8 00630061006600e900000000 utf-16le=8 00630061006600e900000000 ucs-2=8 00630061006600e900000000
// @stdout: from cjk utf8=e4b8ade69687 UTF-8=e4b8ade69687 latin1=2d87 Binary=2d87 ascii=2d87 ucs2=2d4e8765 UTF16LE=2d4e8765 utf-16le=2d4e8765 ucs-2=2d4e8765
// @stdout: write cjk utf8=6 00e4b8ade696870000000000 UTF-8=6 00e4b8ade696870000000000 latin1=2 002d87000000000000000000 Binary=2 002d87000000000000000000 ascii=2 002d87000000000000000000 ucs2=4 002d4e876500000000000000 UTF16LE=4 002d4e876500000000000000 utf-16le=4 002d4e876500000000000000 ucs-2=4 002d4e876500000000000000
// @stdout: from astral utf8=61f09f9880 UTF-8=61f09f9880 latin1=613d00 Binary=613d00 ascii=613d00 ucs2=61003dd800de UTF16LE=61003dd800de utf-16le=61003dd800de ucs-2=61003dd800de
// @stdout: write astral utf8=5 0061f09f9880000000000000 UTF-8=5 0061f09f9880000000000000 latin1=3 00613d000000000000000000 Binary=3 00613d000000000000000000 ascii=3 00613d000000000000000000 ucs2=6 0061003dd800de0000000000 UTF16LE=6 0061003dd800de0000000000 utf-16le=6 0061003dd800de0000000000 ucs-2=6 0061003dd800de0000000000
// @stdout: from lone utf8=78efbfbd79 UTF-8=78efbfbd79 latin1=780079 Binary=780079 ascii=780079 ucs2=780000d87900 UTF16LE=780000d87900 utf-16le=780000d87900 ucs-2=780000d87900
// @stdout: write lone utf8=5 0078efbfbd79000000000000 UTF-8=5 0078efbfbd79000000000000 latin1=3 007800790000000000000000 Binary=3 007800790000000000000000 ascii=3 007800790000000000000000 ucs2=6 00780000d879000000000000 UTF16LE=6 00780000d879000000000000 utf-16le=6 00780000d879000000000000 ucs-2=6 00780000d879000000000000
// @stdout: room utf8 e-acute after ab 2 61620000
// @stdout: room utf8 e-acute last byte 0 00000000
// @stdout: room utf8 cjk in 2 0 00000000
// @stdout: room utf8 emoji in 3 0 000000
// @stdout: room utf8 two e-acute in 3 2 00c3a900
// @stdout: room utf8 lone fits 4 61efbfbd
// @stdout: room utf8 lone in 2 0 000000
// @stdout: room ucs2 ab in 3 2 61000000
// @stdout: room ucs2 emoji in 3 2 3dd80000
// @stdout: room latin1 e-acute in 1 1 000000e9
// @stdout: room latin1 emoji in 1 1 3d000000
// @stdout: room ascii emoji in 3 3 3d006100
// @stdout: toString mixed 68.69.fffd.e9.4e2d.d83d.de00.fffd.fffd.fffd.fffd.0
// @stdout: toString lone 78.fffd.fffd.fffd.79
// @stdout: interpolated lone 78.fffd.fffd.fffd.79
// @stdout: toString mixed utf8 68.69.fffd.e9.4e2d.d83d.de00.fffd.fffd.fffd.fffd.0
// @stdout: toString mixed latin1 68.69.e9.c3.a9.e4.b8.ad.f0.9f.98.80.ed.a0.80.ff.0
// @stdout: toString mixed ascii 68.69.69.43.29.64.38.2d.70.1f.18.0.6d.20.0.7f.0
// @stdout: toString mixed ucs2 6968.c3e9.e4a9.adb8.9ff0.8098.a0ed.ff80
// @stdout: toString mixed UTF-16LE 6968.c3e9.e4a9.adb8.9ff0.8098.a0ed.ff80
// @stdout: toString mixed hex 36.38.36.39.65.39.63.33.61.39.65.34.62.38.61.64.66.30.39.66.39.38.38.30.65.64.61.30.38.30.66.66.30.30
// @stdout: toString mixed base64 61.47.6e.70.77.36.6e.6b.75.4b.33.77.6e.35.69.41.37.61.43.41.2f.77.41.3d
// @stdout: toString mixed base64url 61.47.6e.70.77.36.6e.6b.75.4b.33.77.6e.35.69.41.37.61.43.41.5f.77.41
// @stdout: toString mixed ucs2 odd e969.a9c3
// @stdout: toString ucs2 pair d83d.de00
// @stdout: toString ucs2 lone high d800.41
// @stdout: toString ucs2 low then high de00.d800
// @stdout: ucs2 round trip 61.d83d.de00.d800.e9
// @stdout: unknown from threw TypeError Unknown encoding: bogus
// @stdout: unknown from empty threw TypeError Unknown encoding: bogus
// @stdout: unknown write threw TypeError Unknown encoding: bogus
// @stdout: unknown write empty threw TypeError Unknown encoding: bogus
// @stdout: unknown toString threw TypeError Unknown encoding: bogus
// @stdout: unknown toString empty range []
// @stdout: unknown fill threw TypeError Unknown encoding: utf9
// @stdout: empty name from c3a9
// @stdout: empty name write 2 c3a90000
// @stdout: empty name fill c3a9c3
// @stdout: empty name toString [TypeError Unknown encoding: ]
// @stdout: byteLength empty name 2
// @stdout: byteLength hex 1 1
// @stdout: byteLength base64 3 1 0
// @stdout: byteLength unknown 2
// @stdout: byteLength LATIN1 1
// @stdout: byteLength UCS2 6
// @stdout: byteLength Utf-8 6
// @stdout: isEncoding true true true false
// @stdout: fill latin1 e9e9e9e9
// @stdout: fill lone utf8 efbfbdef
// @stdout: fill ucs2 6100e90061
// @stdout: fill ascii e9e9e9
// @stdout: fill UTF-8 c3a9c3a9c3

const texts: string[] = ["hi!", "café", "中文", "a😀", "x\uD800y"];
const names: string[] = ["ascii", "latin", "cjk", "astral", "lone"];
const encodings: string[] = ["utf8", "UTF-8", "latin1", "Binary", "ascii", "ucs2", "UTF16LE", "utf-16le", "ucs-2"];

function codes(s: string): string {
	let out = "";
	for (let i = 0; i < s.length; i++) out += (i > 0 ? "." : "") + s.charCodeAt(i).toString(16);
	return out;
}

function failure(e: unknown): string {
	const kind = e instanceof TypeError ? "TypeError" : e instanceof RangeError ? "RangeError" : "Error";
	return `${kind} ${(e as Error).message}`;
}

function attempt(label: string, call: () => string): void {
	try {
		console.log(`${label} ${call()}`);
	} catch (e) {
		console.log(`${label} threw ${failure(e)}`);
	}
}

function each(call: (encoding: string) => string): string {
	let out = "";
	for (let k = 0; k < encodings.length; k++) {
		let cell = "";
		try {
			cell = call(encodings[k]);
		} catch (e) {
			cell = failure(e);
		}
		out += ` ${encodings[k]}=${cell}`;
	}
	return out;
}

function written(size: number, text: string, offset: number, length: number, encoding: string): string {
	const b = Buffer.alloc(size);
	const n = b.write(text, offset, length, encoding);
	return `${n} ${b.toHex()}`;
}

function filled(size: number, text: string, encoding: string): string {
	const b = Buffer.alloc(size);
	b.fillString(text, 0, size, encoding);
	return b.toHex();
}

for (let t = 0; t < texts.length; t++) {
	console.log(`from ${names[t]}${each((encoding: string): string => Buffer.fromString(texts[t], encoding).toHex())}`);
	console.log(`write ${names[t]}${each((encoding: string): string => written(12, texts[t], 1, 10, encoding))}`);
}

attempt("room utf8 e-acute after ab", () => written(4, "abé", 0, 3, "utf8"));
attempt("room utf8 e-acute last byte", () => written(4, "é", 3, 1, "utf8"));
attempt("room utf8 cjk in 2", () => written(4, "中", 0, 2, "utf8"));
attempt("room utf8 emoji in 3", () => written(3, "😀", 0, 3, "utf8"));
attempt("room utf8 two e-acute in 3", () => written(4, "éé", 1, 3, "utf8"));
attempt("room utf8 lone fits", () => written(4, "a\uD800", 0, 4, "utf8"));
attempt("room utf8 lone in 2", () => written(3, "\uD800", 0, 2, "utf8"));
attempt("room ucs2 ab in 3", () => written(4, "ab", 0, 3, "ucs2"));
attempt("room ucs2 emoji in 3", () => written(4, "😀", 0, 3, "utf16le"));
attempt("room latin1 e-acute in 1", () => written(4, "é", 3, 1, "latin1"));
attempt("room latin1 emoji in 1", () => written(4, "😀", 0, 1, "latin1"));
attempt("room ascii emoji in 3", () => written(4, "😀a", 0, 3, "ascii"));

const mixed = Buffer.fromArray([0x68, 0x69, 0xe9, 0xc3, 0xa9, 0xe4, 0xb8, 0xad, 0xf0, 0x9f, 0x98, 0x80, 0xed, 0xa0, 0x80, 0xff, 0x00]);
const lone = Buffer.fromArray([0x78, 0xed, 0xa0, 0x80, 0x79]);
attempt("toString mixed", () => codes(mixed.toString()));
attempt("toString lone", () => codes(lone.toString()));
attempt("interpolated lone", () => codes(`${lone}`));
const ranges: string[] = ["utf8", "latin1", "ascii", "ucs2", "UTF-16LE", "hex", "base64", "base64url"];
for (let k = 0; k < ranges.length; k++) {
	attempt(`toString mixed ${ranges[k]}`, () => codes(mixed.toStringEncoded(ranges[k], 0, mixed.length)));
}
attempt("toString mixed ucs2 odd", () => codes(mixed.toStringEncoded("ucs2", 1, 6)));
attempt("toString ucs2 pair", () => codes(Buffer.fromArray([0x3d, 0xd8, 0x00, 0xde]).toStringEncoded("ucs2", 0, 4)));
attempt("toString ucs2 lone high", () => codes(Buffer.fromArray([0x00, 0xd8, 0x41, 0x00]).toStringEncoded("ucs2", 0, 4)));
attempt("toString ucs2 low then high", () => codes(Buffer.fromArray([0x00, 0xde, 0x00, 0xd8]).toStringEncoded("ucs2", 0, 4)));
attempt("ucs2 round trip", () => codes(Buffer.fromString("a😀\uD800é", "ucs2").toStringEncoded("utf16le", 0, 10)));

attempt("unknown from", () => Buffer.fromString("x", "bogus").toHex());
attempt("unknown from empty", () => Buffer.fromString("", "bogus").toHex());
attempt("unknown write", () => written(4, "x", 0, 4, "bogus"));
attempt("unknown write empty", () => written(4, "", 0, 4, "bogus"));
attempt("unknown toString", () => mixed.toStringEncoded("bogus", 0, 4));
attempt("unknown toString empty range", () => `[${mixed.toStringEncoded("bogus", 3, 1)}]`);
attempt("unknown fill", () => filled(4, "ab", "utf9"));
attempt("empty name from", () => Buffer.fromString("é", "").toHex());
attempt("empty name write", () => written(4, "é", 0, 4, ""));
attempt("empty name fill", () => filled(3, "é", ""));
attempt("empty name toString", () => {
	try {
		return mixed.toStringEncoded("", 0, 2);
	} catch (e) {
		return `[${failure(e)}]`;
	}
});
attempt("byteLength empty name", () => `${Buffer.byteLength("é", "")}`);
attempt("byteLength hex", () => `${Buffer.byteLength("abc", "hex")} ${Buffer.byteLength("é0", "hex")}`);
attempt("byteLength base64", () => `${Buffer.byteLength("abcde", "base64")} ${Buffer.byteLength("ab==", "base64url")} ${Buffer.byteLength("=", "base64")}`);
attempt("byteLength unknown",() => `${Buffer.byteLength("é", "bogus")}`);
attempt("byteLength LATIN1", () => `${Buffer.byteLength("é", "LATIN1")}`);
attempt("byteLength UCS2", () => `${Buffer.byteLength("é😀", "UCS2")}`);
attempt("byteLength Utf-8", () => `${Buffer.byteLength("é😀", "Utf-8")}`);
attempt("isEncoding", () => `${Buffer.isBufferEncoding("UTF8")} ${Buffer.isBufferEncoding("Latin1")} ${Buffer.isBufferEncoding("utf-16le")} ${Buffer.isBufferEncoding("bogus")}`);

attempt("fill latin1", () => filled(4, "é", "latin1"));
attempt("fill lone utf8", () => filled(4, "\uD800", "utf8"));
attempt("fill ucs2", () => filled(5, "aé", "ucs2"));
attempt("fill ascii", () => filled(3, "é", "ascii"));
attempt("fill UTF-8", () => filled(5, "é", "UTF-8"));
