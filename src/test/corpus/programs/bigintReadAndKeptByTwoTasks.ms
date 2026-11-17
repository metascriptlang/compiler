// @stdout: const 4000 lent 4000 field 4000
// @serial

const B: bigint = 123456789012345678901234567890n;

interface Limits { ceiling: bigint; }
const LIMITS: Readonly<Limits> = { ceiling: 987654321098765432109876543210n };

function keepConst(): int32 {
	const keep: bigint[] = [];
	for (let i = 0; i < 2000; i += 1) { keep.push(B); }
	return keep.length;
}

function keepLent(x: bigint): int32 {
	const keep: bigint[] = [];
	for (let i = 0; i < 2000; i += 1) { keep.push(x); }
	return keep.length;
}

function keepField(): int32 {
	const keep: bigint[] = [];
	for (let i = 0; i < 2000; i += 1) { keep.push(LIMITS.ceiling); }
	return keep.length;
}

async function main(): Promise<void> {
	const a = spawn(() => keepConst());
	const b = spawn(() => keepConst());
	const fromConst = await a + await b;
	const big: bigint = B * 3n;
	const c = spawn(() => keepLent(big));
	const d = spawn(() => keepLent(big));
	const fromLent = await c + await d;
	const e = spawn(() => keepField());
	const f = spawn(() => keepField());
	console.log(`const ${fromConst} lent ${fromLent} field ${await e + await f}`);
}

await main();
