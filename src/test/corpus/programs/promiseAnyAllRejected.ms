// @stdout: int All promises were rejected
// @stdout: string All promises were rejected
// @stdout: struct All promises were rejected
// @stdout: empty All promises were rejected
// @stdout: pool All promises were rejected
// @stdout: any skips rejection 7
// @stdout: empty race pending
// @serial
// note: Promise.any rejects with "All promises were rejected" once every input rejected, for an int32, a string and a struct element, over an empty array, and over inputs rejected on pool threads; one fulfilled input among rejections still wins; Promise.race over an empty array never settles.

struct Pt { name: string; n: int32; }

async function noInt(): Promise<int32> { await Promise.resolve(0); throw new Error("a"); }
async function noWord(): Promise<string> { await Promise.resolve(0); throw new Error("b"); }
async function noPoint(): Promise<Pt> { await Promise.resolve(0); throw new Error("c"); }
async function okInt(n: int32): Promise<int32> { await Promise.resolve(0); await Promise.resolve(0); return n; }

function poolNo(): Promise<string> {
	return spawn((): string => { throw new Error("pool"); });
}

async function messageOf<T>(p: Promise<T>): Promise<string> {
	try {
		await p;
		return "resolved";
	} catch (e) {
		return (e as Error).message;
	}
}

async function main(): Promise<void> {
	console.log("int " + await messageOf(Promise.any([noInt(), noInt(), noInt()])));
	console.log("string " + await messageOf(Promise.any([noWord(), noWord()])));
	console.log("struct " + await messageOf(Promise.any([noPoint(), noPoint()])));
	const none: Promise<string>[] = [];
	console.log("empty " + await messageOf(Promise.any(none)));
	let last = "";
	for (let round = 0; round < 50; round++) last = await messageOf(Promise.any([poolNo(), poolNo(), poolNo()]));
	console.log("pool " + last);
	console.log("any skips rejection " + await Promise.any([noInt(), okInt(7), noInt()]));
	const pending = Promise.race(none);
	for (let i = 0; i < 4; i++) await Promise.resolve(0);
	console.log("empty race pending");
	pending;
}

await main();
