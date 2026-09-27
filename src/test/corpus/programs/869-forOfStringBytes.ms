// @stdout: bytes 11 empty 0 codes 97,98,99, field 5 concat 4 skip 2 typed 3
// @xfail(raiser): the Raiser VM runs for-of itself and rejects a string iterable ('expected an array, got value kind String')
// note: for-of over a string yields each UTF-8 byte as a char, as Nim's items does for string. The lowering used to read UTF-16 units as one-character strings into the char binding, which did not compile on C and split a surrogate pair on JS.

class Named { name: string; constructor(n: string) { this.name = n; } }

function count(s: string): int32 {
	let n: int32 = 0;
	for (const ch of s) { n = n + 1; }
	return n;
}

function codes(s: string): string {
	let out = "";
	for (const ch of s) { out = out + String(ch as int32) + ","; }
	return out;
}

function fieldBytes(o: Named): int32 {
	let n: int32 = 0;
	for (const ch of o.name) { n = n + 1; }
	return n;
}

function concatBytes(a: string, b: string): int32 {
	let n: int32 = 0;
	for (const ch of a + b) { n = n + 1; }
	return n;
}

function skipVowels(s: string): int32 {
	let n: int32 = 0;
	for (const ch of s) {
		if (ch == 97 as char || ch == 101 as char) continue;
		n = n + 1;
	}
	return n;
}

function typedBinding(s: string): int32 {
	let n: int32 = 0;
	for (const ch of s) {
		const c: char = ch;
		if (c != 0 as char) n = n + 1;
	}
	return n;
}

console.log(`bytes ${count("héllo\u{1F600}!")} empty ${count("")} codes ${codes("abc")} field ${fieldBytes(new Named("abéc"))} concat ${concatBytes("a", "éb")} skip ${skipVowels("bead")} typed ${typedBinding("xyz")}`);
