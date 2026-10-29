// @stdout: direct spawned
// @stdout: after 5
// @stdout: all spawned again
// @stdout: after 6
// note: a spawned task that throws hands its error to its future once, so a reader that catches it and awaits again leaves nothing behind, read directly or through Promise.all.

async function num(n: int32): Promise<int32> { return n; }

async function main(): Promise<void> {
	const boom = spawn((): int32 => { throw new Error("spawned"); });
	try { await boom; } catch (e) { console.log(`direct ${(e as Error).message}`); }
	console.log(`after ${await num(5)}`);
	const again = spawn((): int32 => { throw new Error("spawned again"); });
	try { await Promise.all([again]); } catch (e) { console.log(`all ${(e as Error).message}`); }
	console.log(`after ${await num(6)}`);
}

await main();
