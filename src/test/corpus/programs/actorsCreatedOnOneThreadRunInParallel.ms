// @stdout: two actors: parallel
// @stdout: one actor twice: serial
// @stdout: two actors made inside a third: parallel
// @exit: 0
// @serial
// @skip-js: the JS backend runs actors on one thread
// note: two CPU-bound actors created on the main thread run side by side because a queued actor wakes an idle worker that steals it (old: serial, pair time about twice the single time); one actor still runs its messages one at a time (A2). Each time is the best of seven runs and a class holds if one of three attempts shows it, so a burst of load on the host does not turn a class

actor Burner {
	burn(rounds: int64): uint64 {
		let x: uint64 = 1;
		for (let i: int64 = 0; i < rounds; i++) { x = x ^ (x << 13); x = x ^ (x >> 7); x = x ^ (x << 17); }
		return x;
	}
}

actor Spawner {
	pairTime(rounds: int64): number {
		const a = new Burner();
		const b = new Burner();
		const start = performance.now();
		await Promise.all([a.burn(rounds), b.burn(rounds)]);
		return performance.now() - start;
	}
}

const ROUNDS: int64 = 60000000;
const RUNS = 7;
const one = new Burner();
const two = new Burner();
const outer = new Spawner();
await Promise.all([one.burn(1000), two.burn(1000)]);

function aloneTime(): number {
	const start = performance.now();
	await one.burn(ROUNDS);
	return performance.now() - start;
}

function pairTime(): number {
	const start = performance.now();
	await Promise.all([one.burn(ROUNDS), two.burn(ROUNDS)]);
	return performance.now() - start;
}

function sameTime(): number {
	const start = performance.now();
	await Promise.all([one.burn(ROUNDS), one.burn(ROUNDS)]);
	return performance.now() - start;
}

function nestedTime(): number {
	return await outer.pairTime(ROUNDS);
}

function best(run: () => number): number {
	let low = run();
	for (let i = 1; i < RUNS; i++) {
		const t = run();
		if (t < low) low = t;
	}
	return low;
}

function holds(measure: () => number, wantParallel: boolean): boolean {
	for (let attempt = 0; attempt < 3; attempt++) {
		const single = best(aloneTime);
		const t = best(measure);
		if (wantParallel ? t < single * 1.5 : t > single * 1.5) return true;
	}
	return false;
}

console.log(`two actors: ${holds(pairTime, true) ? "parallel" : "serial"}`);
console.log(`one actor twice: ${holds(sameTime, false) ? "serial" : "parallel"}`);
console.log(`two actors made inside a third: ${holds(nestedTime, true) ? "parallel" : "serial"}`);
