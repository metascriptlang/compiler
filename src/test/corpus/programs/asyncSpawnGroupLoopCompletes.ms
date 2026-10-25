// @serial
// @stdout: ints 60000
// @stdout: pts 6000
// @stdout: strs 6000
// note: in an async function, `await Promise.all([spawn(...), ...])` set the group's
//   done future after submitting the tasks, so when every slot finished first nothing
//   completed it and the await hung; 1000 rounds hung on every run before the fix.
//   Rounds vary the slot count and result kind: two int32, three structs, two strings.

struct Pt { x: int32; }

function mk(x: int32): Pt { return { x: x }; }
function tag(n: int32): string { return n.toString(); }

async function ints(): Promise<int32> {
	let total = 0;
	for (let i = 0; i < 20000; i += 1) {
		const xs = await Promise.all([spawn((): int32 => 1), spawn((): int32 => 2)]);
		total += xs[0] + xs[1];
	}
	return total;
}

async function pts(): Promise<int32> {
	let total = 0;
	for (let i = 0; i < 1000; i += 1) {
		const ps = await Promise.all([spawn(() => mk(1)), spawn(() => mk(2)), spawn(() => mk(3))]);
		total += ps[0].x + ps[1].x + ps[2].x;
	}
	return total;
}

async function strs(): Promise<int32> {
	let total = 0;
	for (let i = 0; i < 2000; i += 1) {
		const ss = await Promise.all([spawn(() => tag(1)), spawn(() => tag(22))]);
		total += ss[0].length + ss[1].length;
	}
	return total;
}

console.log(`ints ${await ints()}`);
console.log(`pts ${await pts()}`);
console.log(`strs ${await strs()}`);
