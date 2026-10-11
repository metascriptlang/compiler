import { readFileSync } from "node:fs";
import { BN, BorshInstructionCoder } from "@coral-xyz/anchor";
import { LiteSVM } from "litesvm";
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

const [programPath, idlPath] = process.argv.slice(2);
if (!programPath || !idlPath) {
	throw new Error("usage: node fixedArgumentArrays.mjs <solanaFixedArgumentArrays.so> <idl.json>");
}
const idl = JSON.parse(readFileSync(idlPath, "utf8"));
const coder = new BorshInstructionCoder(idl);
const programId = address(idl.address);
const svm = new LiteSVM().withBuiltins().withSysvars().withDefaultPrograms();
svm.addProgramFromFile(programId, programPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(11));
svm.airdrop(payer.address, lamports(10_000_000_000n));
const full = new Uint8Array(87);
full[8] = 1;
for (let i = 1; i <= 77; i++) full[8 + i] = i;
full[86] = 1;
const fields = [["empty", 0], ["one", 1], ["four", 4], ["eight", 8], ["near_key", 31], ["past_key", 33]];
function clientEncoding(data) {
	const input = { prefix: data[8] === 1, last: data[86] === 1 };
	let offset = 9;
	for (const [name, length] of fields) {
		input[name] = Array.from(data.slice(offset, offset + length));
		offset += length;
	}
	return coder.encode("read", input);
}
full.set(clientEncoding(full).slice(0, 8));
let cases = 0;
let maxValidCu = 0n;

const scalarInput = {
	prefix: 5, u8: [1, 2], u16: [1, 2], u32: [1, 2], u64: [new BN(1), new BN(2)],
	i8: [-1, 2], i16: [-1, 2], i32: [-1, 2], i64: [new BN(-1), new BN(2)],
	flags: [true, false], last: 7,
};

async function check(data, rejected, label, name = "read") {
	let wire = data;
	if (!rejected) {
		wire = name === "read" ? clientEncoding(data) : coder.encode(name, scalarInput);
		if (!wire.equals(Buffer.from(data))) throw new Error(`${label}: Anchor wire differs`);
	}
	const instruction = { programAddress: programId, accounts: [], data: wire };
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		m => setTransactionMessageFeePayerSigner(payer, m),
		m => setTransactionMessageLifetimeUsingBlockhash({
			blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n,
		}, m),
		m => appendTransactionMessageInstruction(instruction, m),
	);
	const transaction = await signTransactionMessageWithSigners(message);
	const result = svm.simulateTransaction(transaction);
	const failed = result.constructor.name === "FailedTransactionMetadata";
	if (failed !== rejected) throw new Error(`${label}: ${failed ? result.err() : "unexpected acceptance"}`);
	if (rejected) {
		if (!result.err().toString().includes("code: 102")) throw new Error(`${label}: ${result.err()}`);
	} else {
		const score = name === "scalar" ? 29 : data[8] + data[86] * 1000 +
			data.slice(9, 86).reduce((sum, byte, index) => sum + byte * (index + 1), 0);
		if (!result.meta().logs().some(line => line.endsWith(`0x${score.toString(16)}`))) {
			throw new Error(`${label}: wrong checksum`);
		}
		const units = result.meta().computeUnitsConsumed();
		if (units > maxValidCu) maxValidCu = units;
	}
	cases++;
}

for (let length = 0; length < full.length; length++) {
	await check(full.slice(0, length), true, `length=${length}`);
}
for (const first of [0, 1]) for (const last of [0, 1]) {
	const data = full.slice();
	data[8] = first;
	data[86] = last;
	await check(data, false, `flags=${first},${last}`);
}
for (const offset of [8, 86]) for (let byte = 2; byte < 256; byte++) {
	const data = full.slice();
	data[offset] = byte;
	await check(data, true, `bool offset=${offset} byte=${byte}`);
}
for (const offset of [9, 12, 13, 20, 21, 52, 53, 85]) for (let byte = 0; byte < 256; byte++) {
	const data = full.slice();
	data[offset] = byte;
	await check(data, false, `byte offset=${offset} byte=${byte}`);
}
const scalar = coder.encode("scalar", scalarInput);
for (let length = 0; length < scalar.length; length++) {
	await check(scalar.slice(0, length), true, `scalar length=${length}`, "scalar");
}
for (const offset of [69, 70]) for (let byte = 2; byte < 256; byte++) {
	const data = scalar.slice();
	data[offset] = byte;
	await check(data, true, `scalar bool offset=${offset} byte=${byte}`, "scalar");
}
await check(scalar, false, "scalar signed/unsigned/bool", "scalar");
console.log(JSON.stringify({
	cases, maxValidCu: maxValidCu.toString(), sizes: [0, 1, 4, 8, 31, 33],
	client: "Anchor BorshInstructionCoder from generated IDL; exact wire",
}));
