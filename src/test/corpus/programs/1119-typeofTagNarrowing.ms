// Parity program — `typeof x` names one of the eight tags: each real tag still
// narrows a union, a stored tag matches exhaustively over the eight and prints
// as its text, `switch (typeof x)` picks its case, and a union of string
// literals prints as its text, on every backend.
//
// @stdout: n=4 s=3 b=1 o=2
// @stdout: number string boolean object
// @stdout: sym=0 undef=0
// @stdout: stored=number side=b
// @stdout: number a
// @exit: 0

type Value = int32 | string | boolean | int32[];

function weigh(v: Value): int32 {
	if (typeof v === "number") return v + 1;
	if (typeof v === "string") return v.length;
	if (typeof v !== "boolean") return v.length;
	return v ? 1 : 0;
}

function tagName(v: Value): string {
	const t = typeof v;
	return match (t) {
		"bigint" => "bigint",
		"boolean" => "boolean",
		"function" => "function",
		"number" => "number",
		"object" => "object",
		"string" => "string",
		"symbol" => "symbol",
		"undefined" => "undefined",
	};
}

function oddTags(v: Value): int32 {
	let hits: int32 = 0;
	switch (typeof v) {
		case "symbol": hits += 1; break;
		case "undefined": hits += 1; break;
		default: break;
	}
	return hits;
}

function side(n: int32): "a" | "b" {
	return n > 0 ? "a" : "b";
}

const arr: int32[] = [1, 2];
console.log("n=" + weigh(3) + " s=" + weigh("abc") + " b=" + weigh(true) + " o=" + weigh(arr));
console.log(tagName(3), tagName("x"), tagName(false), tagName(arr));
console.log("sym=" + oddTags(3) + " undef=" + oddTags("x"));
const stored = typeof weigh(1);
console.log("stored=" + stored, "side=" + side(0));
console.log(stored, side(1));
