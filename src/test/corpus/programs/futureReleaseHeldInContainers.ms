// @stdout: field 3
// @stdout: array 1,2
// @stdout: tuple 7 x
// @stdout: dropped 4
class Holder {
	pending: Promise<number>;
	constructor(p: Promise<number>) {
		this.pending = p;
	}
}

async function value(n: number): Promise<number> {
	await Promise.resolve(0);
	return n;
}

async function main(): Promise<void> {
	const holder = new Holder(value(3));
	console.log(`field ${await holder.pending}`);

	const all: Promise<number>[] = [value(1), value(2)];
	const got: number[] = [];
	for (const p of all) got.push(await p);
	console.log(`array ${got.join(",")}`);

	const pair: [Promise<number>, string] = [value(7), "x"];
	console.log(`tuple ${await pair[0]} ${pair[1]}`);

	let last = holder;
	for (let i = 0; i < 4; i += 1) last = new Holder(value(i));
	await last.pending;
	console.log("dropped 4");
}

main();
