// Parity program — search, split, replace and trim, including the edge cases
// where a hand-written byte loop and a native delegation are most likely to
// part ways: no-match sentinels, empty fields, delimiters at the ends, an
// overlapping needle, and a start offset past the end.

function showN(label: string, v: int64): void {
	console.log(label + "=" + v.toString());
}

function show(label: string, v: string): void {
	console.log(label + "=[" + v + "]");
}

function showB(label: string, v: boolean): void {
	console.log(label + "=" + (v ? "true" : "false"));
}

function showParts(label: string, parts: string[]): void {
	let acc = "";
	for (const p of parts) { acc = acc + "<" + p + ">"; }
	console.log(label + " n=" + parts.length.toString() + " " + acc);
}

function main(): void {
	const s = "the quick brown fox";

	showN("idx", s.indexOf("quick"));
	showN("idxChar", s.indexOf("o"));
	showN("idxFrom", s.indexOf("o", 13));
	showN("idxFromPastEnd", s.indexOf("o", 99));
	showN("idxMissing", s.indexOf("zebra"));
	showN("idxEmptyNeedle", s.indexOf(""));
	showN("last", s.lastIndexOf("o"));
	showN("lastMissing", s.lastIndexOf("zebra"));
	showN("idxSelf", s.indexOf(s));

	showB("has", s.contains("brown"));
	showB("hasNot", s.contains("Brown"));
	showB("starts", s.startsWith("the "));
	showB("startsNot", s.startsWith("he"));
	showB("ends", s.endsWith("fox"));
	showB("endsNot", s.endsWith("Fox"));
	showB("startsEmpty", s.startsWith(""));
	showB("startsTooLong", "ab".startsWith("abc"));

	showN("count", "aXbXcX".count("X"));
	showN("countNone", "abc".count("X"));
	showN("countOverlap", "aaaa".count("aa"));

	showParts("split", "a,b,c".split(","));
	showParts("splitEmptyField", "a,,c".split(","));
	showParts("splitLeading", ",a,b".split(","));
	showParts("splitTrailing", "a,b,".split(","));
	showParts("splitNoMatch", "abc".split(","));
	showParts("splitOnlyDelim", ",".split(","));
	showParts("splitMulti", "a--b--c".split("--"));
	showParts("splitEmptyInput", "".split(","));

	show("replaceFirst", "a-b-c".replace("-", "+"));
	show("replaceMissing", "abc".replace("-", "+"));
	show("replaceAll", "a-b-c".replaceAll("-", "+"));
	show("replaceAllWider", "a-b".replaceAll("-", "==="));
	show("replaceAllShrink", "a---b".replaceAll("---", "-"));
	show("replaceEmptyWith", "a-b".replaceAll("-", ""));

	show("trim", "  pad  ".trim());
	show("trimStart", "  pad  ".trimStart());
	show("trimEnd", "  pad  ".trimEnd());
	show("trimTabs", "\t\npad\n\t".trim());
	show("trimNothing", "pad".trim());
	show("trimAll", "   ".trim());

	showB("includesHit", "haystack".includes("stack"));
	showB("includesMiss", "haystack".includes("zzz"));
}
main();
