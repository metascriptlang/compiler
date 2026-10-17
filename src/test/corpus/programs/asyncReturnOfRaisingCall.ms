// @stdout: noAwait caught boom|afterAwait caught boom|local caught boom|statement caught boom|void caught boom|sideEffect ran|plain resolved
// @exit: 0

const out: string[] = [];
let effects: int32 = 0;

function boom(): string { throw new Error("boom"); }
function fail(): void { throw new Error("boom"); }
function note(): void { effects += 1; }
function plain(): string { return "ok"; }

async function noAwait(): Promise<string> { return boom(); }
async function afterAwait(): Promise<string> { await sleepAsync(1); return boom(); }
async function local(): Promise<string> { await sleepAsync(1); const r = boom(); return r; }
async function statement(): Promise<string> { await sleepAsync(1); boom(); return "ok"; }
async function voidReturn(): Promise<void> { await sleepAsync(1); return fail(); }
async function sideEffect(): Promise<void> { return note(); }
async function plainReturn(): Promise<string> { return plain(); }

async function report(name: string, run: () => Promise<string>): Promise<void> {
	try { await run(); out.push(`${name} resolved`); } catch (e) { out.push(`${name} caught ${(e as Error).message}`); }
}

async function main(): Promise<void> {
	await report("noAwait", (): Promise<string> => noAwait());
	await report("afterAwait", (): Promise<string> => afterAwait());
	await report("local", (): Promise<string> => local());
	await report("statement", (): Promise<string> => statement());
	try { await voidReturn(); out.push("void no throw"); } catch (e) { out.push(`void caught ${(e as Error).message}`); }
	await sideEffect();
	out.push(effects == 1 ? "sideEffect ran" : "sideEffect lost");
	await report("plain", (): Promise<string> => plainReturn());
	console.log(out.join("|"));
}

main();
