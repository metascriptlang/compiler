import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { FeatureSet, LiteSVM } from "litesvm";
import { AccountRole, address, appendTransactionMessageInstruction, createKeyPairSignerFromPrivateKeyBytes, createTransactionMessage, getBase58Encoder, lamports, pipe, setTransactionMessageFeePayerSigner, setTransactionMessageLifetimeUsingBlockhash, signTransactionMessageWithSigners } from "@solana/kit";
const base58 = getBase58Encoder();
const features = JSON.parse(readFileSync(new URL("./mainnetInactiveFeatures.json", import.meta.url), "utf8"));
const tag = (p, n) => new Uint8Array(createHash("sha256").update(p + n).digest().subarray(0, 8));
const programId = address("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32");
const petKey = address("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");
const set = FeatureSet.allEnabled(); for (const id of features.inactive) set.deactivate(new Uint8Array(base58.encode(id)));
const svm = new LiteSVM().withFeatureSet(set).withBuiltins().withSysvars().withDefaultPrograms();
svm.addProgramFromFile(programId, process.argv[2]);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(11));
svm.airdrop(payer.address, lamports(10_000_000_000n));
const ix = { programAddress: programId, accounts: [{ address: petKey, role: AccountRole.READONLY }], data: tag("global:", "read") };
const msg = pipe(createTransactionMessage({ version: 0 }), (m) => setTransactionMessageFeePayerSigner(payer, m), (m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m), (m) => appendTransactionMessageInstruction(ix, m));
const tx = await signTransactionMessageWithSigners(msg);
let checked = 0;
let maxValidCu = 0n;
function verify(data, expected, label) {
	svm.setAccount({ address: petKey, data, executable: false, lamports: lamports(1_000_000_000n), programAddress: programId, space: BigInt(data.length) });
	const r = svm.simulateTransaction(tx);
	const failed = r.constructor.name === "FailedTransactionMetadata";
	if (failed !== expected || (failed && !r.err().toString().includes("code: 3003"))) throw new Error(`${label}: ${failed ? r.err().toString() : "accepted"}`);
	if (!failed) {
		const expectedScore = (data[8] === 1 ? 100 : 0) + data.slice(10).reduce((sum, byte) => sum + byte, 0);
		const scoreLog = r.meta().logs().filter(line => line.startsWith("Program log: ")).at(-1);
		if (!scoreLog?.endsWith(`0x${expectedScore.toString(16)}`)) throw new Error(`${label}: wrong typed account score ${scoreLog}`);
		const cu = r.meta().computeUnitsConsumed();
		if (cu > 653n) throw new Error(`${label}: packed validation cost ${cu} CU exceeds 653`);
		if (cu > maxValidCu) maxValidCu = cu;
	}
	checked++;
}
for (let offset = 8; offset < 74; offset++) {
	for (let value = 0; value < 256; value++) {
		const data = new Uint8Array(74); data.set(tag("account:", "Pet"));
		for (let i = 8; i < 74; i++) data[i] = i === 8 ? 1 : i % 3;
		data[offset] = value;
		verify(data, value > (offset === 8 ? 1 : 2), `offset=${offset} value=${value}`);
	}
}
for (const value of [0, 1, 2, 3, 127, 128, 129, 254, 255]) {
	const data = new Uint8Array(74); data.set(tag("account:", "Pet")); data.fill(value, 8);
	verify(data, value > 1, `all=${value}`);
}
console.log(`${checked} raw-byte cases passed: all 256 values at every bool/enum position; mixed valid neighbours and full-lane carry boundaries; invalid bytes return 3003; max valid ${maxValidCu} CU.`);
