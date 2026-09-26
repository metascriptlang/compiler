// Symptom: on the JS backend a sync function that awaits was emitted as an `async function`, so its callers received
//   a Promise: `function run(): int32 { return await h; } console.log(run())` printed `[object Promise]`, and
//   `process.exit(main())` ended the program before the awaits resumed.
// Root cause: codegen/js `needsAutoAsync` turned any body holding an await into an async function; JS has no blocking
//   wait, which is what a sync-context await means on the native backends.
// Fix: syncAwait refuses an await in a function that is not async before the JS transform; the module top level, test
//   bodies, spawn thunks and actor methods keep their await, because each result is awaited by whoever consumes it.

import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitJs231(src: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/syncAwait.ms", entrySource: src }];
	return compileProjectToJSWithStd(entries, "test/syncAwait.ms");
}

test "bug231: JS refuses an await in a sync function" {
	const js = emitJs231(`
async function g(): Promise<int32> { return 1; }
function run(): int32 { return await g(); }
console.log(\`\${run()}\`);
`);
	assert js.contains("await in a function that is not async"), js;
}

test "bug231: JS refuses an await in a sync callback" {
	const js = emitJs231(`
async function g(n: int32): Promise<int32> { return n; }
function each(xs: int32[], f: (n: int32) => void): void { for (const x of xs) { f(x); } }
async function all(): Promise<void> { each([1, 2], (n: int32) => { console.log(\`\${await g(n)}\`); }); }
await all();
`);
	assert js.contains("await in a function that is not async"), js;
}

test "bug231: JS keeps an await at the module top level and in an async function" {
	const js = emitJs231(`
async function g(): Promise<int32> { return 1; }
async function run(): Promise<int32> { return await g(); }
console.log(\`\${await run()}\`);
`);
	assert js.indexOf("ERROR", 0) < 0, js;
}

test "bug231: JS keeps an await in a spawn thunk" {
	const js = emitJs231(`
async function g(): Promise<int32> { return 1; }
const h = spawn(() => { return await g(); });
console.log(\`\${await h}\`);
`);
	assert js.indexOf("ERROR", 0) < 0, js;
}
