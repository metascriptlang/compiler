// @stdout: rest x K1 K2 x,z 1
// @stdout: x
// note: a generic call whose type parameter only an unannotated callback's return binds, written as an argument of a rest parameter, takes the element type of the rest as its context and still infers from the callback: `console.log(w(() => "x"))` is `w<string>`. An `unknown` context binds nothing. Before, the first rest argument was checked against the rest type itself and the call was refused. Same output on every backend.
function w<R>(f: () => R): R { return f(); }
class K { k: int32 = 1; }
function count(...xs: K[]): string { return "K" + xs.length.toString(); }
function joined(...xs: string[]): string { return xs.join(","); }
console.log("rest " + w(() => "x") + " " + count(w(() => new K())) + " " + count(w(() => new K()), new K())
	+ " " + joined(w(() => "x"), "z") + " " + w(() => 1).toString());
console.log(w(() => "x"));
