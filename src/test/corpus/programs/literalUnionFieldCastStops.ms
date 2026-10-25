// @exit: 1
// @stdout: ok relative
// @stdout: none null
// @stdout: invalid union conversion: "fixed" is not Narrow
// @xfail(danger): --danger drops the conversion check, so the field keeps a value outside Narrow instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid union conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output; src/codegen/raiser/eval.ms pins it
// note: a struct field cast field-wise from a wider string-literal union into a narrower one is checked like a local: "fixed" stops instead of landing in a Narrow field.

type Wide = "static" | "relative" | "absolute" | "fixed";
type Narrow = "static" | "relative" | "absolute";
type WideStyle = { position: Wide | null };
type NarrowStyle = { position: Narrow | null };

function read(p: Wide | null): WideStyle { return { position: p }; }
function conv(s: WideStyle): NarrowStyle { return { position: s.position as Narrow | null }; }

function main(): void {
	console.log("ok", conv(read("relative")).position);
	console.log("none", conv(read(null)).position);
	console.log("bad", conv(read("fixed")).position);
	console.log("unreachable");
}

main();
