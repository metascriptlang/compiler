// @stdout: 1 ok|2 two|3 three|4 four
// @exit: 0
// note: an arrow whose expression body is a parenthesized object literal under a type assertion keeps it an object expression once the assertion is erased: the cast outside the parentheses, the cast inside a second pair, a declared return type with the cast inside, and an arrow passed as a callback.

struct Pair {
	n: int32;
	tag: string;
}

const outside = (e: string) => ({ n: 1, tag: e }) as Pair;
const nested = (e: string) => (({ n: 2, tag: e }) as Pair);
const declared = (e: string): Pair => ({ n: 3, tag: e } as Pair);

function apply(f: (e: string) => Pair, e: string): Pair {
	return f(e);
}

const a = outside("ok");
const b = nested("two");
const c = declared("three");
const d = apply((e: string) => ({ n: 4, tag: e }) as Pair, "four");
console.log(`${a.n} ${a.tag}|${b.n} ${b.tag}|${c.n} ${c.tag}|${d.n} ${d.tag}`);
