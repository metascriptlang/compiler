// @stdout: 0|7|n:5|s:ab|3
// @stdout: top:7

class V {
	n: int32 = 0;
	size(): int32 { return this.n; }
}

function seven(): int32 { return 7; }

async function inside(): Promise<void> {
	const a = new V();
	const size = await a.size();
	const f = await seven();
	const n: int32 = 5;
	const m = await n;
	const s = "ab";
	const t = await s;
	const g = await (async (): Promise<int32> => 3)();
	console.log(`${String(size)}|${String(f)}|n:${String(m)}|s:${t}|${String(g)}`);
}

await inside();

const top = await seven();
console.log(`top:${String(top)}`);
