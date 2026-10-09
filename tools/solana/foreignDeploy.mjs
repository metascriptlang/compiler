import { createHash } from "node:crypto";
import { LiteSVM } from "litesvm";
import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressEncoder,
	getProgramDerivedAddress,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { SUITES, SYSTEM, anchorTag, concat, mainnetFeatures, oracleAccounts, u64 } from "./anchorSuites.mjs";

// node foreignDeploy.mjs <label>=<dir> ...  (dir holds helloworld.so vault.so nested.so propAmm.so multisig.so)
// Each .so is loaded at its declared id D and at a fresh id X in one LiteSVM. A label named "before"
// expects the early id check (Custom(4100)) at X; any other label expects no check.
const ARTIFACT = { helloworld: "helloworld", vault: "vault", nested: "nested", "prop-amm": "propAmm", multisig: "multisig" };
const FOLDED = new Set(["helloworld/init", "nested/initialize"]);
const X = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(91))).address;

const OVER_EXISTING = { name: "initialize-over-D-oracle", foreignOnly: true, async build(ctx) {
	const x = await oracleAccounts(ctx, true);
	return { accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(x.oracle, true, true), ctx.meta(SYSTEM, false, false)],
		data: { anchor: anchorTag("initialize") } };
} };

const prefunded = (kase) => ({ ...kase, name: kase.name + "-prefunded", foreignOnly: true, async build(ctx) {
	const built = await kase.build(ctx);
	for (const m of built.accounts) if (m.writable && !m.signer && !ctx.svm.getAccount(m.account).exists) {
		ctx.svm.setAccount({ address: m.account, data: new Uint8Array(0), executable: false, lamports: lamports(1_000_000n), programAddress: SYSTEM, space: 0n });
	}
	return built;
} });

async function newWorld(path, ids) {
	const svm = new LiteSVM().withFeatureSet(mainnetFeatures()).withBuiltins().withSysvars().withDefaultPrograms();
	for (const id of ids) svm.addProgramFromFile(id, path);
	const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(11));
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	const signers = new Map([[payer.address, payer]]);
	return { svm, payer, signers, meta: (account, signer, writable) => ({ account, signer, writable }),
		async signer(seed) {
			const s = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed));
			if (!signers.has(s.address)) { signers.set(s.address, s); svm.airdrop(s.address, lamports(10_000_000n)); }
			return s;
		} };
}

async function send(ctx, programAddress, built, tag) {
	const instruction = { programAddress, data: built.data[tag], accounts: built.accounts.map((m) => ({
		address: m.account,
		role: m.signer ? (m.writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER)
			: (m.writable ? AccountRole.WRITABLE : AccountRole.READONLY),
		...(m.signer ? { signer: ctx.signers.get(m.account) } : {}) })) };
	const message = pipe(createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(ctx.payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: ctx.svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction(instruction, m));
	const result = ctx.svm.sendTransaction(await signTransactionMessageWithSigners(message));
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	return { failed, error: failed ? result.err().toString() : "ok", cu: Number(meta.computeUnitsConsumed()) };
}

function snapshot(svm, keys) {
	return JSON.stringify(keys.map((key) => {
		const a = svm.getAccount(key);
		return a.exists ? [key, a.programAddress, String(a.lamports), Buffer.from(a.data).toString("hex")] : [key, "absent"];
	}));
}

const keysOf = (built, ctx) => [...new Set(built.accounts.map((m) => m.account))].filter((k) => k !== ctx.payer.address && k !== SYSTEM);
const code = (error) => (/code: (\d+)/.exec(error)?.[1] ?? /error: (\w+)/.exec(error)?.[1] ?? error);


const TOKEN = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const ASSOCIATED = address("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
const ESCROW_ID = address("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");
const enc = getAddressEncoder();

async function escrowWorld(path, program, svm) {
	const key = async (seed) => (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed)));
	const maker = await key(1 + (program === X ? 100 : 0));
	const taker = await key(2 + (program === X ? 100 : 0));
	const mintA = (await key(3 + (program === X ? 100 : 0))).address;
	const mintB = (await key(4 + (program === X ? 100 : 0))).address;
	for (const s of [maker, taker]) svm.airdrop(s.address, lamports(10_000_000_000n));
	const put = (account, data, rent) => svm.setAccount({ address: account, data, executable: false, lamports: lamports(rent), programAddress: TOKEN, space: BigInt(data.length) });
	const mint = (authority) => { const d = new Uint8Array(82); d.set(u64(1).subarray(0, 4), 0); d.set(enc.encode(authority), 4); d.set(u64(1_000_000), 36); d[44] = 6; d[45] = 1; return d; };
	const tok = (m, owner, amount) => { const d = new Uint8Array(165); d.set(enc.encode(m), 0); d.set(enc.encode(owner), 32); d.set(u64(amount), 64); d[108] = 1; return d; };
	const ata = async (wallet, m) => (await getProgramDerivedAddress({ programAddress: ASSOCIATED, seeds: [enc.encode(wallet), enc.encode(TOKEN), enc.encode(m)] }))[0];
	put(mintA, mint(maker.address), 1_461_600n);
	put(mintB, mint(taker.address), 1_461_600n);
	const a = { makerAtaA: await ata(maker.address, mintA), takerAtaB: await ata(taker.address, mintB),
		takerAtaA: await ata(taker.address, mintA), makerAtaB: await ata(maker.address, mintB) };
	put(a.makerAtaA, tok(mintA, maker.address, 1000), 2_039_280n);
	put(a.takerAtaB, tok(mintB, taker.address, 500), 2_039_280n);
	put(a.takerAtaA, tok(mintA, taker.address, 0), 2_039_280n);
	put(a.makerAtaB, tok(mintB, maker.address, 0), 2_039_280n);
	const seed = 7;
	const [escrow] = await getProgramDerivedAddress({ programAddress: program, seeds: ["escrow", enc.encode(maker.address), u64(seed)] });
	const vault = await ata(escrow, mintA);
	const signers = new Map([[maker.address, maker], [taker.address, taker]]);
	const tag = (n) => new Uint8Array(createHash("sha256").update("global:" + n).digest().subarray(0, 8));
	const m = (account, signer, writable) => ({ account, signer, writable });
	const ix = {
		make: () => ({ accounts: [m(maker.address, true, true), m(mintA, false, false), m(mintB, false, false), m(a.makerAtaA, false, true), m(escrow, false, true), m(vault, false, true), m(ASSOCIATED, false, false), m(TOKEN, false, false), m(SYSTEM, false, false)],
			data: { anchor: concat(tag("make"), u64(seed), u64(600), u64(300)) } }),
		take: () => ({ accounts: [m(taker.address, true, true), m(maker.address, false, true), m(mintA, false, false), m(mintB, false, false), m(a.takerAtaA, false, true), m(a.takerAtaB, false, true), m(a.makerAtaB, false, true), m(escrow, false, true), m(vault, false, true), m(TOKEN, false, false), m(SYSTEM, false, false)],
			data: { anchor: tag("take") } }),
		refund: () => ({ accounts: [m(maker.address, true, true), m(mintA, false, false), m(a.makerAtaA, false, true), m(escrow, false, true), m(vault, false, true), m(TOKEN, false, false), m(SYSTEM, false, false)],
			data: { anchor: tag("refund") } }),
	};
	const amount = (k) => { const x = svm.getAccount(k); return x.exists ? new DataView(x.data.buffer, x.data.byteOffset).getBigUint64(64, true) : null; };
	return { maker, taker, signers, ix, escrow, vault, keys: [maker.address, taker.address, mintA, mintB, ...Object.values(a), escrow, vault], amount, a };
}

async function escrowRows(label, path, before) {
	const mk = () => { const svm = new LiteSVM(); svm.addProgramFromFile(ESCROW_ID, path); svm.addProgramFromFile(X, path); return svm; };
	const run = async (svm, w, program, name) => {
		const ctx = { svm, payer: name === "take" ? w.taker : w.maker, signers: w.signers };
		const r = await send(ctx, program, w.ix[name](), "anchor");
		svm.expireBlockhash();
		return r;
	};
	for (const name of ["take", "refund"]) {
		const svm = mk();
		const d = await escrowWorld(path, ESCROW_ID, svm);
		const made = await run(svm, d, ESCROW_ID, "make");
		const first = await run(svm, d, ESCROW_ID, name);
		const gone = (k) => { const a = svm.getAccount(k); return !a.exists || a.lamports === 0n; };
		const closed = gone(d.vault) && gone(d.escrow);
		row(label, `escrow/${name}`, "1 normal at D", first, "-", (x) => !made.failed && !x.failed && closed);
		const svm2 = mk();
		const d2 = await escrowWorld(path, ESCROW_ID, svm2);
		await run(svm2, d2, ESCROW_ID, "make");
		const watched2 = d2.keys.filter((k) => k !== (name === "take" ? d2.taker : d2.maker).address);
		const snap = snapshot(svm2, watched2);
		const xr = await run(svm2, d2, X, name);
		row(label, `escrow/${name}`, "2/3 D's accounts, call X", xr, snapshot(svm2, watched2) === snap, (x, u) => x.failed && u);
		const svm3 = mk();
		const d3 = await escrowWorld(path, ESCROW_ID, svm3);
		await run(svm3, d3, ESCROW_ID, "make");
		const watched3 = d3.keys.filter((k) => k !== d3.maker.address);
		const snapD = snapshot(svm3, watched3);
		const x3 = await escrowWorld(path, X, svm3);
		const m3 = await run(svm3, x3, X, "make");
		const t3 = m3.failed ? m3 : await run(svm3, x3, X, name);
		const gone3 = (k) => { const a = svm3.getAccount(k); return !a.exists || a.lamports === 0n; };
		const stateOk = !m3.failed && !t3.failed && gone3(x3.vault) && gone3(x3.escrow);
		row(label, `escrow/make+${name}`, "4 X's own accounts, call X", t3, snapshot(svm3, watched3) === snapD, (x, u) => u && (before ? m3.failed && code(m3.error) === "4100" : stateOk));
	}
}

let failures = 0;
const rows = [];
function row(label, name, scenario, r, unchanged, expectation) {
	const pass = expectation(r, unchanged);
	if (!pass) failures++;
	rows.push({ label, name, scenario, result: r.failed ? "refused " + code(r.error) : "ok", cu: r.cu, unchanged, pass });
}

for (const arg of process.argv.slice(2)) {
	const [label, dir] = arg.split("=");
	const before = label === "before";
	for (const suite of SUITES) {
		const path = `${dir}/${ARTIFACT[suite.name]}.so`;
		const D = address(suite.programId);
		const cases = [...suite.cases, ...(suite.name === "prop-amm" ? [OVER_EXISTING] : []),
			...suite.cases.filter((k) => FOLDED.has(`${suite.name}/${k.name}`)).map(prefunded)];
		for (const kase of cases) {
			const name = `${suite.name}/${kase.name}`;
			const folded = FOLDED.has(name);
			const createsForX = name === "prop-amm/initialize";
			const d = await newWorld(path, [D, X]);
			d.programId = D;
			const built = await kase.build(d);
			const watchedD = keysOf(built, d);
			if (!kase.foreignOnly) {
				const home = await newWorld(path, [D, X]);
				home.programId = D;
				const b = await kase.build(home);
				const r = await send(home, D, b, "anchor");
				let stateOk = !r.failed;
				if (stateOk && b.check) { try { b.check(); } catch { stateOk = false; } }
				row(label, name, "1 normal at D", r, "-", (x) => !x.failed && stateOk);
			}
			{
				const probe = await newWorld(path, [D, X]);
				probe.programId = X;
				const xKeys = keysOf(await kase.build(probe), probe);
				const watched = [...new Set([...watchedD, ...xKeys])];
				const payerBefore = d.svm.getAccount(d.payer.address).lamports;
				const snap = snapshot(d.svm, watched);
				const r = await send(d, X, built, "anchor");
				const delta = d.svm.getAccount(d.payer.address).lamports - payerBefore;
				const fee = 5000n * BigInt(new Set([d.payer.address, ...built.accounts.filter((m) => m.signer).map((m) => m.account)]).size);
				const same = snapshot(d.svm, watched) === snap && delta <= 0n && delta >= -fee;
				if (createsForX && !before) {
					const made = d.svm.getAccount(built.accounts[1].account);
					row(label, name, "2/3 D's accounts, call X", r, `${same} (creates an X-owned oracle on the caller's own keypair, nothing of D's)`,
						(x) => !x.failed && made.programAddress === X);
				} else row(label, name, "2/3 D's accounts, call X", r, same, (x, u) => x.failed && u);
			}
			if (!kase.foreignOnly) {
				const both = await newWorld(path, [D, X]);
				both.programId = D;
				const bd = await kase.build(both);
				const watched = keysOf(bd, both);
				const snap = snapshot(both.svm, watched);
				const own = Object.assign(Object.create(both), { programId: X, signer: (seed) => both.signer(seed === 7 ? seed : seed + 100) });
				const bx = await kase.build(own);
				const r = await send(own, X, bx, "anchor");
				let stateOk = !r.failed;
				if (stateOk && bx.check) { try { bx.check(); } catch { stateOk = false; } }
				const same = snapshot(both.svm, watched) === snap;
				row(label, name, "4 X's own accounts, call X", r, same, (x, u) => u && (before ? x.failed && code(x.error) === "4100"
					: folded ? x.failed : !x.failed && stateOk));
			}
		}
	}
}
for (const arg of process.argv.slice(2)) {
	const [label, dir] = arg.split("=");
	await escrowRows(label, `${dir}/escrow.so`, label === "before");
}
console.log(["label", "case", "scenario", "result", "CU", "D unchanged", "assert"].join("\t"));
for (const r of rows) console.log([r.label, r.name, r.scenario, r.result, r.cu, r.unchanged, r.pass ? "pass" : "FAIL"].join("\t"));
console.log(failures === 0 ? "foreignDeploy: all assertions hold" : `foreignDeploy: ${failures} assertion(s) FAILED`);
process.exit(failures === 0 ? 0 : 1);
