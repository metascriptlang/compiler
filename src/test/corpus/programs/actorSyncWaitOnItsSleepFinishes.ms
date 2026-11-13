// @skip-js: the JS backend has no blocking wait, so an await in a function that is not async is refused there
// @stdout: nap 12 doze 3
// note: a plain function an actor method calls blocks on a sleep the visit armed. The sleep settles as the
// actor's job, which cannot run while the visit waits, so the thread that fires the timer marks the future
// finished and the wait ends on that mark (ULTRALOCK A4, S2).

function pause(ms: int32): int32 {
	await sleepAsync(ms);
	return ms;
}

actor Sleeper {
	nap(): int32 { return pause(5) + pause(7); }
	doze(): int32 {
		await sleepAsync(3);
		return 3;
	}
}

async function main(): Promise<void> {
	const s = new Sleeper();
	console.log(`nap ${await s.nap()} doze ${await s.doze()}`);
}
await main();
