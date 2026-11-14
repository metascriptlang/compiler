// @stdout: invariant: 4
// @stdout: moved index: 104 101 108
// @stdout: moved receiver: 97 99
// @stdout: empty: 0
// note: a string read whose receiver and index a loop never writes gives each iteration the same value; one whose index or receiver the loop writes reads the new one; a loop that runs no iteration reads nothing.
const LETTERS: Readonly<string[]> = ["h", "e", "l", "x"];

function matchesAt(text: string, i: int32): int32 {
	let hits: int32 = 0;
	for (const w of LETTERS) {
		if (text.charCodeAt(i) == w.charCodeAt(0)) hits += 1;
	}
	return hits;
}

const word = "hello";
let total: int32 = 0;
for (let i: int32 = 0; i < word.length; i += 1) total += matchesAt(word, i);
console.log(`invariant: ${total}`);

let at: int32 = 0;
let codes = "";
while (at < 3) {
	codes = codes + " " + word.charCodeAt(at).toString();
	at += 1;
}
console.log(`moved index:${codes}`);

let t = "ab";
let firsts = "";
for (let k: int32 = 0; k < 2; k += 1) {
	firsts = firsts + " " + t.charCodeAt(0).toString();
	t = "cd";
}
console.log(`moved receiver:${firsts}`);

const none: string[] = [];
let seen: int32 = 0;
for (const w of none) {
	if (word.charCodeAt(99) == w.charCodeAt(0)) seen += 1;
}
console.log(`empty: ${seen}`);
