// @stdout: s s 3 | n 4 | str 3x | flat 6 6 | pair 5 p5 | after done
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: then picks its overload from what the callback returns, whatever the destination: a
// plain value gives Promise<U> (annotated as Promise<string> or not), a Promise gives the
// promise it returns (annotated as Promise<number> or not), and an unannotated arrow with an
// inferred parameter works in both shapes.

struct Pair { n: int32; tag: string; }

async function load(n: int32): Promise<int32> { await sleepAsync(1); return n + 1; }

async function run(): Promise<void> {
	const p: Promise<int32> = load(2);
	const t: Promise<string> = p.then((x) => "s");
	const u = p.then((x) => "s");
	const lifted: Promise<int32> = p.then((x) => x + 1);
	let out = `${await t} ${await u} ${await p}`;
	out += ` | n ${await lifted}`;
	const text: Promise<string> = p.then((x: int32): string => x.toString() + "x").then((s: string) => s.slice(0, 1) + "x");
	out += ` | str ${(await text).slice(0, 2)}`;
	const flat: Promise<int32> = p.then((x) => load(x + 2));
	const flatBare = p.then((x) => load(x + 2));
	out += ` | flat ${await flat} ${await flatBare}`;
	const pair: Promise<Pair> = p.then((x: int32): Pair => ({ n: x + 2, tag: "p" + (x + 2).toString() }));
	const pr = await pair;
	out += ` | pair ${pr.n} ${pr.tag}`;
	console.log(out + " | after done");
}

await run();
