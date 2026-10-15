import {
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	appendTransactionMessageInstruction,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node logText.mjs <logTextProbe.so>   (msc build tools/solana/logTextProbe.ms --os=solana --release --output=logTextProbe.so)");
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

async function run(bytes) {
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts: [], data: Uint8Array.from(bytes) }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	const logs = meta.logs().filter((l) => l.startsWith("Program log:") || l.startsWith("Program data:"));
	return { ok: !failed, error: failed ? result.err().toString() : "", logs };
}

const text = (s) => [...Buffer.from(s)];
const wellFormed = [
	["ascii", text("hi")],
	["two bytes", text("é")],
	["three bytes", text("€")],
	["four bytes", text("😀")],
	["empty", []],
];
for (const [name, body] of wellFormed) {
	const outcome = await run([2, ...body]);
	check(`[${name}] well-formed text is logged as a Program log line`, outcome.ok && outcome.logs.length === 1 && outcome.logs[0] === `Program log: ${Buffer.from(body).toString()}`);
}

const malformed = [
	["stray lead byte", [0xff, 0xff]],
	["cut sequence", [0xe0, 0xa0]],
	["overlong two bytes", [0xc0, 0x80]],
	["surrogate", [0xed, 0xa0, 0x80]],
	["above U+10FFFF", [0xf4, 0x90, 0x80, 0x80]],
	["valid text then a stray continuation", [...text("ok"), 0x80]],
];
for (const [name, body] of malformed) {
	const outcome = await run([2, ...body]);
	check(`[${name}] the instruction still succeeds`, outcome.ok);
	check(`[${name}] the bytes are logged as a Program data line`, outcome.logs.length === 1 && outcome.logs[0] === `Program data: ${Buffer.from(body).toString("base64")}`);
}

if (failures > 0) {
	console.log(`${failures} FAILED`);
	process.exit(1);
}
console.log("all ok");
