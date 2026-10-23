// @stdout: string-order-utf16 ok
// string < <= > >= and sort() order by UTF-16 code units: a surrogate pair (U+10000 and up) sorts below U+E000..U+FFFF,
// where UTF-8 byte order puts it above. Every other pair keeps its byte order.
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
