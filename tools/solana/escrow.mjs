import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import anchor from "@coral-xyz/anchor";
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

const { BN, Program, parseIdlErrors, web3 } = anchor;
const SYSTEM = address("11111111111111111111111111111111");
const TOKEN = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const ASSOCIATED = address("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
const encoder = getAddressEncoder();
const [programPath, idlPath] = process.argv.slice(2);
if (!programPath || !idlPath) {
	console.error("usage: node escrow.mjs <escrow.so> <escrow-idl.json>");
	process.exit(2);
}

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

function discriminator(name) {
	return new Uint8Array(createHash("sha256").update("global:" + name).digest().subarray(0, 8));
}

function mintData(authority, decimals) {
	const data = new Uint8Array(82);
	data.set(u64(1).subarray(0, 4), 0);
	data.set(encoder.encode(authority), 4);
	data.set(u64(1_000_000), 36);
	data[44] = decimals;
	data[45] = 1;
	return data;
}

function tokenData(mint, owner, amount) {
	const data = new Uint8Array(165);
	data.set(encoder.encode(mint), 0);
	data.set(encoder.encode(owner), 32);
	data.set(u64(amount), 64);
	data[108] = 1;
	return data;
}

async function ata(wallet, mint) {
	const [found] = await getProgramDerivedAddress({
		programAddress: ASSOCIATED,
		seeds: [encoder.encode(wallet), encoder.encode(TOKEN), encoder.encode(mint)],
	});
	return found;
}

const key = (value) => new web3.PublicKey(value);
const hex = (bytes) => Buffer.from(bytes).toString("hex");

let failures = 0;
const idl = JSON.parse(readFileSync(idlPath, "utf8"));
// The program runs at the id its build declares (the IDL's address); an IDL without one gets a fixed key.
const programAddress = idl.address !== "" ? idl.address : (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(7))).address;
idl.address = programAddress;
const client = new Program(idl, { connection: new web3.Connection("http://127.0.0.1:1") });

async function scenario(label, body) {
	const svm = new LiteSVM();
	svm.addProgramFromFile(programAddress, programPath);
	const maker = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
	const taker = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(2));
	const mintA = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(3))).address;
	const mintB = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(4))).address;
	svm.airdrop(maker.address, lamports(10_000_000_000n));
	svm.airdrop(taker.address, lamports(10_000_000_000n));
	const putToken = (account, data, rent) => svm.setAccount({
		address: account,
		data,
		executable: false,
		lamports: lamports(rent),
		programAddress: TOKEN,
		space: BigInt(data.length),
	});
	putToken(mintA, mintData(maker.address, 6), 1_461_600n);
	putToken(mintB, mintData(taker.address, 6), 1_461_600n);
	const makerAtaA = await ata(maker.address, mintA);
	const takerAtaB = await ata(taker.address, mintB);
	const takerAtaA = await ata(taker.address, mintA);
	const makerAtaB = await ata(maker.address, mintB);
	putToken(makerAtaA, tokenData(mintA, maker.address, 1000), 2_039_280n);
	putToken(takerAtaB, tokenData(mintB, taker.address, 500), 2_039_280n);
	putToken(takerAtaA, tokenData(mintA, taker.address, 0), 2_039_280n);
	putToken(makerAtaB, tokenData(mintB, maker.address, 0), 2_039_280n);
	const signers = new Map([[maker.address, maker], [taker.address, taker]]);

	function check(what, condition) {
		console.log(`[${label}] ${what}: ${condition ? "ok" : "FAILED"}`);
		if (!condition) failures++;
	}

	async function send(step, payer, built, handMetas, handData, expected = null) {
		const metas = built.keys.map((meta) => ({
			address: address(meta.pubkey.toBase58()),
			signer: meta.isSigner,
			writable: meta.isWritable,
		}));
		check(`${step}: Anchor's accounts are the hand-built ones`, metas.length === handMetas.length
			&& metas.every((meta, i) => meta.address === handMetas[i].address
				&& meta.signer === handMetas[i].signer && meta.writable === handMetas[i].writable));
		check(`${step}: Anchor's data is the hand-built bytes`, hex(built.data) === hex(handData));
		const accounts = metas.map((meta) => ({
			address: meta.address,
			role: meta.signer
				? (meta.writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER)
				: (meta.writable ? AccountRole.WRITABLE : AccountRole.READONLY),
			...(meta.signer ? { signer: signers.get(meta.address) } : {}),
		}));
		const instruction = { programAddress: programAddress, accounts, data: new Uint8Array(built.data) };
		const message = pipe(
			createTransactionMessage({ version: 0 }),
			(m) => setTransactionMessageFeePayerSigner(payer, m),
			(m) => setTransactionMessageLifetimeUsingBlockhash(
				{ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n },
				m,
			),
			(m) => appendTransactionMessageInstruction(instruction, m),
		);
		const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
		svm.expireBlockhash();
		const failed = result.constructor.name === "FailedTransactionMetadata";
		const meta = failed ? result.meta() : result;
		const units = Number(meta.computeUnitsConsumed());
		const error = failed ? result.err().toString() : "";
		const passed = expected === null ? !failed : failed && error.includes(expected);
		console.log(`[${label}] ${step}: ${failed ? error : "ok"}, ${units} CU${passed ? "" : "  <-- FAILED"}`);
		if (!passed) {
			console.log(meta.logs().join("\n"));
			failures++;
		}
		return error;
	}

	function amount(account) {
		const stored = svm.getAccount(account);
		if (!stored.exists) return null;
		return new DataView(stored.data.buffer, stored.data.byteOffset).getBigUint64(64, true);
	}

	function gone(account) {
		const stored = svm.getAccount(account);
		return !stored.exists || stored.lamports === 0n;
	}

	const meta = (account, writable, signer = false) => ({ address: account, writable, signer });

	async function make(seed, deposit, receive, expected = null) {
		const [escrow, bump] = await getProgramDerivedAddress({
			programAddress: programAddress,
			seeds: ["escrow", encoder.encode(maker.address), u64(seed)],
		});
		const vault = await ata(escrow, mintA);
		const built = await client.methods.make(new BN(seed), new BN(deposit), new BN(receive)).accountsStrict({
			maker: key(maker.address),
			mintA: key(mintA),
			mintB: key(mintB),
			makerAtaA: key(makerAtaA),
			escrow: key(escrow),
			vault: key(vault),
			associatedTokenProgram: key(ASSOCIATED),
			tokenProgram: key(TOKEN),
			systemProgram: key(SYSTEM),
		}).instruction();
		const error = await send(`make seed=${seed} deposit=${deposit}`, maker, built, [
			meta(maker.address, true, true),
			meta(mintA, false),
			meta(mintB, false),
			meta(makerAtaA, true),
			meta(escrow, true),
			meta(vault, true),
			meta(ASSOCIATED, false),
			meta(TOKEN, false),
			meta(SYSTEM, false),
		], concat(discriminator("make"), u64(seed), u64(deposit), u64(receive)), expected);
		return { escrow, vault, bump, error };
	}

	await body({ svm, maker, taker, mintA, mintB, makerAtaA, takerAtaA, takerAtaB, makerAtaB, make, send,
		meta, amount, check, gone });
}

await scenario("take", async (t) => {
	const { escrow, vault, bump } = await t.make(7, 600, 300);
	t.check("vault holds the deposit", t.amount(vault) === 600n && t.amount(t.makerAtaA) === 400n);
	const stored = t.svm.getAccount(escrow);
	const state = client.coder.accounts.decode("escrow", Buffer.from(stored.data));
	t.check("Anchor decodes the escrow account", state.seed.toString() === "7"
		&& state.maker.toBase58() === t.maker.address && state.mintA.toBase58() === t.mintA
		&& state.mintB.toBase58() === t.mintB && state.receive.toString() === "300" && state.bump === bump);
	const filter = client.coder.accounts.memcmp("escrow");
	t.check("Anchor's account filter is the stored discriminator",
		hex(anchor.utils.bytes.bs58.decode(filter.bytes)) === hex(stored.data.subarray(0, 8)));
	const built = await client.methods.take().accountsStrict({
		taker: key(t.taker.address),
		maker: key(t.maker.address),
		mintA: key(t.mintA),
		mintB: key(t.mintB),
		takerAtaA: key(t.takerAtaA),
		takerAtaB: key(t.takerAtaB),
		makerAtaB: key(t.makerAtaB),
		escrow: key(escrow),
		vault: key(vault),
		tokenProgram: key(TOKEN),
		systemProgram: key(SYSTEM),
	}).instruction();
	await t.send("take", t.taker, built, [
		t.meta(t.taker.address, true, true),
		t.meta(t.maker.address, true),
		t.meta(t.mintA, false),
		t.meta(t.mintB, false),
		t.meta(t.takerAtaA, true),
		t.meta(t.takerAtaB, true),
		t.meta(t.makerAtaB, true),
		t.meta(escrow, true),
		t.meta(vault, true),
		t.meta(TOKEN, false),
		t.meta(SYSTEM, false),
	], discriminator("take"));
	t.check("taker received mint A", t.amount(t.takerAtaA) === 600n);
	t.check("maker received mint B", t.amount(t.makerAtaB) === 300n && t.amount(t.takerAtaB) === 200n);
	t.check("vault and escrow closed", t.gone(vault) && t.gone(escrow));
});

await scenario("refund", async (t) => {
	const { escrow, vault } = await t.make(9, 600, 300);
	const built = await client.methods.refund().accountsStrict({
		maker: key(t.maker.address),
		mintA: key(t.mintA),
		makerAtaA: key(t.makerAtaA),
		escrow: key(escrow),
		vault: key(vault),
		tokenProgram: key(TOKEN),
		systemProgram: key(SYSTEM),
	}).instruction();
	await t.send("refund", t.maker, built, [
		t.meta(t.maker.address, true, true),
		t.meta(t.mintA, false),
		t.meta(t.makerAtaA, true),
		t.meta(escrow, true),
		t.meta(vault, true),
		t.meta(TOKEN, false),
		t.meta(SYSTEM, false),
	], discriminator("refund"));
	t.check("maker got the deposit back", t.amount(t.makerAtaA) === 1000n);
	t.check("vault and escrow closed", t.gone(vault) && t.gone(escrow));
});

await scenario("constraints", async (t) => {
	const { escrow, vault } = await t.make(7, 600, 300);
	const stored = t.svm.getAccount(escrow);
	const takeBuilt = () => client.methods.take().accountsStrict({
		taker: key(t.taker.address),
		maker: key(t.maker.address),
		mintA: key(t.mintA),
		mintB: key(t.mintB),
		takerAtaA: key(t.takerAtaA),
		takerAtaB: key(t.takerAtaB),
		makerAtaB: key(t.makerAtaB),
		escrow: key(escrow),
		vault: key(vault),
		tokenProgram: key(TOKEN),
		systemProgram: key(SYSTEM),
	}).instruction();
	const takeMetas = [
		t.meta(t.taker.address, true, true),
		t.meta(t.maker.address, true),
		t.meta(t.mintA, false),
		t.meta(t.mintB, false),
		t.meta(t.takerAtaA, true),
		t.meta(t.takerAtaB, true),
		t.meta(t.makerAtaB, true),
		t.meta(escrow, true),
		t.meta(vault, true),
		t.meta(TOKEN, false),
		t.meta(SYSTEM, false),
	];
	const corrupt = (label, at, code) => async () => {
		const data = new Uint8Array(stored.data);
		data[at] ^= 1;
		t.svm.setAccount({
			address: escrow,
			data,
			executable: false,
			lamports: stored.lamports,
			programAddress: stored.programAddress,
			space: BigInt(data.length),
		});
		await t.send(label, t.taker, await takeBuilt(), takeMetas, discriminator("take"), `code: ${code}`);
	};
	const SEED = 8, MAKER = 16, MINT_A = 48, MINT_B = 80, BUMP = 120;
	await corrupt("take with the escrow naming another maker (has_one)", MAKER + 31, 2001)();
	await corrupt("take with the escrow naming another mint A (has_one)", MINT_A + 31, 2001)();
	await corrupt("take with the escrow naming another mint B (has_one)", MINT_B + 31, 2001)();
	await corrupt("take with another stored bump (seeds)", BUMP, 2006)();
	await corrupt("take with another stored seed (seeds)", SEED, 2006)();
	t.svm.setAccount({
		address: t.takerAtaB,
		data: tokenData(t.mintB, t.maker.address, 500),
		executable: false,
		lamports: lamports(2_039_280n),
		programAddress: TOKEN,
		space: 165n,
	});
	await t.send("take with a token account of another authority (token owner)", t.taker, await takeBuilt(), takeMetas, discriminator("take"), "code: 2015");
	t.svm.setAccount({
		address: t.takerAtaB,
		data: tokenData(t.mintB, t.taker.address, 500),
		executable: false,
		lamports: lamports(2_039_280n),
		programAddress: TOKEN,
		space: 165n,
	});
	const stranger = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
	t.svm.setAccount({
		address: stranger,
		data: tokenData(t.mintB, t.maker.address, 0),
		executable: false,
		lamports: lamports(2_039_280n),
		programAddress: TOKEN,
		space: 165n,
	});
	const movedMetas = takeMetas.map((meta) => meta.address === t.makerAtaB ? t.meta(stranger, true) : meta);
	const moved = await client.methods.take().accountsStrict({
		taker: key(t.taker.address),
		maker: key(t.maker.address),
		mintA: key(t.mintA),
		mintB: key(t.mintB),
		takerAtaA: key(t.takerAtaA),
		takerAtaB: key(t.takerAtaB),
		makerAtaB: key(stranger),
		escrow: key(escrow),
		vault: key(vault),
		tokenProgram: key(TOKEN),
		systemProgram: key(SYSTEM),
	}).instruction();
	await t.send("take with a token account off the associated address (associated)", t.taker, moved, movedMetas, discriminator("take"), "code: 2009");
});

await scenario("refused", async (t) => {
	const { error } = await t.make(7, 0, 300, "6000");
	const code = Number(/code: (\d+)/.exec(error)?.[1]);
	t.check(`Anchor names custom error ${code}`, parseIdlErrors(client.idl).get(code) === "ZeroAmount");
});

if (failures > 0) {
	console.log(`${failures} failure(s)`);
	process.exit(1);
}
console.log("escrow: all LiteSVM scenarios passed, every instruction built by Anchor's client from the IDL");
