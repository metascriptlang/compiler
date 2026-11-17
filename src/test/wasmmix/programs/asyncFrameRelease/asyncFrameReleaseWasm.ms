class Probe {
	tag: string;
	constructor(tag: string) { this.tag = tag; }
}
function onDestroy(this p: Probe): void { console.log(`destroyed ${p.tag}`); }

function sleep(ms: int32): Promise<void> {
	return new Promise((resolve) => { setTimeout(() => resolve(), ms); });
}

@wasm
export async function holds(n: int32): Promise<int32> {
	const p = new Probe(`p${n}`);
	await sleep(1);
	return n + p.tag.length;
}

@wasm
export async function quick(n: int32): Promise<int32> {
	const p = new Probe(`q${n}`);
	return n + p.tag.length;
}
