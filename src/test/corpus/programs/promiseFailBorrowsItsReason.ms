// @stdout: rejected boom|thrown bad|late 1|kept keep 2|thenable nope
// @exit: 0

class Refuse {
	then(onFulfilled: (v: int32) => void, onRejected: (reason: Error) => void): void { onRejected(new Error("nope")); }
}

async function main(): Promise<void> {
	const out: string[] = [];
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
	out.push(`late ${await new Promise<number>((resolve, reject) => { resolve(1); reject(new Error("late")); })}`);
	const shared = new Error("keep");
	let seen = 0;
	for (let i = 0; i < 2; i += 1) {
		try {
			await new Promise<number>((resolve, reject) => { reject(shared); });
		} catch (e) {
			seen += 1;
		}
	}
	out.push(`kept ${shared.message} ${seen}`);
	try {
		await new Refuse();
	} catch (e) {
		out.push(`thenable ${e.message}`);
	}
	console.log(out.join("|"));
}

main();
