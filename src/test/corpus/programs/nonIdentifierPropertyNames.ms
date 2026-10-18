// Parity program — an object key that is not an identifier keeps its spelling on every backend:
// the JS emitter quotes it in a literal and brackets it in a member read, the C backend mangles it.
// Before, JS printed `{ data-probe: "counter" }` and the macro-built read `value.data-probe`,
// which node refused as a SyntaxError.
//
// @stdout: {"data-probe":"counter","aria-label":"increment","q\"b\\s":"quote","42":"num","plain":"bare"}
// @stdout: {"data-probe":"counter","aria-label":"increment","q\"b\\s":"quote","42":"num","plain":"bare","extra":"more"}
// @stdout: keys data-probe|aria-label|q"b\s|42|plain
// @stdout: values counter|increment|quote|num|bare

const attrs = { "data-probe": "counter", "aria-label": "increment", "q\"b\\s": "quote", "42": "num", plain: "bare" };
console.log(JSON.stringify(attrs));
console.log("keys " + Object.keys(attrs).join("|"));
console.log("values " + Object.values(attrs).join("|"));

const merged = { ...attrs, extra: "more" };
console.log(JSON.stringify(merged));

function encode<T>(value: T): string {
	return JSON.stringify(value);
}
const copy = attrs;
console.log(encode(copy));
console.log(encode({ "data-probe": "inline", "a b": "space" }));
