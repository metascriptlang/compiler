// @stdout: order a b c d | int 42 | text hi | pair 7 seven | first 1 | void ok | later 9 | reject boom | thrown caught | late 5 | twice hi hi | after done
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: new Promise<T>(executor) runs the executor at once, in the calling order (the log reads
// a b c d). resolve completes the promise with a value of T, whatever T is (number, string,
// struct, void) and only the first resolve or reject counts; reject(message) rejects with that
// message; a throw out of the executor rejects unless it already settled. The promise can be
// settled later, from a callback that outlives the executor. An await may read the same
// promise twice. The rejected promise is read through .catch, whose consumed
// Error the SAN ledger does not balance (.inbox/compiler/2026-10-06-catch-handler-never-destroys-the-error.md):
// the ledger skips a type with no destroy, and this program destroys none of that type.

struct Pair { n: int32; tag: string; }

let log = "";

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

	const later = new Promise<int32>((resolve, reject) => { sleepAsync(1).then(() => { resolve(9); }); });
	out += ` | later ${await later}`;

	const rejected = new Promise<string>((resolve, reject) => { reject("boom"); });
	out += ` | reject ${await rejected.catch((e: string) => e)}`;

	const thrown = new Promise<string>((resolve, reject) => { throw new Error("bad"); });
	try { await thrown; out += " | thrown lost"; } catch (e) { out += " | thrown caught"; }

	const settled = new Promise<int32>((resolve, reject) => { resolve(5); throw new Error("ignored"); });
	out += ` | late ${await settled}`;

	const again = new Promise<string>((resolve, reject) => { resolve("hi"); });
	out += ` | twice ${await again} ${await again}`;

	console.log(out + " | after done");
}

await run();
