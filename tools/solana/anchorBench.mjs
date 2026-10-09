import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { LiteSVM } from "litesvm";
import {
	AccountRole,
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
import { SUITES, SYSTEM, mainnetFeatures } from "./anchorSuites.mjs";

function accountSnapshot(svm, keys) {
	return keys.map(key => {
		const account = svm.getAccount(key);
		return account?.data ? { key, owner: account.owner ?? account.programAddress,
			lamports: String(account.lamports), data: Buffer.from(account.data).toString("hex") } : { key };
	});
}

const faults = process.env.BENCH_REFUSALS ? [
	"empty-data", "unknown-tag", "readonly", "missing-signer", "wrong-owner", "bad-discriminator", "wrong-program-id",
	"missing-account", "short-args", "bad-utf8", "label-too-long", "invalid-threshold",
] : [];

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
	const states = {};
	const refusals = [];
	for (const kase of suite.cases) for (const fault of [null, ...faults]) {
		const svm = new LiteSVM().withFeatureSet(mainnetFeatures()).withBuiltins().withSysvars().withDefaultPrograms();
		const programId = address(suite.programId);
		const callee = fault === "wrong-program-id"
			? (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(91))).address
			: programId;
		svm.addProgramFromFile(programId, variant.path);
		if (callee !== programId) svm.addProgramFromFile(callee, variant.path);
		const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(11));
		svm.airdrop(payer.address, lamports(10_000_000_000n));
		const signers = new Map([[payer.address, payer]]);
		const ctx = {
			svm,
			programId,
			payer,
			meta: (account, signer, writable) => ({ account, signer, writable }),
			async signer(seed) {
				const signer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed));
				if (!signers.has(signer.address)) {
					signers.set(signer.address, signer);
					svm.airdrop(signer.address, lamports(10_000_000n));
				}
				return signer;
			},
		};
		const built = await kase.build(ctx);
		const originalKeys = built.accounts.map(m => m.account);
		let data = built.data[variant.encoding];
		if (!data) {
			console.log(`FAIL ${variant.suite}:${variant.label} ${kase.name}: no ${variant.encoding} encoding`);
			failures++;
			continue;
		}
		if (fault === "empty-data") data = new Uint8Array(0);
		if (fault === "unknown-tag") {
			data = new Uint8Array(data);
			data.fill(255, 0, variant.encoding === "anchor" ? 8 : 1);
		}
		if (fault === "readonly") {
			const account = built.accounts.find(m => m.writable && m.account !== payer.address);
			if (!account) continue;
			account.writable = false;
		}
		if (fault === "missing-signer") {
			const account = built.accounts.find(m => m.signer);
			if (!account) continue;
			account.account = (await ctx.signer(42)).address;
			account.signer = false;
		}
		if (fault === "wrong-owner" || fault === "bad-discriminator") {
			const meta = built.accounts.find(m => {
				const account = svm.getAccount(m.account);
				return account?.data && account.data.length > 0 && (account.owner ?? account.programAddress) === programId;
			});
			if (!meta) continue;
			const account = svm.getAccount(meta.account);
			const bytes = new Uint8Array(account.data);
			if (fault === "bad-discriminator") bytes[0] ^= 255;
			svm.setAccount({ address: meta.account, data: bytes, executable: false,
				lamports: lamports(account.lamports), programAddress: fault === "wrong-owner" ? SYSTEM : programId, space: BigInt(bytes.length) });
		}
		if (fault === "wrong-program-id" && suite.name === "prop-amm" && kase.name === "initialize") continue;
		if (fault === "missing-account") built.accounts = [];
		if (fault === "short-args") {
			if (data.length <= (variant.encoding === "anchor" ? 8 : 1)) continue;
			data = data.slice(0, -1);
		}
		if (fault === "bad-utf8" || fault === "label-too-long") {
			if (suite.name !== "multisig" || kase.name !== "set_label") continue;
			data = new Uint8Array(data);
			const prefix = variant.encoding === "anchor" ? 8 : 1;
			if (fault === "bad-utf8") data[prefix + 1] = 0xc0;
			else data[prefix] = 33;
		}
		if (fault === "invalid-threshold") {
			if (suite.name !== "multisig" || kase.name !== "create") continue;
			data = new Uint8Array(data);
			data[variant.encoding === "anchor" ? 8 : 1] = 0;
		}
		const watched = [...new Set([...originalKeys, ...built.accounts.map(m => m.account)]
			.filter(key => key !== payer.address && key !== SYSTEM))];
		const before = accountSnapshot(svm, watched);
		const instruction = {
			programAddress: callee,
			accounts: built.accounts.map((m) => ({
				address: m.account,
				role: m.signer
					? (m.writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER)
					: (m.writable ? AccountRole.WRITABLE : AccountRole.READONLY),
				...(m.signer ? { signer: signers.get(m.account) } : {}),
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
		if (fault) {
			const unchanged = JSON.stringify(before) === JSON.stringify(accountSnapshot(svm, watched));
			refusals.push({ instruction: kase.name, fault, refused: failed, unchanged,
				cu: Number(meta.computeUnitsConsumed()), error: failed ? result.err().toString() : null });
			if (!failed || !unchanged) {
				console.log(`FAIL ${variant.suite}:${variant.label} ${kase.name}/${fault}: refused=${failed} unchanged=${unchanged}`);
				failures++;
			}
			continue;
		}
		units[kase.name] = Number(meta.computeUnitsConsumed());
		if (!failed) states[kase.name] = accountSnapshot(svm, watched);
		if (process.env.BENCH_LOGS) console.log(`--- ${variant.suite}:${variant.label} ${kase.name}\n${meta.logs().join("\n")}`);
		if (!failed && built.check) {
			try { built.check(); }
			catch (error) {
				console.log(`FAIL ${variant.suite}:${variant.label} ${kase.name} state: ${error.message}`);
				failures++;
			}
		}
		if (failed) {
			console.log(`FAIL ${variant.suite}:${variant.label} ${kase.name}: ${result.err().toString()}`);
			console.log(meta.logs().join("\n"));
			failures++;
		}
	}
	rows.push({ suite: variant.suite, label: variant.label, encoding: variant.encoding,
		artifact: variant.path, sha256: createHash("sha256").update(readFileSync(variant.path)).digest("hex"),
		bytes: statSync(variant.path).size, units, states, refusals });
}

for (const row of rows) {
	const control = rows.find(candidate => candidate.suite === row.suite);
	if (JSON.stringify(control.states) !== JSON.stringify(row.states)) {
		console.log(`FAIL ${row.suite}:${row.label}: success account bytes/owner/lamports differ from ${control.label}`);
		failures++;
	}
	const cu = Object.entries(row.units).map(([k, v]) => `${k} ${v}`).join(", ");
	console.log(`${row.suite.padEnd(11)} ${row.label.padEnd(10)} ${String(row.bytes).padStart(7)} B  ${cu}`);
}
if (process.env.BENCH_JSON) writeFileSync(process.env.BENCH_JSON,
	JSON.stringify({ features: "mainnetInactiveFeatures.json", failures, rows }, null, 2) + "\n");
process.exit(failures === 0 ? 0 : 1);
