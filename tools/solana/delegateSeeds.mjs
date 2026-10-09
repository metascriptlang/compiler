import { LiteSVM } from "litesvm";
import {
	AccountRole, address, appendTransactionMessageInstruction, createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage, getAddressEncoder, getProgramDerivedAddress, lamports, pipe,
	setTransactionMessageFeePayerSigner, setTransactionMessageLifetimeUsingBlockhash, signTransactionMessageWithSigners,
} from "@solana/kit";
import { SYSTEM, mainnetFeatures } from "./anchorSuites.mjs";

// node delegateSeeds.mjs <dlp.so> <label>=<delegateSeedsProbe.so> ...  (dlp.so: solana program dump DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh dlp.so -um)
// Each build delegates a pet whose seed ["pet", mint] has the mint in
// the pet's own data (shape 0) and in a local copy (shape 1), against the mainnet delegation program.
const DLP = address("DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh");
const enc = getAddressEncoder();
const key = async (seed) => createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed));
const pda = async (programAddress, seeds) => getProgramDerivedAddress({ programAddress, seeds });

async function once(path, shape) {
	const svm = new LiteSVM().withFeatureSet(mainnetFeatures()).withBuiltins().withSysvars().withDefaultPrograms();
	const program = (await key(42)).address;
	svm.addProgramFromFile(program, path);
	svm.addProgramFromFile(DLP, DLP_SO);
	const payer = await key(11);
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	const mint = enc.encode((await key(7)).address);
	const [pet, bump] = await pda(program, ["pet", mint]);
	svm.setAccount({ address: pet, data: new Uint8Array(mint), executable: false, lamports: lamports(1_113_600n), programAddress: program, space: 32n });
	const [buffer] = await pda(program, ["buffer", enc.encode(pet)]);
	const [record] = await pda(DLP, ["delegation", enc.encode(pet)]);
	const [metadata] = await pda(DLP, ["delegation-metadata", enc.encode(pet)]);
	const meta = (a, role, signer) => ({ address: a, role, ...(signer ? { signer } : {}) });
	const instruction = { programAddress: program, data: new Uint8Array([shape, bump]), accounts: [
		meta(payer.address, AccountRole.WRITABLE_SIGNER, payer), meta(pet, AccountRole.WRITABLE),
		meta(program, AccountRole.READONLY), meta(buffer, AccountRole.WRITABLE), meta(record, AccountRole.WRITABLE),
		meta(metadata, AccountRole.WRITABLE), meta(SYSTEM, AccountRole.READONLY), meta(DLP, AccountRole.READONLY)] };
	const message = pipe(createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction(instruction, m));
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const m = failed ? result.meta() : result;
	const after = svm.getAccount(pet);
	const rec = svm.getAccount(metadata);
	const seedsKept = rec.exists && Buffer.from(rec.data).includes(Buffer.from(mint));
	const logs = m.logs().filter((l) => /failed|error|Error|consumed/.test(l)).slice(-3);
	return { outcome: failed ? result.err().toString() : "ok", cu: Number(m.computeUnitsConsumed()),
		owner: after.programAddress === DLP ? "DLP" : after.programAddress, seedsKept, logs };
}

const DLP_SO = process.argv[2];
for (const arg of process.argv.slice(3)) {
	const [label, path] = arg.split("=");
	for (const shape of [0, 1]) {
		const r = await once(path, shape);
		console.log(`${label} ${shape === 0 ? "seed-in-account" : "seed-local    "} ${r.outcome.padEnd(40).slice(0, 60)} cu=${r.cu} owner=${r.owner} seedsInMetadata=${r.seedsKept}`);
		if (r.outcome !== "ok") for (const l of r.logs) console.log("    " + l.slice(0, 160));
	}
}
