// @stdout: A-- 1 true true false true 4
// note: a char is a byte, so a for-of over a string compares with the byte's code, `ch == "e".code`, and prints what TypeScript prints for `s[i] == "e"`. The text forms `ch == "e"`, `"e" == ch`, `ch != "e"` and `case "e"` on a char are refused (checker3pass/scenarios/charEqualsText.ms); they used to pass the checker, fail clang on C and be false on JS and the Raiser.
let line = "";
for (const ch of "abc") { line = line + (ch == "a".code ? "A" : "-"); }
let n = 0;
for (const ch of "hello") { if (ch == "e".code) n += 1; }
const c = 97 as char;
const d = 98 as char;
let hits = 0;
switch (c) {
	case 97 as char: hits += 1; break;
	case 98 as char: hits += 5; break;
	default: break;
}
for (const ch of "aab") { if (ch != "a".code) hits += 1; else hits += 1; }
console.log(line, n, c == "a".code, "a".code == c, c == d, c != d, hits);
