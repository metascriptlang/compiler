// A rejected promise keeps its Error through .finally: the finally output and a later await
// of the input each see the same message, and the Error is destroyed once.
// @skip-js: the JS std Promise declares no finally (std/core/promise/index.jms)
// @xfail(raiser): raiser-solid owns Raiser Promise APIs (no host bridge for the combinators and then/catch/finally)
// @stdout: finally no
// @stdout: chain no
// @stdout: done

import { sleepAsync } from "std/core/promise";

async function fail(ms: int32): Promise<int32> {
	await sleepAsync(ms);
	throw new Error("no");
}

async function run(): Promise<void> {
	const finalized = fail(1);
	try { await finalized.finally((): void => { console.log("fin"); }); } catch (e) { console.log(`finally ${e.message}`); }
	try { await finalized; } catch (e) { console.log(`input ${e.message}`); }

	const chained = fail(1);
	try {
		await chained.then((v: int32): void => { console.log(`value ${v}`); }).finally((): void => { console.log("fin"); });
	} catch (e) { console.log(`chain ${e.message}`); }
	try { await chained; } catch (e) { console.log(`input ${e.message}`); }
}

await run();
console.log("done");
