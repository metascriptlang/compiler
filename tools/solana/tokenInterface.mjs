import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressEncoder,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node tokenInterface.mjs <tokenInterfaceProbe.so>   (msc build tools/solana/tokenInterfaceProbe.ms --os=solana --release --output=tokenInterfaceProbe.so)");
	process.exit(2);
}

const TOKEN = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const TOKEN_2022 = address("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
const encoder = getAddressEncoder();
const OP = { mint: 0, interfaceMint: 1, tokenAccount: 2, interfaceTokenAccount: 3, transferLegacy: 4, transferInterface: 5 };
const WRONG_PROGRAM = 3007;
const DID_NOT_DESERIALIZE = 3003;
const UNSUPPORTED = 4200;
const MINT_LENGTH = { 1: 108, 3: 32, 4: 65, 6: 1, 9: 0, 10: 52, 12: 32, 14: 64, 16: 96, 18: 64, 19: 80, 20: 64, 21: 80, 22: 64, 23: 72, 24: 130, 25: 56, 26: 33 };
const ACCOUNT_LENGTH = { 2: 8, 5: 295, 7: 0, 8: 1, 11: 1, 13: 0, 15: 1, 17: 8, 27: 0 };

const keypair = (seed) => createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed));
const program = (await keypair(9)).address;
const payer = await keypair(1);
const owner = await keypair(2);

function u16(value) {
	const bytes = new Uint8Array(2);
	new DataView(bytes.buffer).setUint16(0, value, true);
	return bytes;
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

function table(kinds, lengths, fill = {}) {
	return concat(...kinds.map((kind) => {
		const payload = new Uint8Array(lengths[kind]);
		if (fill[kind]) payload.set(fill[kind]);
		return concat(u16(kind), u16(lengths[kind]), payload);
	}));
}

function mintData(kinds, supply = 1000, fill = {}) {
	const tlv = table(kinds, MINT_LENGTH, fill);
	const data = new Uint8Array(kinds.length === 0 ? 82 : 166 + tlv.length);
	data[0] = 1;
	data.set(encoder.encode(owner.address), 4);
	data.set(u64(supply), 36);
	data[44] = 6;
	data[45] = 1;
	if (kinds.length > 0) {
		data[165] = 1;
		data.set(tlv, 166);
	}
	return data;
}

function accountData(mint, holder, amount, kinds = [], fill = {}) {
	const tlv = table(kinds, ACCOUNT_LENGTH, fill);
	const data = new Uint8Array(kinds.length === 0 ? 165 : 166 + tlv.length);
	data.set(encoder.encode(mint), 0);
	data.set(encoder.encode(holder), 32);
	data.set(u64(amount), 64);
	data[108] = 1;
	if (kinds.length > 0) {
		data[165] = 2;
		data.set(tlv, 166);
	}
	return data;
}

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

async function world() {
	const svm = new LiteSVM();
	svm.addProgramFromFile(program, programPath);
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	svm.airdrop(owner.address, lamports(10_000_000_000n));
	let seed = 20;
	const signers = new Map([[payer.address, payer], [owner.address, owner]]);
	const put = async (data, holder) => {
		const made = await keypair(seed++);
		svm.setAccount({
			address: made.address,
			data,
			executable: false,
			lamports: lamports(svm.minimumBalanceForRentExemption(BigInt(data.length))),
			programAddress: holder,
			space: BigInt(data.length),
		});
		return made.address;
	};
	const send = async (programAddress, metas, data) => {
		const accounts = metas.map(([key, writable, signer = false]) => ({
			address: key,
			role: signer ? (writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER) : (writable ? AccountRole.WRITABLE : AccountRole.READONLY),
			...(signer ? { signer: signers.get(key) } : {}),
		}));
		const message = pipe(
			createTransactionMessage({ version: 0 }),
			(m) => setTransactionMessageFeePayerSigner(payer, m),
			(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
			(m) => appendTransactionMessageInstruction({ programAddress, accounts, data }, m),
		);
		const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
		svm.expireBlockhash();
		if (result.constructor.name !== "FailedTransactionMetadata") return { code: 0, units: Number(result.computeUnitsConsumed()) };
		const text = result.err().toString();
		const code = /code: (\d+)/.exec(text);
		return { code: code ? Number(code[1]) : text };
	};
	const verify = (op, key) => send(program, [[key, false]], Uint8Array.of(op)).then((r) => r.code);
	const units = (op, key) => send(program, [[key, false]], Uint8Array.of(op)).then((r) => r.units);
	const amountOf = (key) => new DataView(svm.getAccount(key).data.buffer, svm.getAccount(key).data.byteOffset).getBigUint64(64, true);
	return { svm, put, send, verify, units, amountOf };
}

const w = await world();

const legacyMint = await w.put(mintData([]), TOKEN);
const plain2022 = await w.put(mintData([]), TOKEN_2022);
const legacyAccount = await w.put(accountData(legacyMint, owner.address, 10), TOKEN);
const plainAccount2022 = await w.put(accountData(plain2022, owner.address, 10), TOKEN_2022);

check("a legacy mint is accepted by Mint", await w.verify(OP.mint, legacyMint) === 0);
check("a legacy mint is accepted by InterfaceMint", await w.verify(OP.interfaceMint, legacyMint) === 0);
check("a Token-2022 mint without extensions is refused by Mint", await w.verify(OP.mint, plain2022) === WRONG_PROGRAM);
check("a Token-2022 mint without extensions is accepted by InterfaceMint", await w.verify(OP.interfaceMint, plain2022) === 0);
check("a legacy token account is accepted by TokenAccount and InterfaceTokenAccount",
	await w.verify(OP.tokenAccount, legacyAccount) === 0 && await w.verify(OP.interfaceTokenAccount, legacyAccount) === 0);
check("a Token-2022 token account is refused by TokenAccount and accepted by InterfaceTokenAccount",
	await w.verify(OP.tokenAccount, plainAccount2022) === WRONG_PROGRAM && await w.verify(OP.interfaceTokenAccount, plainAccount2022) === 0);
const lengthened = await w.put(mintData([3]), TOKEN);
check("a legacy-owned mint longer than 82 bytes is not a Mint or an InterfaceMint",
	await w.verify(OP.mint, lengthened) === DID_NOT_DESERIALIZE && await w.verify(OP.interfaceMint, lengthened) === DID_NOT_DESERIALIZE);

const idle = await w.units(OP.mint, legacyMint);
const costs = [
	["Mint, legacy mint", await w.units(OP.mint, legacyMint)],
	["InterfaceMint, legacy mint", await w.units(OP.interfaceMint, legacyMint)],
	["InterfaceMint, Token-2022 mint without extensions", await w.units(OP.interfaceMint, plain2022)],
	["InterfaceMint, Token-2022 mint with MetadataPointer", await w.units(OP.interfaceMint, await w.put(mintData([18]), TOKEN_2022))],
	["InterfaceMint, Token-2022 mint with four inert extensions", await w.units(OP.interfaceMint, await w.put(mintData([3, 10, 18, 25]), TOKEN_2022))],
];
for (const [what, units] of costs) console.log(`measured: ${what}: ${units} CU (${units - idle} over Mint on a legacy mint)`);

const MINT_REFUSED = { 1: "TransferFeeConfig", 4: "ConfidentialTransferMint", 6: "DefaultAccountState", 9: "NonTransferable", 12: "PermanentDelegate", 14: "TransferHook", 16: "ConfidentialTransferFeeConfig", 24: "ConfidentialMintBurn", 26: "Pausable" };
for (const [kind, name] of Object.entries(MINT_REFUSED)) {
	const key = await w.put(mintData([Number(kind)]), TOKEN_2022);
	const alone = await w.verify(OP.interfaceMint, key);
	const after = await w.verify(OP.interfaceMint, await w.put(mintData([3, Number(kind)]), TOKEN_2022));
	check(`a mint with ${name} is refused by InterfaceMint, alone and after an inert extension`, alone === UNSUPPORTED && after === UNSUPPORTED);
}
const MINT_INERT = { 3: "MintCloseAuthority", 10: "InterestBearingConfig", 18: "MetadataPointer", 19: "TokenMetadata", 20: "GroupPointer", 21: "TokenGroup", 22: "GroupMemberPointer", 23: "TokenGroupMember", 25: "ScaledUiAmount" };
for (const [kind, name] of Object.entries(MINT_INERT)) {
	const key = await w.put(mintData([Number(kind)]), TOKEN_2022);
	check(`a mint with ${name} is accepted by InterfaceMint and refused by Mint`,
		await w.verify(OP.interfaceMint, key) === 0 && await w.verify(OP.mint, key) === WRONG_PROGRAM);
}
const unknownTable = concat(mintData([3]), u16(60000), u16(0));
const unknown = await w.put(unknownTable, TOKEN_2022);
check("a mint with an extension this std does not know is refused by InterfaceMint", await w.verify(OP.interfaceMint, unknown) === UNSUPPORTED);

const ACCOUNT_REFUSED = { 2: "TransferFeeAmount", 5: "ConfidentialTransferAccount", 13: "NonTransferableAccount", 15: "TransferHookAccount", 17: "ConfidentialTransferFeeAmount", 27: "PausableAccount" };
for (const [kind, name] of Object.entries(ACCOUNT_REFUSED)) {
	const key = await w.put(accountData(plain2022, owner.address, 10, [7, Number(kind)]), TOKEN_2022);
	check(`a token account with ${name} is refused by InterfaceTokenAccount`, await w.verify(OP.interfaceTokenAccount, key) === UNSUPPORTED);
}
const ACCOUNT_INERT = { 7: "ImmutableOwner", 8: "MemoTransfer", 11: "CpiGuard" };
for (const [kind, name] of Object.entries(ACCOUNT_INERT)) {
	const key = await w.put(accountData(plain2022, owner.address, 10, [Number(kind)]), TOKEN_2022);
	check(`a token account with ${name} is accepted by InterfaceTokenAccount`, await w.verify(OP.interfaceTokenAccount, key) === 0);
}

async function transferOn(tokenProgram, op, mintKinds, fromKinds = [], toKinds = [], fill = {}) {
	const on = { 8: Uint8Array.of(1), 11: Uint8Array.of(1) };
	const t = await world();
	const mint = await t.put(mintData(mintKinds, 1000, fill), tokenProgram);
	const from = await t.put(accountData(mint, owner.address, 500, fromKinds, on), tokenProgram);
	const to = await t.put(accountData(mint, payer.address, 0, toKinds, on), tokenProgram);
	const sent = await t.send(program, [[from, true], [to, true], [mint, false], [owner.address, false, true], [tokenProgram, false]], concat(Uint8Array.of(op), u64(120)));
	return { ...sent, from: t.amountOf(from), to: t.amountOf(to) };
}

const viaInterface2022 = await transferOn(TOKEN_2022, OP.transferInterface, [18]);
check("a transfer through the interface types on a Token-2022 mint with MetadataPointer moves exactly the amount",
	viaInterface2022.code === 0 && viaInterface2022.from === 380n && viaInterface2022.to === 120n);
const viaInterfaceLegacy = await transferOn(TOKEN, OP.transferInterface, []);
check("a transfer through the interface types on a legacy mint moves exactly the amount",
	viaInterfaceLegacy.code === 0 && viaInterfaceLegacy.from === 380n && viaInterfaceLegacy.to === 120n);
const viaLegacyTypes = await transferOn(TOKEN, OP.transferLegacy, []);
check("a transfer through the legacy types on a legacy mint moves exactly the amount",
	viaLegacyTypes.code === 0 && viaLegacyTypes.to === 120n);
const legacyTypes2022 = await transferOn(TOKEN_2022, OP.transferLegacy, []);
check("a transfer through the legacy types on a Token-2022 mint is refused before the CPI",
	legacyTypes2022.code === WRONG_PROGRAM && legacyTypes2022.from === 500n && legacyTypes2022.to === 0n);
const interestBearing = await transferOn(TOKEN_2022, OP.transferInterface, [10]);
check("InterestBearing: raw amounts move exactly (the extension changes the UI amount only)",
	interestBearing.code === 0 && interestBearing.to === 120n);
const withFee = await transferOn(TOKEN_2022, OP.transferInterface, [1], [2], [2]);
check("a transfer through the interface types on a TransferFeeConfig mint is refused and moves nothing",
	withFee.code === UNSUPPORTED && withFee.to === 0n);

const cpiGuarded = await transferOn(TOKEN_2022, OP.transferInterface, [], [11], []);
console.log(`measured: CpiGuard on the source, owner signing through a CPI: code ${cpiGuarded.code}, moved ${cpiGuarded.to}`);
check("CpiGuard fails the transfer loudly and moves nothing", cpiGuarded.code !== 0 && cpiGuarded.to === 0n);
const memoRequired = await transferOn(TOKEN_2022, OP.transferInterface, [], [], [8]);
console.log(`measured: MemoTransfer on the destination without a memo: code ${memoRequired.code}, moved ${memoRequired.to}`);
check("MemoTransfer fails the transfer loudly and moves nothing", memoRequired.code !== 0 && memoRequired.to === 0n);

const closable = await w.put(mintData([3], 5, { 3: encoder.encode(owner.address) }), TOKEN_2022);
const closed = await w.send(TOKEN_2022, [[closable, true], [payer.address, true], [owner.address, false, true]], Uint8Array.of(9));
console.log(`measured: closing a mint with MintCloseAuthority while its supply is 5: code ${closed.code}`);
check("MintCloseAuthority cannot close a mint that still has supply", closed.code !== 0 && w.svm.getAccount(closable).exists);
const emptied = await w.put(mintData([3], 0, { 3: encoder.encode(owner.address) }), TOKEN_2022);
const closedEmpty = await w.send(TOKEN_2022, [[emptied, true], [payer.address, true], [owner.address, false, true]], Uint8Array.of(9));
check("and closes one whose supply is zero", closedEmpty.code === 0 && !w.svm.getAccount(emptied).exists);

if (failures > 0) {
	console.error(`${failures} check(s) failed`);
	process.exit(1);
}
console.log("token interface types against the real token programs: every check passed");
