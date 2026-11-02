// @stdout: b once
// @stdout: tick 1
// @stdout: tick 2
// @stdout: timeout
// note: an interval's next run is due one period after the run started, not after its callback returned, so a slow first tick still runs the second before a timeout its callback set for a little later; an interval cleared inside its own callback never runs again.

let ticks = 0;
let a: number = 0;
let b: number = 0;

function busy(ms: number): void {
	const end = performance.now() + ms;
	while (performance.now() < end) {}
}

a = setInterval((): void => {
	ticks += 1;
	console.log(`tick ${ticks}`);
	if (ticks == 1) {
		setTimeout((): void => { console.log("timeout"); }, 15);
		busy(30);
	}
	if (ticks == 2) clearInterval(a);
}, 10);
b = setInterval((): void => {
	console.log("b once");
	clearInterval(b);
}, 5);
