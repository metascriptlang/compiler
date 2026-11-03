// Parity program — a bigint held by a union keeps its own runtime kind: `typeof` tells it apart
// from a string carrying the same digits, from a number and from a struct arm, in a local, a
// call result, an array element and a Map value, on every backend.
//
// @stdout: bigint 6 | string 5
// @stdout: number 2.5 | bigint 1180591620717411303423
// @stdout: object -7 | bigint 9 | string 9
// @stdout: B2,Sa,B-73786976294838206464,S0
// @stdout: big=B200000000000000000000 text=S10
// @exit: 0

interface Wrap {
	v: bigint;
}

function textOrBig(i: int32): string | bigint {
	if (i == 0) return 5n;
	return "5";
}

function numberOrBig(i: int32): number | bigint {
	if (i == 0) return 2.5;
	return 2n ** 70n;
}

function show(u: Wrap | bigint | string): string {
	if (typeof u === "bigint") return "bigint " + (u + 1n).toString();
	if (typeof u === "string") return "string " + u;
	return "object " + u.v.toString();
}

function describe(x: bigint | string): string {
	return typeof x === "bigint" ? "B" + (x * 2n).toString() : "S" + x;
}

const texts: string[] = [];
for (let i = 0; i < 2; i++) {
	const u = textOrBig(i);
	texts.push(typeof u === "bigint" ? "bigint " + (u + 1n).toString() : "string " + u);
}
console.log(texts.join(" | "));

const numbers: string[] = [];
for (let i = 0; i < 2; i++) {
	const x = numberOrBig(i);
	numbers.push(typeof x === "bigint" ? "bigint " + (x - 1n).toString() : "number " + x.toString());
}
console.log(numbers.join(" | "));

console.log(show({ v: -7n }), "|", show(8n), "|", show("9"));

const mixed: (bigint | string)[] = [1n, "a", -(2n ** 65n), "0"];
const described: string[] = [];
for (const x of mixed) described.push(describe(x));
console.log(described.join(","));

const held = new Map<string, string | bigint>();
held.set("big", 10n ** 20n);
held.set("text", "10");
const big = held.get("big")!;
const text = held.get("text")!;
console.log("big=" + describe(big), "text=" + (typeof text === "bigint" ? "B" + text.toString() : "S" + text));
