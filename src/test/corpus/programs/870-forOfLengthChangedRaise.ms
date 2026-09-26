// @exit: 1
// @stdout: the length of the array changed while iterating over it
// @xfail(raiser): the Raiser VM runs for-of itself and rejects a string iterable ('expected an array, got value kind String')
// note: an uncaught length change of a for-of array ends the program with Nim's items message; a string that grows while iterated raises too, as Nim's items does for string. The loop used to read past the end or skip what was added.

function grownString(): string {
	let s = "abc";
	let seen = "";
	try {
		for (const ch of s) { seen = seen + String(ch as int32) + ","; s = s + "d"; }
	} catch (e) {
		return "string raised after " + seen;
	}
	return "string finished " + seen;
}

function sameLengthString(): string {
	let s = "abc";
	let seen = "";
	try {
		for (const ch of s) { seen = seen + String(ch as int32) + ","; s = "xyz"; }
	} catch (e) {
		return "same-length string raised after " + seen;
	}
	return "same-length string finished " + seen;
}

console.log(grownString() + " | " + sameLengthString());

const names: string[] = ["a", "b", "c"];
let visited = 0;
for (const n of names) {
	visited += 1;
	if (n == "b") names.pop();
}
console.log("not reached " + String(visited));
