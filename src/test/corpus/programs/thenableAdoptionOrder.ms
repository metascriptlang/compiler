// @stdout: A start|A after call|then 1|A 1|B start|B after resolve|then 2|B 2|E start|E after all|then 5|then 6|E 5,6
// @xfail(raiser): the Raiser has no job queue and calls `then` inside the adopting call (NIM-REF RT-39 Open: it resumes awaits eagerly), and has no host function for msPromiseAll
// @exit: 0
// note: an async function's return, `Promise.resolve` and `Promise.all` call a thenable's `then` from a queued job, after the caller's next statement, as `await` does.

const out: string[] = [];

class Now {
	v: int32;
	constructor(v: int32) { this.v = v; }
	then(onFulfilled: (v: int32) => void): void {
		out.push(`then ${this.v}`);
		onFulfilled(this.v);
	}
}

async function ret(): Promise<int32> { return new Now(1); }

async function main(): Promise<void> {
	out.push("A start");
	const p = ret();
	out.push("A after call");
	out.push(`A ${await p}`);
	out.push("B start");
	const q = Promise.resolve(new Now(2));
	out.push("B after resolve");
	out.push(`B ${await q}`);
	out.push("E start");
	const t = Promise.all([new Now(5), new Now(6)]);
	out.push("E after all");
	const xs = await t;
	out.push(`E ${xs[0]},${xs[1]}`);
	console.log(out.join("|"));
}

main();
