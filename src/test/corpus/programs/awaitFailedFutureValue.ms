// @stdout: string caught boom|inline caught boom|struct caught boom|number caught boom|ok fine
// @exit: 0

struct Point {
	x: int32;
	y: int32;
}

const out: string[] = [];

function boom(): string { throw new Error("boom"); }
async function badString(): Promise<string> { const r = boom(); return r; }
async function badPoint(): Promise<Point> { throw new Error("boom"); }
async function badNumber(): Promise<number> { throw new Error("boom"); }
async function good(): Promise<string> { return "fine"; }

async function main(): Promise<void> {
	try { const s = await badString(); out.push(`string ${s}`); } catch (e) { out.push(`string caught ${(e as Error).message}`); }
	try { out.push(`inline ${await badString()}`); } catch (e) { out.push(`inline caught ${(e as Error).message}`); }
	try { const p = await badPoint(); out.push(`struct ${p.x}`); } catch (e) { out.push(`struct caught ${(e as Error).message}`); }
	try { const n = await badNumber(); out.push(`number ${n}`); } catch (e) { out.push(`number caught ${(e as Error).message}`); }
	const g = await good();
	out.push(`ok ${g}`);
	console.log(out.join("|"));
}

main();
