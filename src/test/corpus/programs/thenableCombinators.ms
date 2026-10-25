// @stdout: all 1,2,3|race 4|any 6
// @exit: 0
// note: `Promise.all`, `race` and `any` adopt each thenable in an array literal as `await` does, next to promises.

const out: string[] = [];

class Now {
	v: int32;
	constructor(v: int32) { this.v = v; }
	then(onFulfilled: (v: int32) => void): void { onFulfilled(this.v); }
}

class Later {
	v: int32;
	constructor(v: int32) { this.v = v; }
	then(onFulfilled: (v: int32) => void): void { this.deliver(onFulfilled); }
	async deliver(onFulfilled: (v: int32) => void): Promise<void> {
		await sleepAsync(20);
		onFulfilled(this.v);
	}
}

async function three(): Promise<int32> { return 3; }

async function main(): Promise<void> {
	const all = await Promise.all([new Now(1), new Later(2), three()]);
	out.push(`all ${all[0]},${all[1]},${all[2]}`);
	out.push(`race ${await Promise.race([new Now(4), new Later(5)])}`);
	out.push(`any ${await Promise.any([new Now(6)])}`);
	console.log(out.join("|"));
}

main();
