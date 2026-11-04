const MIN_ROUND_MS = 250.0;
const ROUNDS = 3;

function round(op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = (elapsed < 1.0 ? calls * 16.0 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed))) as int32;
	}
}

async function roundAsync(op: () => Promise<void>): Promise<number> {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) await op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = (elapsed < 1.0 ? calls * 16.0 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed))) as int32;
	}
}

function pad(text: string, width: number): string {
	let out = text;
	while (out.length < width) out = out + " ";
	return out;
}

function fixed(value: number, digits: number): string {
	const scale = Math.pow(10, digits);
	return (Math.round(value * scale) / scale).toString();
}

function report(name: string, perCallBytes: number, msPerCall: number[]): void {
	const rates: number[] = [];
	for (const ms of msPerCall) rates.push(perCallBytes > 0 ? perCallBytes / ms / 1000.0 : ms * 1000.0);
	rates.sort((a, b) => a - b);
	const median = rates[1];
	const spread = (rates[2] - rates[0]) / median * 100.0;
	const unit = perCallBytes > 0 ? "MB/s" : "us/op";
	console.log(pad(name, 28) + pad(fixed(median, 3) + " " + unit, 18) + "spread " + fixed(spread, 1) + "%");
}

export function bench(name: string, perCallBytes: number, op: () => void): void {
	const times: number[] = [];
	for (let r = 0; r < ROUNDS; r++) times.push(round(op));
	report(name, perCallBytes, times);
}

export async function benchAsync(name: string, perCallBytes: number, op: () => Promise<void>): Promise<void> {
	const times: number[] = [];
	for (let r = 0; r < ROUNDS; r++) times.push(await roundAsync(op));
	report(name, perCallBytes, times);
}
