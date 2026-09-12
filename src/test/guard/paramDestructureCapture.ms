// nim-guard: a destructured parameter is bound from the pattern and survives capture on BOTH backends
//
// INVARIANT (parser desugars `({ a, b }: P)` to `const { a, b } = _destr0;` at the top of the
//   body): the bound names carry the fields' declared types, an owned string field copies out of
//   the parameter with its own hooks, a returned closure captures the bound name, and a loop that
//   calls the function per element leaks nothing.
//
// WHAT IT CATCHES: the pattern silently binding nothing (Undefined variable / a stray global),
//   a destructured string field freed with the parameter while a closure still holds it, or the
//   js lane regressing while native passes.
//
// RED MEANS: exit != 0, or GUARD-OK missing on either lane.
//
// GUARD-JS

interface Item { name: string; n: number; }

function greet({ name, n }: Item): () => string { return () => name + "#" + n.toString(); }
const label = ({ name }: Item): string => name.toUpperCase();

function main(): void {
	const items: Item[] = [{ name: "a", n: 1 }, { name: "b", n: 2 }, { name: "c", n: 3 }];
	let out = "";
	for (const it of items) out = out + greet(it)() + label(it);
	if (out == "a#1Ab#2Bc#3C") {
		console.log("GUARD-OK");
	} else {
		console.log("GUARD-FAIL " + out);
	}
}
main();
