// @stdout: replace aXYc -abc ba e🚀é éé |abc$$1
// @stdout: replaceAll bb ba abababababab éRéR eee |a.$$1b.b.$$1
// @stdout: replaceAll empty needle -a-b-c- - 7:124,233,124,55357,124,56960,124 ab
// @stdout: replace identity true true 0
// @stdout: split ends 5 [|a||b|]
// @stdout: split multi 4 [a|b||c]
// @stdout: split uni 3 [a|b|c]
// @stdout: split none 1 [abc]
// @stdout: split whole 2 [|]
// @stdout: split empty hay 1 []
// @stdout: split empty both 0 []
// @stdout: split units 2 [1:97|1:233]
// @stdout: split astral 4 [1:97|1:55357|1:56960|1:98]
// @stdout: padStart [007] [xyxyxabc] [abc] [abc] [abc] [é🚀é]
// @stdout: padEnd [700] [abcxyxyx] [abc] [abc] [éü-ü] [aba]
// @stdout: pad astral 4:55357,56960,55357,97 4:97,55357,56960,55357 5:233,55357,56960,97,98 2:97,98
// @stdout: pad multi abcabcabc5 5abcabcabc ---🚀 🚀
// @stdout: join [] [a] [abc] [a----c] [] [é·🚀·ü]
function units(s: string): string {
	const out: string[] = [];
	for (let i = 0; i < s.length; i = i + 1) out.push(s.charCodeAt(i).toString());
	return s.length.toString() + ":" + out.join(",");
}

function show(label: string, parts: string[]): void {
	console.log(label + " " + parts.length.toString() + " [" + parts.join("|") + "]");
}

console.log("replace " + "abc".replace("b", "XY") + " " + "abc".replace("", "-") + " " + "aaa".replace("aa", "b") + " " + "é🚀é".replace("é", "e") + " " + "é🚀é".replace("🚀", "") + " " + "ab".replace("ab", "") + "|" + "abc".replace("c", "$&$$$1$'"));
console.log("replaceAll " + "aaaa".replaceAll("aa", "b") + " " + "aaa".replaceAll("aa", "b") + " " + "abab".replaceAll("ab", "ababab") + " " + "é🚀é🚀".replaceAll("🚀", "R") + " " + "ééé".replaceAll("é", "e") + " " + "x".replaceAll("x", "") + "|" + "a.b.".replaceAll(".", "$&$$$1$'"));
console.log("replaceAll empty needle " + "abc".replaceAll("", "-") + " " + "".replaceAll("", "-") + " " + units("é🚀".replaceAll("", "|")) + " " + "ab".replaceAll("", ""));
console.log("replace identity " + ("abc".replace("zz", "q") == "abc") + " " + ("abc".replaceAll("zz", "q") == "abc") + " " + "".replace("a", "b").length.toString());

show("split ends", ",a,,b,".split(","));
show("split multi", "a--b----c".split("--"));
show("split uni", "aébéc".split("é"));
show("split none", "abc".split("x"));
show("split whole", "abc".split("abc"));
show("split empty hay", "".split(","));
show("split empty both", "".split(""));
show("split units", "aé".split("").map((part: string) => units(part)));
show("split astral", "a🚀b".split("").map((part: string) => units(part)));

console.log("padStart [" + "7".padStart(3, "0") + "] [" + "abc".padStart(8, "xy") + "] [" + "abc".padStart(8, "") + "] [" + "abc".padStart(2, "x") + "] [" + "abc".padStart(3, "x") + "] [" + "é".padStart(4, "é🚀") + "]");
console.log("padEnd [" + "7".padEnd(3, "0") + "] [" + "abc".padEnd(8, "xy") + "] [" + "abc".padEnd(8, "") + "] [" + "abc".padEnd(2, "x") + "] [" + "é".padEnd(4, "ü-") + "] [" + "".padEnd(3, "ab") + "]");
console.log("pad astral " + units("a".padStart(4, "🚀")) + " " + units("a".padEnd(4, "🚀")) + " " + units("ab".padStart(5, "é🚀")) + " " + units("ab".padEnd(2, "🚀")));
console.log("pad multi " + "5".padStart(10, "abc") + " " + "5".padEnd(10, "abc") + " " + "🚀".padStart(5, "-") + " " + "🚀".padEnd(2, "-"));

const none: string[] = [];
console.log("join [" + none.join(",") + "] [" + ["a"].join(",") + "] [" + ["a", "b", "c"].join("") + "] [" + ["a", "", "c"].join("--") + "] [" + ["", ""].join("") + "] [" + ["é", "🚀", "ü"].join("·") + "]");
