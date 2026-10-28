// @stdout: fresh 4|made 5|kept 6 6|unawaited|text t7 t7|struct 8
// @exit: 0

class Plain { n: int32 = 4; }
struct Pair { a: int32; b: string; }

function made(n: int32): Plain {
	const p = new Plain();
	p.n = n;
	return p;
}

function unawaited(): void {
	const p = Promise.resolve(new Plain());
}

async function main(): Promise<void> {
	const out: string[] = [];
	const fresh = await Promise.resolve(new Plain());
	out.push(`fresh ${fresh.n}`);
	const m = await Promise.resolve(made(5));
	out.push(`made ${m.n}`);
	const kept = made(6);
	const same = await Promise.resolve(kept);
	out.push(`kept ${same.n} ${kept.n}`);
	unawaited();
	out.push("unawaited");
	const t = `t${7}`;
	const text = await Promise.resolve(t);
	out.push(`text ${text} ${t}`);
	const pair = await Promise.resolve({ a: 8, b: "x" } as Pair);
	out.push(`struct ${pair.a}`);
	console.log(out.join("|"));
}

main();
