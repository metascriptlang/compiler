let ticks: int32 = 0;
let ticker: number = 0;

@wasm
export function schedule(x: int32): int32 {
	setTimeout(() => {
		console.log(`timer ${x}`);
	}, 20);
	setTimeout(() => {
		console.log(`soon ${x}`);
	}, 0);
	ticker = setInterval(() => {
		ticks += 1;
		console.log(`tick ${ticks}`);
		if (ticks == 3) clearInterval(ticker);
	}, 1);
	Promise.resolve(x).then((v) => {
		console.log(`then ${v}`);
	});
	return x + 1;
}
