// @stdout: ascii first 0 0 1 -1 -1
// @stdout: ascii start 3 3 -1 6 -1
// @stdout: ascii last 3 6 7 -1 -1
// @stdout: ascii last from 0 3 3 0 -1
// @stdout: bmp first 1 3 2 4 -1
// @stdout: bmp last 5 3 3 -1 0
// @stdout: cjk first 1 1 3 4 5
// @stdout: cjk last 3 3 1 0 4
// @stdout: astral first 1 4 4 4 8 3
// @stdout: astral last 6 4 0 3
// @stdout: mixed first 0 4 1 2 2 5
// @stdout: mixed last 4 5 6 4 5
// @stdout: empty 0 3 8 8 3 8 0 0 -1 -1
// @stdout: empty uni 0 3 9 9 3 9 0 4
// @stdout: negative 0 2 6 5 1 6 1
// @stdout: beyond -1 -1 5 -1 8 0 -1 -1
// @stdout: edges 6 6 0 0 1 1 1 2 2 2
// @stdout: longer -1 -1 -1 -1 -1
// @stdout: lastIndexOf astral start -1,1,1,1,4,4,6,6,6,6,6
// @stdout: mixed start -1|-1|1,1|-1|1,1|-1|4,1|3|4,4|3|4,4|3|-1,4|3|-1,4|3|-1
function show(label: string, v: int32[]): void {
	let acc = "";
	for (const n of v) acc = acc + " " + n.toString();
	console.log(label + acc);
}

const ascii = "abcabcab";
const bmp = "aébécé";
const cjk = "x日本日本y";
const astral = "a😀b😀😀c";
const mixed = "é日😀é日😀";

show("ascii first", [ascii.indexOf("abc"), ascii.indexOf("ab"), ascii.indexOf("b"), ascii.indexOf("z"), ascii.indexOf("abcabcabc")]);
show("ascii start", [ascii.indexOf("abc", 1), ascii.indexOf("abc", 3), ascii.indexOf("abc", 4), ascii.indexOf("ab", 6), ascii.indexOf("ab", 7)]);
show("ascii last", [ascii.lastIndexOf("abc"), ascii.lastIndexOf("ab"), ascii.lastIndexOf("b"), ascii.lastIndexOf("z"), ascii.lastIndexOf("abcabcabc")]);
show("ascii last from", [ascii.lastIndexOf("abc", 2), ascii.lastIndexOf("abc", 3), ascii.lastIndexOf("ab", 5), ascii.lastIndexOf("ab", 0), ascii.lastIndexOf("c", 1)]);
show("bmp first", [bmp.indexOf("é"), bmp.indexOf("é", 2), bmp.indexOf("bé"), bmp.indexOf("cé"), bmp.indexOf("z")]);
show("bmp last", [bmp.lastIndexOf("é"), bmp.lastIndexOf("é", 4), bmp.lastIndexOf("é", 3), bmp.lastIndexOf("é", 0), bmp.lastIndexOf("a")]);
show("cjk first", [cjk.indexOf("日"), cjk.indexOf("日本"), cjk.indexOf("日", 2), cjk.indexOf("本y"), cjk.indexOf("y")]);
show("cjk last", [cjk.lastIndexOf("日"), cjk.lastIndexOf("日本"), cjk.lastIndexOf("日", 2), cjk.lastIndexOf("x"), cjk.lastIndexOf("本", 100)]);
show("astral first", [astral.indexOf("😀"), astral.indexOf("😀", 2), astral.indexOf("😀", 4), astral.indexOf("😀😀"), astral.indexOf("c"), astral.indexOf("b")]);
show("astral last", [astral.lastIndexOf("😀"), astral.lastIndexOf("😀😀"), astral.lastIndexOf("a"), astral.lastIndexOf("b", 3)]);
show("mixed first", [mixed.indexOf("é"), mixed.indexOf("é", 1), mixed.indexOf("日"), mixed.indexOf("😀"), mixed.indexOf("😀é"), mixed.indexOf("日😀", 3)]);
show("mixed last", [mixed.lastIndexOf("é"), mixed.lastIndexOf("日"), mixed.lastIndexOf("😀"), mixed.lastIndexOf("é", 4), mixed.lastIndexOf("日😀", 6)]);
show("empty", [ascii.indexOf(""), ascii.indexOf("", 3), ascii.indexOf("", 100), ascii.lastIndexOf(""), ascii.lastIndexOf("", 3), ascii.lastIndexOf("", 100), "".indexOf(""), "".lastIndexOf(""), "".indexOf("a"), "".lastIndexOf("a")]);
show("empty uni", [astral.indexOf(""), astral.indexOf("", 3), astral.indexOf("", 100), astral.lastIndexOf(""), astral.lastIndexOf("", 3), astral.lastIndexOf("", 100), mixed.indexOf("", -5), mixed.lastIndexOf("", 4)]);
show("negative", [ascii.indexOf("a", -1), ascii.indexOf("c", -100), ascii.lastIndexOf("a", -1), ascii.lastIndexOf("c", -100), astral.indexOf("😀", -3), astral.lastIndexOf("😀", -3), bmp.indexOf("é", -2147483647)]);
show("beyond", [ascii.indexOf("a", 8), ascii.indexOf("a", 2147483647), ascii.lastIndexOf("c", 2147483647), astral.indexOf("c", 2147483647), astral.lastIndexOf("c", 2147483647), bmp.lastIndexOf("a", 2147483647), cjk.indexOf("y", 7), cjk.indexOf("y", 6)]);
show("edges", [ascii.indexOf("ab", 6), ascii.lastIndexOf("ab"), "aa".indexOf("aa"), "aa".lastIndexOf("aa"), "aaa".indexOf("aa", 1), "aaa".lastIndexOf("aa"), "aaaa".lastIndexOf("aa", 1), "😀😀".indexOf("😀", 1), "😀😀".indexOf("😀", 2), "😀😀".lastIndexOf("😀", 2)]);
show("longer", ["ab".indexOf("abc"), "ab".lastIndexOf("abc"), "é".indexOf("éé"), "é".lastIndexOf("éé"), "x".indexOf("xy", 0)]);

const fromEach: string[] = [];
for (let k = 0; k <= 10; k++) fromEach.push(`${astral.lastIndexOf("😀", k)}`);
console.log(`lastIndexOf astral start ${fromEach.join(",")}`);
const mixedStart = "é😀x😀";
const mixedEach: string[] = [];
for (let k = 0; k <= 7; k++) mixedEach.push(`${mixedStart.lastIndexOf("😀", k)}|${mixedStart.lastIndexOf("x", k)}|${mixedStart.indexOf("😀", k)}`);
console.log(`mixed start ${mixedEach.join(",")}`);
