export struct Label { text: string; count: int32; }

function sleep(ms: int32): Promise<void> {
	return new Promise((resolve) => {
		setTimeout(() => resolve(), ms);
	});
}

@wasm
export async function doubled(x: int32): Promise<int32> {
	await sleep(2);
	return x * 2;
}

@wasm
export async function ready(x: int32): Promise<int32> {
	return x + 1;
}

@wasm
export async function greeting(name: string): Promise<string> {
	await sleep(1);
	return `hello ${name}`;
}

@wasm
export async function labelled(n: int32): Promise<Label> {
	await sleep(1);
	return { text: `n=${n}`, count: n };
}

@wasm
export async function maybe(n: int32): Promise<int32 | null> {
	await sleep(1);
	return n > 0 ? n : null;
}

@wasm
export async function series(n: int32): Promise<Vec<float64>> {
	await sleep(1);
	let out: Vec<float64> = [];
	for (let i = 0; i < n; i += 1) out.push(i * 0.5);
	return out;
}

@wasm
export async function failing(n: int32): Promise<int32> {
	await sleep(1);
	if (n > 0) throw new Error(`bad ${n}`);
	return n;
}

@wasm
export async function nothing(n: int32): Promise<void> {
	await sleep(1);
	console.log(`nothing ran ${n}`);
}

@wasm
export async function reporting(n: int32, report: (v: int32) => void): Promise<int32> {
	await sleep(1);
	report(n);
	return n + 100;
}
