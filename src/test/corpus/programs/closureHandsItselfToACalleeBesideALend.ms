// @stdout: total 8
// note: a closure that hands itself to a callee, in a function called beside a lend. The scan that asks whether a handed-over function leaves code running used to enter that closure's body again at its own hand-over, without end, and `msc check` crashed (exit 139 on bac1b95e1948).

function walkAll(xs: int32[], f: (x: int32) => void): void { for (const x of xs) { f(x); } }

function deep(xs: int32[]): int32 {
	let n: int32 = 0;
	const visit = (x: int32): void => {
		n += x;
		if (x > 0) walkAll([x - 1], visit);
	};
	walkAll(xs, visit);
	return n;
}

async function main(): Promise<void> {
	const xs: int32[] = [1, 2];
	const t = spawn(() => xs.length);
	const d = deep([3]);
	console.log(`total ${d + await t}`);
}

await main();
