// @stdout: empty 0
// @stdout: ints 6
// @stdout: strings a!b!
// @stdout: structs 9 p2
// @stdout: all rejects late
// @stdout: spawned 42
// @stdout: spawned rejects spawned
// @stdout: race 5
// @stdout: race rejects first
// @stdout: any 7
// @stdout: any rejects All promises were rejected
// @stdout: any empty All promises were rejected
// @serial
// note: Promise.all, race and any settle alike on every backend: values in input order for int, string and
//   struct elements, the first rejection, an empty input, pending spawned inputs and inputs already settled.

struct Pt { x: int32; label: string; }

async function num(n: int32): Promise<int32> { return n; }
async function text(s: string): Promise<string> { return s + "!"; }
async function point(x: int32): Promise<Pt> { return { x, label: "p" + x.toString() }; }
function rejected(m: string): Promise<int32> { return Promise.reject(new Error(m)); }

async function main(): Promise<void> {
	const none: Promise<int32>[] = [];
	console.log(`empty ${(await Promise.all(none)).length}`);
	const ns = await Promise.all([num(1), num(2), num(3)]);
	console.log(`ints ${ns[0] + ns[1] + ns[2]}`);
	const ts = await Promise.all([text("a"), text("b")]);
	console.log(`strings ${ts[0]}${ts[1]}`);
	const ps = await Promise.all([point(1), point(2)]);
	ps[0].x = 9;
	console.log(`structs ${ps[0].x} ${ps[1].label}`);
	try {
		await Promise.all([num(1), rejected("late"), rejected("later")]);
		console.log("all resolved");
	} catch (e) {
		console.log(`all rejects ${(e as Error).message}`);
	}
	const a = spawn((): int32 => 40);
	const b = spawn((): int32 => 2);
	const sum = await Promise.all([a, b]);
	console.log(`spawned ${sum[0] + sum[1]}`);
	const ok = spawn((): int32 => 1);
	const boom = spawn((): int32 => { throw new Error("spawned"); });
	try {
		await Promise.all([ok, boom]);
		console.log("spawned resolved");
	} catch (e) {
		console.log(`spawned rejects ${(e as Error).message}`);
	}
	console.log(`race ${await Promise.race([num(5), num(6)])}`);
	try {
		await Promise.race([rejected("first"), num(6)]);
	} catch (e) {
		console.log(`race rejects ${(e as Error).message}`);
	}
	console.log(`any ${await Promise.any([rejected("q"), num(7)])}`);
	try {
		await Promise.any([rejected("q"), rejected("w")]);
	} catch (e) {
		console.log(`any rejects ${(e as Error).message}`);
	}
	try {
		await Promise.any(none);
	} catch (e) {
		console.log(`any empty ${(e as Error).message}`);
	}
}

await main();
