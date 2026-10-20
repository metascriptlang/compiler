// @stdout: split empty both 0 []
// @stdout: split empty sep 3 [1|1|1]
// @stdout: split overlap 3 [||]
// @stdout: split uni sep 3 [a|b|c]
// @stdout: replaceAll empty -a-b-c- -
// @stdout: replaceAll overlap bb dollar a$&$1b long ab uni e🚀e éRé
// @stdout: replace +bc -abc abc é$&
// @stdout: includes true true false true true
// @stdout: count 2 4 2 0
// @stdout: byteSlice he.ello..
function show(label: string, parts: string[]): void {
	console.log(label + " " + parts.length.toString() + " [" + parts.join("|") + "]");
}

show("split basic", "a,b,,c,".split(","));
show("split empty hay", "".split(","));
show("split empty both", "".split(""));
show("split empty sep", "é🚀".split("").map((part: string) => part.length.toString()));
show("split long sep", "ab".split("abc"));
show("split overlap", "aaaa".split("aa"));
show("split uni sep", "aébéc".split("é"));
console.log("replaceAll empty " + "abc".replaceAll("", "-") + " " + "".replaceAll("", "-"));
console.log("replaceAll overlap " + "aaaa".replaceAll("aa", "b") + " dollar " + "a.b".replaceAll(".", "$&$1")
	+ " long " + "ab".replaceAll("abc", "x") + " uni " + "é🚀é".replaceAll("é", "e") + " " + "é🚀é".replaceAll("🚀", "R"));
console.log("replace " + "abc".replace("a", "+") + " " + "abc".replace("", "-") + " " + "abc".replace("x", "-") + " " + "é🚀".replace("🚀", "$&"));
console.log("includes " + "abc".includes("") + " " + "abc".includes("bc") + " " + "ab".includes("abc") + " " + "é🚀".includes("🚀") + " " + "".includes(""));
console.log("count " + "aaaa".count("aa").toString() + " " + "abc".count("").toString() + " " + "é🚀é".count("é").toString() + " " + "ab".count("abc").toString());
console.log("byteSlice " + "hello".byteSlice(-3, 2) + "." + "hello".byteSlice(1, 99) + "." + "hello".byteSlice(3, 1) + ".");
