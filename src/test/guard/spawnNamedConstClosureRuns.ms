// nim-guard: named closures that capture only const values still spawn (P1cap)
//
// INVARIANT: the neighbour of the P1cap refusals: a const-bound closure, a local function declaration and a closure with an inner closure, all capturing only a const, compile and run.
// RED MEANS: the named-closure refusal over-reaches into closures that are judged at their declaration.
//
// GUARD-JS

async function run(): Promise<int32> {
	const k: int32 = 3;
	const f = (): int32 => { let s: int32 = 0; for (let i = 0; i < 1000; i += 1) s += k; return s; };
	function g(): int32 { return k * 2; }
	const h = (): int32 => { const inner = (x: int32): int32 => x + k; let t: int32 = 0; t = inner(1); return t; };
	const a = spawn(f);
	const b = spawn(g);
	const c = spawn(h);
	return (await a) + (await b) + (await c);
}
const sum = await run();
console.log(sum == 3010 ? "GUARD-OK" : `GUARD-FAIL sum=${sum}`);
