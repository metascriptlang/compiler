import {
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
	console.error("usage: node failFirst.mjs <failFirstProbe.so>   (msc build tools/solana/failFirstProbe.ms --os=solana --release --output=failFirstProbe.so)");
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

async function run(op) {
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts: [], data: new Uint8Array([op]) }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	return result.constructor.name === "FailedTransactionMetadata" ? result.err().toString() : "ok";
}

check("two failWith calls: the instruction ends with the first error", (await run(0)).includes("code: 5 }"));
check("one failWith call: the instruction ends with that error", (await run(1)).includes("code: 6 }"));
check("no failWith call: the instruction succeeds", (await run(2)) === "ok");

if (failures > 0) {
	console.log(`${failures} FAILED`);
	process.exit(1);
}
console.log("all ok");
