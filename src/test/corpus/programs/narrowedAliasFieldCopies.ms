// @stdout: bxxxxxxxxxxxxxxxxxxxxxxx/bxxxxxxxxxxxxxxxxxxxxxxx|hixxxxxxxxxxxxxxxxxxxxxxx/hixxxxxxxxxxxxxxxxxxxxxxx
// note: a field read through a binding made from a narrowed Result variant is a copy, because the binding owns nothing: the Result keeps its heap string after the field is read out. Covered for the error arm and the value arm, with strings built at runtime
struct Key {
	b: uint8;
}

function build(tail: string): string {
	return ["x", tail, "xxxxxxxxxxxxxxxxxxxxxx"].join("");
}

function failing(text: string): Result<Key, string> {
	return Result.err("b" + text);
}

function wording(text: string): Result<string, int32> {
	return Result.ok("hi" + text);
}

const bad = failing(build(""));
const good = wording(build(""));
let e = "";
let v = "";
if (!bad.ok) {
	const h = bad;
	e = h.error;
}
if (good.ok) {
	const g = good;
	v = g.value;
}
console.log(`${e}/${bad.ok ? "" : bad.error}|${v}/${good.ok ? good.value : ""}`);
