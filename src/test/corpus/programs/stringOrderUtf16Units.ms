// @stdout: string-order-utf16 ok
// @stdout: 6 >>><<>=<<><>>>>><>> >>><<>=<<><>>>>><>>
// @stdout: sort 0 1 2 5 9 12 13 15 11 17 18 14 6 10 16 7 8 3 4
// @stdout: by< 0 1 2 5 9 12 13 15 11 17 18 14 6 10 16 7 8 3 4
// string < <= > >= and sort() order by UTF-16 code units: a surrogate pair (U+10000 and up) sorts below U+E000..U+FFFF,
// and above a lone low surrogate or a greater lone high one, where UTF-8 byte order disagrees. The surrogate rows print
// indices, not strings, so a lone surrogate is not a lane divergence.
const lo = "\u{FFFD}";
const hi = "\u{1F600}";
const ee = "\u{E000}";
const first = "\u{10000}";
const last = "\u{10FFFF}";

let ok = true;
function check(cond: boolean): void { if (!cond) ok = false; }

check(lo > hi && hi < lo && !(lo < hi) && !(hi > lo));
check(ee > first && ee > last && first < ee && last < ee);
check(hi <= lo && lo >= hi && !(lo <= hi));
check("ab" + hi < "ab" + lo && "ab" + lo > "ab" + hi);
check("ab" + hi + "x" < "ab" + ee + "a");
check(hi < hi + "a" && lo < lo + "a" && !(hi < hi));
check("é" < lo && "é" < hi && "z" < "é" && "߿" < ee && "߿" < hi);

const xs = [hi, lo, "z", ee, "é", first, "a"];
xs.sort();
const codes = xs.map((s: string): string => s.charCodeAt(0).toString()).join(",");
check(codes == "97,122,233,55296,55357,57344,65533");

const latin = ["pear", "Apple", "éclair", "apple", "zebra", "Zed", "café", "cafe"];
latin.sort();
check(latin.join(",") == "Apple,Zed,apple,cafe,café,pear,zebra,éclair");

console.log(ok ? "string-order-utf16 ok" : "string-order-utf16 FAIL");

const units: string[] = [
	"a", "é", "퟿", "", "￿", "\uD800", "\uDBFF", "\uDC00", "\uDFFF",
	"\u{10000}", "\u{10FFFF}", "\u{1F600}",
	"\uD83D", "\uD83Dz", "\uD83D", "\uD83D\uDBFF", "\uDBFF", "\u{1F600}a", "\u{1F600}\u{10000}",
];

function sign(a: string, b: string): string {
	return a < b ? "<" : a > b ? ">" : "=";
}

function signLe(a: string, b: string): string {
	return a <= b ? (b <= a ? "=" : "<") : ">";
}

for (let i = 0; i < units.length; i++) {
	let lt = "";
	let le = "";
	for (let j = 0; j < units.length; j++) {
		lt += sign(units[i], units[j]);
		le += signLe(units[i], units[j]);
	}
	console.log(i.toString() + " " + lt + " " + le);
}

function indices(sorted: string[]): string {
	let out = "";
	for (const s of sorted) out += " " + units.indexOf(s).toString();
	return out;
}

const byDefault = units.slice();
byDefault.sort();
console.log("sort" + indices(byDefault));

const byLess = units.slice();
byLess.sort((a: string, b: string): number => a < b ? -1 : a > b ? 1 : 0);
console.log("by<" + indices(byLess));
