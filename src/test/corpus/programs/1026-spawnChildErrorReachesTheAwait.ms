// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @xfail(raiser): a failed spawn future re-raises as a string on Raiser (inbox 2026-09-19-raiser-failed-future-rethrows-string)
// @serial
// @stdout: thrown boom|runtime the length of the array changed while iterating over it|built 7|pair second|timed second|apair second|many 200
// note: an error raised in a spawn child must reach the await that joins it, on every
//   join path. Before the fix the fused sync await (msAwaitSlotResult) set the error flag
//   without the exception object, so a thrown Error reached the parent's catch as null
//   and a failed runtime check reached nothing; and the AwaitGroup joins (Promise.all of
//   spawns, a spawn with a timeout, sync or async) never looked at the failure at all:
//   `pair 1`, `timed 0`, `apair 1`. `many` re-raises 200 times through one slot pool.

function boom(): int32 { throw new Error("boom"); }
function second(): int32 { throw new Error("second"); }

function thrown(): string {
	try { return `${await spawn(() => boom())}`; } catch (e) { return "thrown " + e.message; }
}

function runtimeCheck(): string {
	try {
		return `${await spawn((): int32 => {
			const ys: int32[] = [1, 2, 3];
			let s: int32 = 0;
			for (const y of ys) { s += y; if (ys.length < 10) ys.push(1); }
			return s;
		})}`;
	} catch (e) {
		return "runtime " + e.message;
	}
}

class Box { n: int32 = 0; }

function built(): string {
	return `built ${await spawn((): int32 => { const b = new Box(); b.n = 7; return b.n; })}`;
}

function pair(): string {
	try {
		const rs = await Promise.all([spawn((): int32 => 1), spawn(() => second())]);
		return `pair ${rs[0]}`;
	} catch (e) {
		return "pair " + e.message;
	}
}

function timed(): string {
	try { return `timed ${await spawn(() => second(), { timeout: 4000 })}`; } catch (e) { return "timed " + e.message; }
}

async function asyncPair(): Promise<string> {
	try {
		const rs = await Promise.all([spawn((): int32 => 1), spawn(() => second())]);
		return `apair ${rs[0]}`;
	} catch (e) {
		return "apair " + e.message;
	}
}

function many(): int32 {
	let caught: int32 = 0;
	for (let i = 0; i < 200; i += 1) {
		try { await spawn(() => boom()); } catch (e) { caught += 1; }
	}
	return caught;
}

console.log(`${thrown()}|${runtimeCheck()}|${built()}|${pair()}|${timed()}|${await asyncPair()}|many ${many()}`);
