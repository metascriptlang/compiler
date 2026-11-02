// @stdout: resolved 2|pending 3 ran 3|rejected boom|declared 0 2 true|nulls 3 true|empty 0
// @exit: 0
// note: Promise.all over Promise<void> resolves to an array of undefined, as in TS: resolved and pending elements keep the array's length, a rejection rejects the whole, a declared void[] holds the null carrier, Promise.all over Promise<null> collects the same way, and an empty list resolves to an empty array.

async function done(): Promise<void> {}

let ran = 0;
async function later(): Promise<void> {
	await Promise.resolve(0);
	ran += 1;
}

async function fails(): Promise<void> {
	throw new Error("boom");
}

function nothing(): void {}

async function none(): Promise<null> {
	return null;
}

async function main(): Promise<void> {
	const a = await Promise.all([done(), done()]);
	const b = await Promise.all([later(), later(), later()]);
	let rejected = "none";
	try {
		await Promise.all([done(), fails()]);
	} catch (e) {
		rejected = (e as Error).message;
	}
	const xs: void[] = [];
	const ys: void[] = [nothing(), nothing()];
	const n = await Promise.all([none(), none(), none()]);
	const nothingYet: Promise<void>[] = [];
	const e = await Promise.all(nothingYet);
	console.log(`resolved ${a.length}|pending ${b.length} ran ${ran}|rejected ${rejected}|declared ${xs.length} ${ys.length} ${ys[0] === undefined}|nulls ${n.length} ${n[0] === null}|empty ${e.length}`);
}
await main();
