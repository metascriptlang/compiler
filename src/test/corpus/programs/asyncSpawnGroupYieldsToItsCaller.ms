// @stdout: plain: caller continues
// @stdout: plain: group done
// @stdout: plain 7
// @stdout: extension: caller continues
// @stdout: extension: group done
// @stdout: extension 7
// @stdout: sink: caller continues
// @stdout: sink: group done
// @stdout: sink 7
// @stdout: method: caller continues
// @stdout: method: group done
// @stdout: method 11

struct Box { v: int32; }
class Bag { v: int32 = 4; }

async function plain(v: int32): Promise<int32> {
	const xs = await Promise.all([spawn((): int32 => 1), spawn((): int32 => 2)]);
	console.log("plain: group done");
	return xs[0] + xs[1] + v;
}

async function viaExtension(this b: Box): Promise<int32> {
	const xs = await Promise.all([spawn((): int32 => 1), spawn((): int32 => 2)]);
	console.log("extension: group done");
	return xs[0] + xs[1] + b.v;
}

async function viaSink(sink b: Bag): Promise<int32> {
	const xs = await Promise.all([spawn((): int32 => 1), spawn((): int32 => 2)]);
	console.log("sink: group done");
	return xs[0] + xs[1] + b.v;
}

class Pair {
	v: int32 = 4;
	async sum(sink t: Bag): Promise<int32> {
		const xs = await Promise.all([spawn((): int32 => 1), spawn((): int32 => 2)]);
		console.log("method: group done");
		return xs[0] + xs[1] + this.v + t.v;
	}
}

const p0 = plain(4);
console.log("plain: caller continues");
console.log(`plain ${await p0}`);

const box: Box = { v: 4 };
const p1 = box.viaExtension();
console.log("extension: caller continues");
console.log(`extension ${await p1}`);

const p2 = viaSink(new Bag());
console.log("sink: caller continues");
console.log(`sink ${await p2}`);

const pair = new Pair();
const p3 = pair.sum(new Bag());
console.log("method: caller continues");
console.log(`method ${await p3}`);
