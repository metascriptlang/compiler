// Parity program — two different property names never share one spelling on C, neither as members of
// one object nor inside the names of the anonymous types and generic instances built from them.
// Before, "é" and "è" both became the member `XX_`, "a-b" became `aminusb_` (the spelling of the key
// "aminusb_"), the keyword escape of `int` was the key `int_0`, `$x` was the key `dollarx_`, two
// one-key literals over "é" and "è" froze as one C struct, and `JSON.parse<T>` / `Set<T>` over
// `{ "data-probe": string }` named the instance `Result__ref___anon1__data-probes_string`, invalid C.
// Sibling of nonIdentifierPropertyNames (JS quoting of the same keys).
//
// @stdout: {"é":1,"è":2} é|è 1|2
// @stdout: {"a-b":3,"aminusb_":4} a-b|aminusb_ 3|4
// @stdout: {"int":5,"int_0":6,"$x":7,"dollarx_":8} int|int_0|$x|dollarx_ 5|6|7|8
// @stdout: {"é":"acute"} {"è":"grave"}
// @stdout: {"data-probe":"parsed"}
// @stdout: {"q\"b\\s":"parsed","a b":"space"}
// @stdout: 1 2
// @stdout: 1 2

function show<T>(value: T, keys: string[], values: string[]): string {
	return JSON.stringify(value) + " " + keys.join("|") + " " + values.join("|");
}

const accents = { "é": 1, "è": 2 };
console.log(show(accents, Object.keys(accents), Object.values(accents).map((v) => v.toString())));
const dashed = { "a-b": 3, "aminusb_": 4 };
console.log(show(dashed, Object.keys(dashed), Object.values(dashed).map((v) => v.toString())));
const escapes = { int: 5, int_0: 6, $x: 7, dollarx_: 8 };
console.log(show(escapes, Object.keys(escapes), Object.values(escapes).map((v) => v.toString())));

const acute = { "é": "acute" };
const grave = { "è": "grave" };
console.log(JSON.stringify(acute) + " " + JSON.stringify(grave));

function decode<T>(seed: T, text: string): string {
	const back = JSON.parse<T>(text);
	return back.ok ? JSON.stringify(back.value) : "parse failed: " + back.error;
}
const probe = { "data-probe": "seed" };
console.log(decode(probe, "{\"data-probe\":\"parsed\"}"));
const quoted = { "q\"b\\s": "seed", "a b": "space" };
console.log(decode(quoted, "{\"q\\\"b\\\\s\":\"parsed\",\"a b\":\"space\"}"));

function distinct<T>(a: T, b: T): string {
	const seen = new Set<T>();
	seen.add(a);
	seen.add(b);
	return seen.size.toString();
}
console.log(distinct(probe, probe) + " " + distinct(probe, { ...probe, "data-probe": "other" }));
console.log(distinct(quoted, quoted) + " " + distinct(quoted, { ...quoted, "a b": "other" }));
