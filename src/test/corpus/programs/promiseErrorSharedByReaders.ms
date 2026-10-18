// A rejected promise keeps its Error for every reader: a combinator or a then/catch
// output and a later await of the input each see the same message, a second await sees it
// again, and the Error is destroyed once the last holder lets go, on C and JS.
// @xfail(raiser): raiser-solid owns Raiser Promise APIs (no host bridge for the combinators and then/catch/finally)
// @stdout: race no
// @stdout: all no
// @stdout: any All promises were rejected
// @stdout: settled
// @stdout: then no
// @stdout: catch no
// @stdout: second no
// @stdout: race won 7
// @stdout: caught handler
// @stdout: done

import { sleepAsync } from "std/core/promise";

async function fail(ms: int32): Promise<int32> {
	await sleepAsync(ms);
	throw new Error("no");
}

async function ok(ms: int32): Promise<int32> {
	await sleepAsync(ms);
	return 7;
}

async function combinators(): Promise<void> {
	const raced = fail(1);
	try { await Promise.race([raced]); } catch (e) { console.log(`race ${e.message}`); }
	try { await raced; } catch (e) { console.log(`input ${e.message}`); }

	const joined = fail(1);
	try { await Promise.all([joined]); } catch (e) { console.log(`all ${e.message}`); }
	try { await joined; } catch (e) { console.log(`input ${e.message}`); }

	const anyOf = fail(1);
	try { await Promise.any([anyOf]); } catch (e) { console.log(`any ${e.message}`); }
	try { await anyOf; } catch (e) { console.log(`input ${e.message}`); }

	const settled = fail(1);
	await Promise.allSettled([settled]);
	console.log("settled");
	try { await settled; } catch (e) { console.log(`input ${e.message}`); }
}

async function handlers(): Promise<void> {
	const thened = fail(1);
	try { await thened.then((v: int32): void => { console.log(`value ${v}`); }); } catch (e) { console.log(`then ${e.message}`); }
	try { await thened; } catch (e) { console.log(`input ${e.message}`); }

	const caught = fail(1);
	await caught.catch((e: string): void => { console.log(`catch ${e}`); });
	try { await caught; } catch (e) { console.log(`input ${e.message}`); }
}

async function readers(): Promise<void> {
	const twice = fail(1);
	try { await twice; } catch (e) { console.log(`first ${e.message}`); }
	try { await twice; } catch (e) { console.log(`second ${e.message}`); }

	const late = fail(20);
	const won = await Promise.race([ok(1), late]);
	console.log(`race won ${won}`);
	await sleepAsync(40);

	await fail(1).catch((e: string): void => { console.log(`caught handler`); });
}

await combinators();
await handlers();
await readers();
console.log("done");
