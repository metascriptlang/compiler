// @stdout: <b 97 98> | <b 97 98> | <b 97 98> | x=<b 97 98> | y<b 97 98> | 97,98
// note: a toString declared for a brand over an array turns that brand into text in a template, String(),
// concatenation and `+=`, while a plain `uint8[]` keeps printing its elements.
type Bytes = uint8[] & { __brand: "Bytes" };

function toString(this b: Bytes): string {
	let out = "<b";
	for (const x of b) out += " " + x.toString();
	return out + ">";
}

const raw: uint8[] = [97, 98];
const b = raw as Bytes;
let acc = "x=";
acc += b;
console.log(`${b} | ${String(b)} | ${b.toString()} | ${acc} | ${"y" + b} | ${raw}`);
