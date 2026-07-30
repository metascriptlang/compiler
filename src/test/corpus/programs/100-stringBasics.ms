// Parity program — the ASCII string surface, byte-compared across every lane.
// Broad and shallow on purpose: this is the floor the rest of the 1xx cluster
// stands on, so a regression in plain concat/index/compare shows up here first
// instead of being diagnosed as a unicode bug in 101.

function show(label: string, v: string): void {
	console.log(label + "=[" + v + "]");
}

function showN(label: string, v: int64): void {
	console.log(label + "=" + v.toString());
}

function showB(label: string, v: boolean): void {
	console.log(label + "=" + (v ? "true" : "false"));
}

function main(): void {
	const s = "Hello, World";

	show("concat", "Hello" + ", " + "World");
	show("concatEmpty", "" + "a" + "");
	showN("len", s.length);
	showN("lenEmpty", "".length);

	show("upper", s.toUpperCase());
	show("lower", s.toLowerCase());
	show("reverse", "abcdef".reverse());
	show("repeat0", "ab".repeat(0));
	show("repeat3", "ab".repeat(3));

	show("slice", s.slice(7, 12));
	show("sliceHead", s.slice(0, 5));
	show("sliceEmpty", s.slice(3, 3));
	show("substring", s.substring(1, 4));

	show("charAt0", s.charAt(0));
	show("charAtLast", s.charAt(11));
	show("index1", s[1]);
	showN("code0", s.charCodeAt(0));
	showN("codeSpace", s.charCodeAt(6));

	showB("eq", "abc" === "abc");
	showB("ne", "abc" === "abd");
	showB("lt", "apple" < "banana");
	showB("gt", "banana" > "apple");
	showB("le", "abc" <= "abc");
	showB("ge", "abc" >= "abc");
	showB("ltPrefix", "ab" < "abc");
	showB("eqIgnoreCase", "AbC".equalsIgnoreCase("aBc"));
	showB("eqIgnoreCaseNo", "AbC".equalsIgnoreCase("aBd"));

	let acc = "";
	for (let i = 0; i < 5; i = i + 1) { acc = acc + i.toString() + ";"; }
	show("loopBuild", acc);
}
main();
