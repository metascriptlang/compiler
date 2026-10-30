// @stdout: utf8=0/0 hex=0/0 base64=0/0 latin1=0/0 HEX=0/0
// @stdout: =>>>><<<=<=<<<<>=><<<<=<=<<<<>>>=<<>>>>>=<>>>>>>=
// @stdout: ab||x|ab|0123456789abcdx|0123456789abcdex|0123456789abcdxy0123456789abcdx|0123456789abcdexy0123456789abcdex
// @stdout: 61.e9.fffd.62 20ac.fffd d83d.de00.fffd.41
function codes(s: string): string { let o = ""; for (let i = 0; i < s.length; i++) o += (i > 0 ? "." : "") + s.charCodeAt(i).toString(16); return o; }

let empty = "";
for (const enc of ["utf8", "hex", "base64", "latin1", "HEX"]) {
	const b = Buffer.fromString("", enc);
	empty += enc + "=" + b.length.toString() + "/" + b.toStringEncoded(enc, 0, b.length).length.toString() + " ";
}
console.log(empty.trim());

const words = ["b", "", "a", "", "ab", "é", "😀"];
let order = "";
for (const x of words) for (const y of words) order += x < y ? "<" : x == y ? "=" : ">";
console.log(order);

console.log([
	"ab".replaceAll("abc", "x"), "".replaceAll("a", "b"), "".replaceAll("", "x"), "ab".replace("abc", "x"),
	"x".replace("x", "0123456789abcd$&"), "x".replace("x", "0123456789abcde$&"),
	"xyx".replaceAll("x", "0123456789abcd$&"), "xyx".replaceAll("x", "0123456789abcde$&"),
].join("|"));

const mixed: number[][] = [[0x61, 0xC3, 0xA9, 0xFF, 0x62], [0xE2, 0x82, 0xAC, 0xE2, 0x82], [0xF0, 0x9F, 0x98, 0x80, 0xC0, 0x41]];
let utf = "";
for (const bytes of mixed) utf += codes(Buffer.fromArray(bytes).toStringEncoded("utf8", 0, bytes.length)) + " ";
console.log(utf.trim());
