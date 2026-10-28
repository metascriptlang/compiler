// @stdout: maps 2 3
// @stdout: await 42
// @stdout: await reject 2
// @stdout: return 42
// @stdout: resolve 42
// @stdout: spread 1 2 2 3
// @stdout: spread x 2 y
// @exit: 0
// note: a call the compiler writes for the author (the builder of a map literal, the adoption of an awaited thenable, the rest of a spread) reaches std's routine. Each user function below shares a name with one of them and prints when called.

class Box { then(fulfil: (v: int32) => void): void { fulfil(41); } }
class Box2 { then(fulfil: (v: int32) => void, reject: (e: Error) => void): void { fulfil(1); } }

function mapFromPairs(k: string[], v: int32[]): Map<string, int32> { console.log("user mapFromPairs"); return new Map<string, int32>(); }
function hashMapFromPairs(k: string[], v: int32[]): HashMap<string, int32> { console.log("user hashMapFromPairs"); return new HashMap<string, int32>(); }
function promiseFromThenable(x: Box, f: (t: Box, a: (v: int32) => void, b: (e: Error) => void) => void): Promise<int32> { console.log("user promiseFromThenable"); return Promise.resolve(0); }
function slice(this xs: int32[], n: int32): int32[] { console.log("user slice"); return [99]; }
function slice(this xs: string[], n: int32): string[] { console.log("user slice"); return ["z"]; }

function g(a: int32 = 10, b: int32 = 20, ...rest: int32[]): void { console.log("spread", a, b, rest.length, rest[0]); }
function h(a: string = "a", ...rest: string[]): void { console.log("spread", a, rest.length, rest[0]); }

async function viaReturn(): Promise<int32> { return new Box(); }

async function main(): Promise<void> {
	const m: Map<string, int32> = { a: 1, b: 2 };
	const hm: HashMap<string, int32> = { a: 1, b: 2, c: 3 };
	console.log("maps", m.size, hm.size);
	console.log("await", await new Box() + 1);
	console.log("await reject", await new Box2() + 1);
	console.log("return", await viaReturn() + 1);
	console.log("resolve", await Promise.resolve(new Box()) + 1);
	g(...[1, 2, 3, 4]);
	h(...["x", "y", "z"]);
}
main();
