// @stdout: 14|15|x!|y!|3,4|3,4|3,4|5|7|h:ab|8|7|ok
// An async function returns what it awaits: `return load(n)` carries the same
// meaning as `return await load(n)` for functions, arrows and expression-bodied
// arrows, over int, string and struct payloads, through a relay of a relay, and for
// a promise made by Promise.resolve.

struct Pt { x: int32; y: int32; }

async function loadInt(n: int32): Promise<int32> { return n * 2; }
async function loadStr(s: string): Promise<string> { return s + "!"; }
async function loadPt(a: int32): Promise<Pt> { return { x: a, y: a + 1 }; }

async function viaFn(n: int32): Promise<int32> { return loadInt(n); }
const viaArrow = async (n: int32): Promise<int32> => { return loadInt(n + 1); };
const viaExpr = async (n: int32): Promise<int32> => loadInt(n + 2);
const viaInferred = async (n: int32) => loadInt(n);

async function strFn(s: string): Promise<string> { return loadStr(s); }
const strArrow = async (s: string): Promise<string> => { return loadStr(s); };

async function ptFn(a: int32): Promise<Pt> { return loadPt(a); }
const ptArrow = async (a: int32): Promise<Pt> => { return loadPt(a); };
const ptExpr = async (a: int32): Promise<Pt> => loadPt(a);

async function relay1(n: int32): Promise<int32> { return viaFn(n); }
async function relay2(n: int32): Promise<int32> { return relay1(n); }
async function viaResolve(): Promise<int32> { return Promise.resolve(7); }

async function guarded(n: int32): Promise<int32> {
	try { return await loadInt(n); } catch (e) { return -1; }
}

async function afterTry(n: int32): Promise<string> {
	try { await loadInt(n); } finally { }
	return loadStr("h:ab".slice(2));
}

function show(p: Pt): string { return p.x + "," + p.y; }

async function main() {
	const a = await viaFn(7);
	const b = await viaArrow(5) + (await viaExpr(0) - 1);
	const c = await strFn("x");
	const d = await strArrow("y");
	const e = show(await ptFn(3));
	const f = show(await ptArrow(3));
	const g = show(await ptExpr(3));
	const h = await guarded(2) + (await viaInferred(0) + 1);
	const i = await relay2(3) + 1;
	const j = "h:" + (await afterTry(1)).slice(0, 2);
	const k = await relay2(4);
	const l = await viaResolve();
	console.log(a + "|" + b + "|" + c + "|" + d + "|" + e + "|" + f + "|" + g + "|" + h + "|" + i + "|" + j + "|" + k + "|" + l + "|ok");
}
main();
