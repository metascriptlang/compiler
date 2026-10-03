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

const SYSTEM = address("11111111111111111111111111111111");
const TOKEN = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const ASSOCIATED = address("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
const encoder = getAddressEncoder();
const programPath = process.argv[2];
if (!programPath) {
	console.error("usage: node escrow.mjs <escrow.so>");
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

let failures = 0;

async function scenario(label, body) {
	const svm = new LiteSVM();
	const program = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(7));
	svm.addProgramFromFile(program.address, programPath);
	const maker = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
	const taker = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(2));
	const mintA = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(3))).address;
	const mintB = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(4))).address;
	svm.airdrop(maker.address, lamports(10_000_000_000n));
	svm.airdrop(taker.address, lamports(10_000_000_000n));
	const putToken = (key, data, rent) => svm.setAccount({
		address: key,
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

	async function send(step, payer, accounts, data, expected = null) {
		const instruction = { programAddress: program.address, accounts, data };
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
	}

	function amount(key) {
		const stored = svm.getAccount(key);
		if (!stored.exists) return null;
		return new DataView(stored.data.buffer, stored.data.byteOffset).getBigUint64(64, true);
	}

	function check(what, condition) {
		console.log(`[${label}] ${what}: ${condition ? "ok" : "FAILED"}`);
		if (!condition) failures++;
	}

	function gone(key) {
		const stored = svm.getAccount(key);
		return !stored.exists || stored.lamports === 0n;
	}

	const role = (key, accountRole, signer) => ({ address: key, role: accountRole, ...(signer ? { signer } : {}) });
	const readonly = (key) => role(key, AccountRole.READONLY);
	const writable = (key) => role(key, AccountRole.WRITABLE);

	async function escrowFor(seed) {
		const [found] = await getProgramDerivedAddress({
			programAddress: program.address,
			seeds: ["escrow", encoder.encode(maker.address), u64(seed)],
		});
		return found;
	}

	async function make(seed, deposit, receive, expected = null) {
		const escrow = await escrowFor(seed);
		const vault = await ata(escrow, mintA);
		await send(`make seed=${seed} deposit=${deposit}`, maker, [
			role(maker.address, AccountRole.WRITABLE_SIGNER, maker),
			readonly(mintA),
			readonly(mintB),
			writable(makerAtaA),
			writable(escrow),
			writable(vault),
			readonly(ASSOCIATED),
			readonly(TOKEN),
			readonly(SYSTEM),
		], concat(discriminator("make"), u64(seed), u64(deposit), u64(receive)), expected);
		return { escrow, vault };
	}

	await body({ maker, taker, mintA, mintB, makerAtaA, takerAtaA, takerAtaB, makerAtaB, make, send,
		role, readonly, writable, amount, check, gone });
}

await scenario("take", async (t) => {
	const { escrow, vault } = await t.make(7, 600, 300);
	t.check("vault holds the deposit", t.amount(vault) === 600n && t.amount(t.makerAtaA) === 400n);
	await t.send("take", t.taker, [
		t.role(t.taker.address, AccountRole.WRITABLE_SIGNER, t.taker),
		t.writable(t.maker.address),
		t.readonly(t.mintA),
		t.readonly(t.mintB),
		t.writable(t.takerAtaA),
		t.writable(t.takerAtaB),
		t.writable(t.makerAtaB),
		t.writable(escrow),
		t.writable(vault),
		t.readonly(TOKEN),
		t.readonly(SYSTEM),
	], discriminator("take"));
	t.check("taker received mint A", t.amount(t.takerAtaA) === 600n);
	t.check("maker received mint B", t.amount(t.makerAtaB) === 300n && t.amount(t.takerAtaB) === 200n);
	t.check("vault and escrow closed", t.gone(vault) && t.gone(escrow));
});

await scenario("refund", async (t) => {
	const { escrow, vault } = await t.make(9, 600, 300);
	await t.send("refund", t.maker, [
		t.role(t.maker.address, AccountRole.WRITABLE_SIGNER, t.maker),
		t.readonly(t.mintA),
		t.writable(t.makerAtaA),
		t.writable(escrow),
		t.writable(vault),
		t.readonly(TOKEN),
		t.readonly(SYSTEM),
	], discriminator("refund"));
	t.check("maker got the deposit back", t.amount(t.makerAtaA) === 1000n);
	t.check("vault and escrow closed", t.gone(vault) && t.gone(escrow));
});

await scenario("refused", async (t) => {
	await t.make(7, 0, 300, "6000");
});

if (failures > 0) {
	console.log(`${failures} failure(s)`);
	process.exit(1);
}
console.log("escrow: all LiteSVM scenarios passed");
