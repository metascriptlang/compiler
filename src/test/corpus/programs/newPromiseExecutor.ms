// @stdout: 10|void|later-7|3,4|rejected boom|thrown bad|1|first|7|5|annotated void|callback
// @exit: 0

struct Point {
	x: int32;
	y: int32;
}

const out: string[] = [];

async function after(ms: number, run: () => void): Promise<void> {
	await sleepAsync(ms);
	run();
}

function callVoid(cb: (v: void) => void): void {
	cb();
}

function inferred(): Promise<number> {
	return new Promise((resolve) => { resolve(7); });
}

function annotated(ms: number): Promise<number> {
	return new Promise<number>((resolve: (v: number) => void, reject: (e: Error) => void): void => { resolve(ms); });
}

async function main(): Promise<void> {
	out.push(`${await new Promise<number>((resolve, reject) => { resolve(10); })}`);

	await new Promise<void>((resolve) => { after(5, (): void => { resolve(); }); });
	out.push("void");

	const word = await new Promise<string>((resolve) => {
		after(5, (): void => { resolve(`later-${3 + 4}`); });
	});
	out.push(word);

	const p = await new Promise<Point>((resolve) => { resolve({ x: 3, y: 4 }); });
	out.push(`${p.x},${p.y}`);

	try {
		await new Promise<number>((resolve, reject) => { reject(new Error("boom")); });
	} catch (e) {
		out.push(`rejected ${e.message}`);
	}

	try {
		await new Promise<number>((resolve) => { throw new Error("bad"); });
	} catch (e) {
		out.push(`thrown ${e.message}`);
	}

	out.push(`${await new Promise<number>((resolve, reject) => { resolve(1); resolve(2); reject(new Error("late")); })}`);
	const first = `first${""}`;
	const second = `second${""}`;
	out.push(await new Promise<string>((resolve) => { resolve(first); resolve(second); }));
	out.push(`${await inferred()}`);
	out.push(`${await annotated(5)}`);
	await new Promise<void>((resolve: () => void): void => { resolve(); });
	out.push("annotated void");
	callVoid((v: void): void => { out.push("callback"); });
	console.log(out.join("|"));
}

main();
