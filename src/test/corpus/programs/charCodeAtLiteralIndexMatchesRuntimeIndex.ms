// @stdout: hey: 104 101 121
// @stdout: same in range: true true true
// @stdout: same outside: true true
// @stdout: first letters: 104 119 97
// note: charCodeAt at a literal index reads what it reads at the same index held in a variable, inside the string and past either end.
function at(s: string, i: int32): int32 {
	return s.charCodeAt(i);
}

const word = "hey";
console.log(`hey: ${word.charCodeAt(0)} ${word.charCodeAt(1)} ${word.charCodeAt(2)}`);
console.log(`same in range: ${word.charCodeAt(0) == at(word, 0)} ${word.charCodeAt(1) == at(word, 1)} ${word.charCodeAt(2) == at(word, 2)}`);
console.log(`same outside: ${word.charCodeAt(7) == at(word, 7)} ${"".charCodeAt(0) == at("", 0)}`);

const words: string[] = ["hi", "wow", "a"];
let firsts = "";
for (const w of words) firsts = firsts + " " + w.charCodeAt(0).toString();
console.log(`first letters:${firsts}`);
