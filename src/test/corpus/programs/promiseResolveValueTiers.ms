// @stdout: text a text long enough to own a heap payload 1
// @stdout: kept a text long enough to own a heap payload 2 same
// @stdout: pair 3 pair-3 pair-3
// @stdout: returned pair-3 pair-3
// @stdout: list 3 4 6
// @stdout: counter 11 12 13
// @stdout: done
// note: Promise.resolve(value) owns a value of every storage tier, as an async function's result
// does: a string built at run time (fresh, and a local the caller keeps), a struct with a heap
// field, an array and a closure; an async function that returns its struct parameter leaves the
// caller's struct intact too. Before, C passed the value into the future without its count: the
// string and the struct did not compile, the array was read after free, and boxing a struct or a
// closure moved it out of a value its owner still held.

struct Pair { n: int32; tag: string; }
type Count = () => int32;

function counter(start: int32): Count {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}

async function passOn(p: Pair): Promise<Pair> {
	return p;
}

function text(n: int32): string {
	return "a text long enough to own a heap payload " + n.toString();
}

async function readTiers(): Promise<void> {
	const t = await Promise.resolve(text(1));
	console.log(`text ${t}`);

	const kept = text(2);
	const k = await Promise.resolve(kept);
	console.log(`kept ${k} ${k == kept ? "same" : "differs"}`);

	const pair: Pair = { n: 3, tag: "pair-" + (3).toString() };
	const p = await Promise.resolve(pair);
	console.log(`pair ${p.n} ${p.tag} ${pair.tag}`);
	const back = await passOn(pair);
	console.log(`returned ${back.tag} ${pair.tag}`);

	const xs = await Promise.resolve([4, 5, 6]);
	console.log(`list ${xs.length} ${xs[0]} ${xs[2]}`);

	const step = counter(10);
	const f = await Promise.resolve(step);
	console.log(`counter ${f()} ${step()} ${f()}`);
}

await readTiers();
console.log("done");
