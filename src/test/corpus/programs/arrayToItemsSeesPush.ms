// @skip-js: the JS prelude declares no toItems on arrays
// toItems reads the live array, so a push during iteration is visited.
// @stdout: ok
let nums: int32[] = [1, 2];
let t = "";
let grown = false;
for (const x of nums.toItems()) {
	t += `${x},`;
	if (!grown) {
		grown = true;
		nums.push(3);
	}
}
t += "|";
let words: string[] = ["a", "b"];
let more = false;
for (const w of words.toItems()) {
	t += w;
	if (!more) {
		more = true;
		words.push("c");
	}
}
const expected = "1,2,3,|abc";
if (t != expected) throw new Error(`toItems trace differs:\n${t}\n${expected}`);
console.log("ok");
