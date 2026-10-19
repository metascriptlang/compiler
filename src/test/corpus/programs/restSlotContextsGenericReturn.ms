// @stdout: rest x K1 K2 x,z 1
// @stdout: x
// @stdout: on
// @stdout: 1
// @stdout: tb u2
// note: a generic call whose type parameter only an unannotated callback's return binds, written as an argument of a rest parameter, takes the element type of the rest as its context and still infers from the callback: `console.log(w(() => "x"))` is `w<string>`. An `unknown` element gives no context, so a conditional of value types still prints through `console.log` and a conditional of objects still fits an `unknown` rest. Before, the first rest argument was checked against the rest type itself and the call was refused. Same output on every backend.
function w<R>(f: () => R): R { return f(); }
class K { k: int32 = 1; }
function count(...xs: K[]): string { return "K" + xs.length.toString(); }
function joined(...xs: string[]): string { return xs.join(","); }
console.log("rest " + w(() => "x") + " " + count(w(() => new K())) + " " + count(w(() => new K()), new K())
	+ " " + joined(w(() => "x"), "z") + " " + w(() => 1).toString());
console.log(w(() => "x"));
const on = w(() => true);
console.log(on ? "on" : "off");
console.log(on ? 1 : 2);
function tags(...xs: unknown[]): string { return "u" + xs.length.toString(); }
console.log(`t${on ? "b" : "c"} ` + tags(on ? new K() : new K(), new K()));
