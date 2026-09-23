// @stdout: sum=15 last=5

// A module that awaits at its top level and imports nothing still loads as an ES
// module on node. Node's own detection recovers `const x = await f()`, but not an
// await inside a call argument, where CommonJS reads `await` as an identifier; the
// emitter marks the module with `export {};` ahead of it, bundled and split alike.
async function add(a: int32, b: int32): Promise<int32> { return a + b; }

async function last(): Promise<int32> { return 5; }

console.log(`sum=${await add(7, 8)} last=${await last()}`);
