import {
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node arrayCount.mjs <arrayCountProbe.so>   (msc build tools/solana/arrayCountProbe.ms --os=solana --release --output=arrayCountProbe.so)");
	process.exit(2);
}

const svm = new LiteSVM();
const program = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
svm.addProgramFromFile(program, programPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
svm.airdrop(payer.address, lamports(10_000_000_000n));

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

async function run(op, count, at) {
	const data = new Uint8Array(17);
	const view = new DataView(data.buffer);
	data[0] = op;
	view.setBigUint64(1, BigInt.asUintN(64, count), true);
	view.setBigUint64(9, BigInt.asUintN(64, at), true);
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts: [], data }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	return { ok: !failed, error: failed ? result.err().toString() : "", logs: meta.logs() };
}

const TWO_62 = 2n ** 62n;

for (const [name, op] of [["uint64", 0], ["uint8", 1]]) {
	const valid = await run(op, 3n, 2n);
	check(`[${name}] a valid count builds the array, writes through it and ends in the recorded error`,
		!valid.ok && valid.error.includes("Custom") && valid.logs.some((l) => l.endsWith("0x3")) && valid.logs.some((l) => l.endsWith("0x7")));

	for (const [what, count, at] of [
		["negative count", -1n, -11n],
		["count 2^62 + 1 (the byte size wraps)", TWO_62 + 1n, 3000n],
		["count 2^63 - 1 (the header does not fit)", 2n ** 63n - 1n, 3000n],
	]) {
		const outcome = await run(op, count, at);
		check(`[${name}] ${what}: the instruction fails`, !outcome.ok);
		check(`[${name}] ${what}: the failure is not the recorded error, so the write did not reach the result`, !outcome.error.includes("Custom"));
		check(`[${name}] ${what}: the program aborts like an out-of-range index does`, outcome.error.includes("ProgramFailedToComplete") && outcome.logs.some((l) => l.includes("SBF program panicked")));
		check(`[${name}] ${what}: no access violation`, !outcome.logs.some((l) => /Access violation/.test(l)));
	}
}

if (failures > 0) {
	console.log(`${failures} FAILED`);
	process.exit(1);
}
console.log("all ok");
