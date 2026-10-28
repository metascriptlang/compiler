// @stdout: replaced 5

class Holder {
	pending: Promise<number>;
	constructor(p: Promise<number>) {
		this.pending = p;
	}
}

async function value(n: number): Promise<number> {
	return n;
}

function main(): void {
	let last = new Holder(value(9));
	let made = 1;
	for (let i = 0; i < 4; i += 1) {
		last = new Holder(value(i));
		made += 1;
	}
	console.log(`replaced ${made}`);
}

main();
