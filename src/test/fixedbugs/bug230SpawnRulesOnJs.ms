// Symptom: on the JS backend every spawn rule the C checker enforces was skipped: a captured `let`, a write
//   through a capture, a discarded spawn result and a move of a module-level binding compiled and ran, and a
//   valid `spawn(fn, { move: [c] })` failed with "Too many arguments: expected at most 1, got 2".
// Root cause: std/core/promise/index.jms declared `spawn` without `@builtin("PromiseSpawn")`, the tag the checker's
//   spawn rules and move-list desugaring key on.
// Fix: the JS `spawn` carries the tag, and builtinLower leaves Promise builtins alone on JS, where the prelude
//   function is the lowering.

import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitJs230(src: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/spawnRules.ms", entrySource: src }];
	return compileProjectToJSWithStd(entries, "test/spawnRules.ms");
}

test "bug230: JS rejects a mutable local captured by spawn" {
	const js = emitJs230(`
let x = 1;
const h = spawn(() => x + 1);
console.log(\`\${await h}\`);
`);
	assert js.contains("cannot be captured by spawn"), js;
}

test "bug230: JS rejects a write through a spawn capture" {
	const js = emitJs230(`
class Data { n: int32 = 0; }
const d = new Data();
const h = spawn(() => { d.n = 5; return 0; });
await h;
`);
	assert js.contains("cannot write through Readonly<Data>"), js;
}

test "bug230: JS rejects a discarded spawn result" {
	const js = emitJs230(`
spawn(() => 1);
`);
	assert js.contains("spawn result is discarded"), js;
}

test "bug230: JS rejects moving a module-level binding" {
	const js = emitJs230(`
class C { n: int32 = 7; }
const c = new C();
const h = spawn(() => c.n, { move: [c] });
console.log(\`\${await h}\`);
`);
	assert js.contains("cannot move 'c'"), js;
}

test "bug230: JS accepts a move list" {
	const js = emitJs230(`
class C { n: int32 = 7; }
async function run(): Promise<int32> {
	const c = new C();
	const h = spawn(() => { c.n = c.n + 2; return c.n; }, { move: [c] });
	return await h;
}
console.log(\`\${await run()}\`);
`);
	assert js.indexOf("ERROR", 0) < 0, js;
	assert !js.contains("msSpawn");
}
