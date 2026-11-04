const MIN_ROUND_MS = 250.0;
const ROUNDS = 3;

function nextCalls(calls, elapsed) {
	return elapsed < 1.0 ? calls * 16 : Math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed));
}

function round(op) {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = nextCalls(calls, elapsed);
	}
}

async function roundAsync(op) {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) await op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return elapsed / calls;
		calls = nextCalls(calls, elapsed);
	}
}

function fixed(value, digits) {
	const scale = Math.pow(10, digits);
	return (Math.round(value * scale) / scale).toString();
}

function report(name, perCallBytes, msPerCall) {
	const rates = msPerCall.map((ms) => (perCallBytes > 0 ? perCallBytes / ms / 1000.0 : ms * 1000.0));
	rates.sort((a, b) => a - b);
	const median = rates[1];
	const spread = (rates[2] - rates[0]) / median * 100.0;
	const unit = perCallBytes > 0 ? "MB/s" : "us/op";
	console.log(name.padEnd(28) + (fixed(median, 3) + " " + unit).padEnd(18) + "spread " + fixed(spread, 1) + "%");
}

export function bench(name, perCallBytes, op) {
	const times = [];
	for (let r = 0; r < ROUNDS; r++) times.push(round(op));
	report(name, perCallBytes, times);
}

export async function benchAsync(name, perCallBytes, op) {
	const times = [];
	for (let r = 0; r < ROUNDS; r++) times.push(await roundAsync(op));
	report(name, perCallBytes, times);
}
