// @stdout: class worker boom
// @stdout: string worker boom text
// @stdout: int worker boom int
// @skip-raiser: the Raiser runs spawn inline
class Box { v: int32 = 1; }

async function failsBox(): Promise<Box> {
	throw new Error("boom");
}

async function failsText(): Promise<string> {
	throw new Error("boom text");
}

async function failsInt(): Promise<int32> {
	throw new Error("boom int");
}

async function run(): Promise<void> {
	const r = await spawn(() => {
		try {
			const b = await failsBox();
			return `unexpected ${b.v}`;
		} catch (e) {
			return e.message;
		}
	});
	console.log(`class worker ${r}`);
	const s = await spawn(() => {
		try {
			const t = await failsText();
			return `unexpected ${t}`;
		} catch (e) {
			return e.message;
		}
	});
	console.log(`string worker ${s}`);
	const i = await spawn(() => {
		try {
			const n = await failsInt();
			return `unexpected ${n}`;
		} catch (e) {
			return e.message;
		}
	});
	console.log(`int worker ${i}`);
}

await run();
