// @stdout: order a b c d | int 42 | text hi | pair 7 seven | first 1 | void ok | later 9 | reject boom | thrown bad | text raw | late 5 | twice hi hi | after done
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: new Promise<T>(executor) runs the executor at once, in the calling order (the log reads
// a b c d). resolve completes the promise with a value of T, whatever T is (number, string,
// struct, void) and only the first resolve or reject counts; reject(message) rejects with an
// Error carrying that message, as a thrown string does (the .catch reader is
// newPromiseCatch); a throw out of the executor rejects unless it already settled. The promise can be
// settled later, from a callback that outlives the executor. An await may read the same
// promise twice.

struct Pair { n: int32; tag: string; }

let log = "";
let pending: ((v: int32) => void) | null = null;

async function settleLater(v: int32): Promise<void> {
	await sleepAsync(1);
	const settle = pending;
	if (settle !== null) settle(v);
}

async function run(): Promise<void> {
	log += "a";
	const num = new Promise<int32>((resolve, reject) => { log += " b"; resolve(42); log += " c"; });
	log += " d";
	let out = `order ${log} | int ${await num}`;

	const text = new Promise<string>((resolve, reject) => { resolve("hi"); });
	out += ` | text ${await text}`;

	const pair = new Promise<Pair>((resolve, reject) => { resolve({ n: 7, tag: "seven" }); });
	const pr = await pair;
	out += ` | pair ${pr.n} ${pr.tag}`;

	const first = new Promise<int32>((resolve, reject) => { resolve(1); resolve(2); reject("late"); });
	out += ` | first ${await first}`;

	const nothing = new Promise<void>((resolve, reject) => { resolve(); });
	await nothing;
	out += " | void ok";

	const later = new Promise<int32>((resolve, reject) => { pending = resolve; });
	settleLater(9);
	out += ` | later ${await later}`;

	const rejected = new Promise<string>((resolve, reject) => { reject("boom"); });
	try { await rejected; out += " | reject lost"; } catch (e) { out += ` | reject ${(e as Error).message}`; }

	const thrown = new Promise<string>((resolve, reject) => { throw new Error("bad"); });
	try { await thrown; out += " | thrown lost"; } catch (e) { out += ` | thrown ${(e as Error).message}`; }

	const thrownText = new Promise<int32>((resolve, reject) => { throw "raw"; });
	try { await thrownText; out += " | text lost"; } catch (e) { out += ` | text ${(e as Error).message}`; }

	const settled = new Promise<int32>((resolve, reject) => { resolve(5); throw new Error("ignored"); });
	out += ` | late ${await settled}`;

	const again = new Promise<string>((resolve, reject) => { resolve("hi"); });
	out += ` | twice ${await again} ${await again}`;

	console.log(out + " | after done");
}

await run();
