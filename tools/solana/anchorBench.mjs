import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { FeatureSet, LiteSVM } from "litesvm";
import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressEncoder,
	getBase58Encoder,
	getProgramDerivedAddress,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";

const SYSTEM = address("11111111111111111111111111111111");
const encoder = getAddressEncoder();
const base58 = getBase58Encoder();
const features = JSON.parse(readFileSync(new URL("./mainnetInactiveFeatures.json", import.meta.url), "utf8"));

function u64(value) {
	const bytes = new Uint8Array(8);
	new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true);
	return bytes;
}

function concat(...parts) {
	const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
	let offset = 0;
	for (const part of parts) {
		out.set(part, offset);
		offset += part.length;
	}
	return out;
}

const anchorTag = (name) => new Uint8Array(createHash("sha256").update("global:" + name).digest().subarray(0, 8));
const byteTag = (n) => new Uint8Array([n]);

function mainnetFeatures() {
	const set = FeatureSet.allEnabled();
	for (const id of features.inactive) set.deactivate(new Uint8Array(base58.encode(id)));
	return set;
}

const SUITES = [
	{
		name: "helloworld",
		programId: "B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32",
		cases: [{
			name: "init",
			async build(ctx) {
				const [counter] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["counter"] });
				return {
					accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(counter, false, true), ctx.meta(SYSTEM, false, false)],
					data: { anchor: anchorTag("init"), pinocchio: new Uint8Array(0) },
				};
			},
		}],
	},
	{
		name: "vault",
		programId: "33333333333333333333333333333333333333333333",
		cases: [
			{
				name: "deposit",
				async build(ctx) {
					const [vault] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["vault", encoder.encode(ctx.payer.address)] });
					return {
						accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(vault, false, true), ctx.meta(SYSTEM, false, false)],
						data: { anchor: concat(anchorTag("deposit"), u64(1_000_000)), byte: concat(byteTag(0), u64(1_000_000)) },
					};
				},
			},
			{
				name: "withdraw",
				async build(ctx) {
					const [vault] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["vault", encoder.encode(ctx.payer.address)] });
					ctx.svm.setAccount({ address: vault, data: new Uint8Array(0), executable: false, lamports: lamports(1_000_000_000n), programAddress: ctx.programId, space: 0n });
					return {
						accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(vault, false, true)],
						data: { anchor: concat(anchorTag("withdraw"), u64(1_000_000)), byte: concat(byteTag(1), u64(1_000_000)) },
					};
				},
			},
		],
	},
];

const variants = process.argv.slice(2).map((arg) => {
	const [suite, label, encoding, path] = arg.split(":");
	return { suite, label, encoding, path };
});
if (variants.length === 0) {
	console.error("usage: node anchorBench.mjs <suite>:<label>:<anchor|byte|pinocchio>:<program.so> ...");
	process.exit(2);
}

let failures = 0;
const rows = [];
for (const variant of variants) {
	const suite = SUITES.find((s) => s.name === variant.suite);
	if (!suite || !existsSync(variant.path)) {
		console.log(`FAIL ${variant.suite}:${variant.label}: no suite or no program at ${variant.path}`);
		failures++;
		continue;
	}
	const units = {};
	for (const kase of suite.cases) {
		const svm = new LiteSVM().withFeatureSet(mainnetFeatures()).withBuiltins().withSysvars().withDefaultPrograms();
		const programId = address(suite.programId);
		svm.addProgramFromFile(programId, variant.path);
		const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(11));
		svm.airdrop(payer.address, lamports(10_000_000_000n));
		const ctx = {
			svm,
			programId,
			payer,
			meta: (account, signer, writable) => ({ account, signer, writable }),
		};
		const built = await kase.build(ctx);
		const data = built.data[variant.encoding];
		if (!data) {
			console.log(`FAIL ${variant.suite}:${variant.label} ${kase.name}: no ${variant.encoding} encoding`);
			failures++;
			continue;
		}
		const instruction = {
			programAddress: programId,
			accounts: built.accounts.map((m) => ({
				address: m.account,
				role: m.signer
					? (m.writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER)
					: (m.writable ? AccountRole.WRITABLE : AccountRole.READONLY),
				...(m.signer ? { signer: payer } : {}),
			})),
			data,
		};
		const message = pipe(
			createTransactionMessage({ version: 0 }),
			(m) => setTransactionMessageFeePayerSigner(payer, m),
			(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
			(m) => appendTransactionMessageInstruction(instruction, m),
		);
		const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
		const failed = result.constructor.name === "FailedTransactionMetadata";
		const meta = failed ? result.meta() : result;
		units[kase.name] = Number(meta.computeUnitsConsumed());
		if (failed) {
			console.log(`FAIL ${variant.suite}:${variant.label} ${kase.name}: ${result.err().toString()}`);
			console.log(meta.logs().join("\n"));
			failures++;
		}
	}
	rows.push({ suite: variant.suite, label: variant.label, bytes: statSync(variant.path).size, units });
}

for (const row of rows) {
	const cu = Object.entries(row.units).map(([k, v]) => `${k} ${v}`).join(", ");
	console.log(`${row.suite.padEnd(11)} ${row.label.padEnd(10)} ${String(row.bytes).padStart(7)} B  ${cu}`);
}
process.exit(failures === 0 ? 0 : 1);
