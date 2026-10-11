import { readFileSync } from "node:fs";
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

const [withPath, withoutPath] = process.argv.slice(2);
if (!withoutPath) {
	console.error("usage: node securityTxt.mjs <with-securityTxt.so> <without.so>   (a program whose entry takes no accounts and no data)");
	process.exit(2);
}

const BEGIN = Buffer.from("=======BEGIN SECURITY.TXT V1=======\0");
const END = Buffer.from("=======END SECURITY.TXT V1=======\0");

async function units(path) {
	const svm = new LiteSVM();
	const program = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
	svm.addProgramFromFile(program, path);
	const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts: [], data: new Uint8Array(0) }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	return { ok: !failed, units: Number(meta.computeUnitsConsumed()), bytes: readFileSync(path) };
}

const withBlock = await units(withPath);
const without = await units(withoutPath);
let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}
check("both programs run", withBlock.ok && without.ok);
check(`the compute units are equal (${withBlock.units} and ${without.units})`, withBlock.units === without.units);
check("the ELF with the block holds one block, the other none",
	withBlock.bytes.indexOf(BEGIN) >= 0 && withBlock.bytes.indexOf(BEGIN) === withBlock.bytes.lastIndexOf(BEGIN)
		&& withBlock.bytes.indexOf(END) > withBlock.bytes.indexOf(BEGIN) && without.bytes.indexOf(BEGIN) < 0);
process.exit(failures === 0 ? 0 : 1);
