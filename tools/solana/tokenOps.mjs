import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressDecoder,
	getAddressEncoder,
	getProgramDerivedAddress,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node tokenOps.mjs <tokenOpsProbe.so>   (msc build tools/solana/tokenOpsProbe.ms --os=solana --release --output=tokenOpsProbe.so)");
	process.exit(2);
}

const SYSTEM = address("11111111111111111111111111111111");
const TOKEN = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const TOKEN_2022 = address("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
const ASSOCIATED_TOKEN = address("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
const INCINERATOR = address("1nc1nerator11111111111111111111111111111111");
const NATIVE_MINT = { [TOKEN]: address("So11111111111111111111111111111111111111112"), [TOKEN_2022]: address("9pan9bMn5HatX4EJdBwg9VgCa7Uz5HL8N1m5D3NdXejP") };
const OP = {
	createAtKeypair: 0, createAtPda: 1, initializeRaw: 2, burn: 3, burnAsPda: 4, burnRaw: 5,
	setMintAuthority: 6, setAccountAuthority: 7, setMintAuthorityAsPda: 8, setAuthorityRaw: 9,
	approve: 10, approveAsPda: 11, approveRaw: 12, revoke: 13, revokeAsPda: 14, transfer: 15,
	createAssociatedRaw: 16,
};
const KIND = { mintTokens: 0, freezeAccount: 1, accountOwner: 2, closeAccount: 3 };
const MINT_EXTENSION_LENGTH = { 1: 108, 3: 32, 6: 1, 9: 0, 14: 64, 26: 33 };
const DEFAULT_ACCOUNT_STATE = 6;
const FROZEN = 2;
const encoder = getAddressEncoder();
const decoder = getAddressDecoder();

const keypair = (seed) => createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed));
const program = (await keypair(9)).address;

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

function mintData(authority, decimals, supply, extensions = [], freeze = null) {
	const tlv = extensions.flatMap((kind) => {
		const entry = new Uint8Array(4 + MINT_EXTENSION_LENGTH[kind]);
		new DataView(entry.buffer).setUint16(0, kind, true);
		new DataView(entry.buffer).setUint16(2, MINT_EXTENSION_LENGTH[kind], true);
		if (kind === DEFAULT_ACCOUNT_STATE) entry[4] = FROZEN;
		return [entry];
	});
	const data = new Uint8Array(extensions.length === 0 ? 82 : 166 + tlv.reduce((total, entry) => total + entry.length, 0));
	data.set([1, 0, 0, 0], 0);
	data.set(encoder.encode(authority), 4);
	data.set(u64(supply), 36);
	data[44] = decimals;
	data[45] = 1;
	if (freeze !== null) {
		data[46] = 1;
		data.set(encoder.encode(freeze), 50);
	}
	if (extensions.length > 0) {
		data[165] = 1;
		data.set(concat(...tlv), 166);
	}
	return data;
}

function tokenData(mint, owner, amount, fields = {}) {
	const { delegate = null, allowance = 0, state = 1, nativeReserve = null, closeAuthority = null } = fields;
	const data = new Uint8Array(165);
	data.set(encoder.encode(mint), 0);
	data.set(encoder.encode(owner), 32);
	data.set(u64(amount), 64);
	if (delegate !== null) {
		data[72] = 1;
		data.set(encoder.encode(delegate), 76);
		data.set(u64(allowance), 121);
	}
	data[108] = state;
	if (nativeReserve !== null) {
		data[109] = 1;
		data.set(u64(nativeReserve), 113);
	}
	if (closeAuthority !== null) {
		data[129] = 1;
		data.set(encoder.encode(closeAuthority), 133);
	}
	return data;
}

function optionalKeyAt(stored, offset) {
	const view = new DataView(stored.data.buffer, stored.data.byteOffset);
	return view.getUint32(offset, true) === 1 ? decoder.decode(stored.data.subarray(offset + 4, offset + 36)) : null;
}

function supplyOf(stored) {
	return new DataView(stored.data.buffer, stored.data.byteOffset).getBigUint64(36, true);
}

function tokenFields(stored) {
	const view = new DataView(stored.data.buffer, stored.data.byteOffset);
	const optionalKey = (offset) => optionalKeyAt(stored, offset);
	return {
		mint: decoder.decode(stored.data.subarray(0, 32)),
		owner: decoder.decode(stored.data.subarray(32, 64)),
		amount: view.getBigUint64(64, true),
		delegate: optionalKey(72),
		state: stored.data[108],
		nativeReserve: view.getUint32(109, true) === 1 ? view.getBigUint64(113, true) : null,
		delegatedAmount: view.getBigUint64(121, true),
		closeAuthority: optionalKey(129),
	};
}

function extensionKinds(data) {
	const kinds = [];
	const view = new DataView(data.buffer, data.byteOffset);
	for (let offset = 166; offset + 4 <= data.length; offset += 4 + view.getUint16(offset + 2, true)) {
		if (view.getUint16(offset, true) === 0) break;
		kinds.push(view.getUint16(offset, true));
	}
	return kinds;
}

let failures = 0;

async function scenario(label, tokenProgram, body) {
	const svm = new LiteSVM();
	svm.addProgramFromFile(program, programPath);
	const payer = await keypair(1);
	const owner = await keypair(2);
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	svm.airdrop(owner.address, lamports(10_000_000_000n));
	let nextSeed = 20;
	const signers = new Map([[payer.address, payer], [owner.address, owner]]);

	function check(what, condition) {
		console.log(`[${label}] ${what}: ${condition ? "ok" : "FAILED"}`);
		if (!condition) failures++;
	}

	async function fresh() {
		const made = await keypair(nextSeed++);
		signers.set(made.address, made);
		return made;
	}

	function put(account, data, owningProgram = tokenProgram) {
		svm.setAccount({
			address: account,
			data,
			executable: false,
			lamports: lamports(svm.minimumBalanceForRentExemption(BigInt(data.length))),
			programAddress: owningProgram,
			space: BigInt(data.length),
		});
	}

	async function mint(decimals, supply, extensions = [], { authority = owner.address, freeze = null } = {}) {
		const made = (await fresh()).address;
		put(made, mintData(authority, decimals, supply, extensions, freeze));
		return made;
	}

	async function token(mintAddress, holder, amount, fields = {}, owningProgram = tokenProgram) {
		const made = (await fresh()).address;
		put(made, tokenData(mintAddress, holder, amount, fields), owningProgram);
		return made;
	}

	const meta = (account, writable, signer = false) => ({ address: account, writable, signer });

	async function send(step, op, metas, argument, expected = null) {
		const accounts = metas.map((entry) => ({
			address: entry.address,
			role: entry.signer
				? (entry.writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER)
				: (entry.writable ? AccountRole.WRITABLE : AccountRole.READONLY),
			...(entry.signer ? { signer: signers.get(entry.address) } : {}),
		}));
		const instruction = { programAddress: program, accounts, data: concat(new Uint8Array([op]), argument) };
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
		const logs = (failed ? result.meta() : result).logs();
		const error = failed ? result.err().toString() : "";
		const refusedBy = logs.filter((line) => / failed: /.test(line)).map((line) => line.split(" ")[1])[0] ?? "";
		const passed = expected === null
			? !failed
			: failed && error.includes(expected.error) && (expected.by === undefined || refusedBy === expected.by);
		console.log(`[${label}] ${step}: ${failed ? `${error} by ${refusedBy}` : "ok"}${passed ? "" : "  <-- FAILED"}`);
		if (!passed || process.env.TOKEN_OPS_LOGS) console.log(logs.join("\n"));
		if (!passed) failures++;
		return { failed, error, logs };
	}

	await body({ svm, payer, owner, tokenProgram, check, fresh, put, mint, token, meta, send });
}

const custom = (code, by) => ({ error: `InstructionErrorCustom { code: ${code} }`, by });

for (const [name, tokenProgram] of [["token", TOKEN], ["token-2022", TOKEN_2022]]) {
	await scenario(`${name}: create a token account`, tokenProgram, async (t) => {
		const mint = await t.mint(6, 1_000_000);
		const created = await t.fresh();
		const metas = (target, signer) => [
			t.meta(t.payer.address, true, true),
			t.meta(target, true, signer),
			t.meta(mint, false),
			t.meta(SYSTEM, false),
			t.meta(tokenProgram, false),
		];
		const ownerBytes = encoder.encode(t.owner.address);
		await t.send("at a keypair address", OP.createAtKeypair, metas(created.address, true), ownerBytes);
		const stored = t.svm.getAccount(created.address);
		const fields = tokenFields(stored);
		t.check("the account belongs to the mint's token program, 165 bytes, at the rent minimum",
			stored.programAddress === tokenProgram && stored.data.length === 165
				&& stored.lamports === t.svm.minimumBalanceForRentExemption(165n));
		t.check("it is initialized for the mint and the owner, empty, with no delegate and no close authority",
			fields.mint === mint && fields.owner === t.owner.address && fields.amount === 0n && fields.state === 1
				&& fields.delegate === null && fields.closeAuthority === null && fields.nativeReserve === null);
		await t.send("at an address that already holds a token account", OP.createAtKeypair,
			metas(created.address, true), ownerBytes, custom(0, SYSTEM));

		const [vault] = await getProgramDerivedAddress({ programAddress: program, seeds: ["vault", encoder.encode(mint)] });
		await t.send("at a PDA of the program", OP.createAtPda, metas(vault, false), ownerBytes);
		const vaultFields = tokenFields(t.svm.getAccount(vault));
		t.check("the PDA holds a token account of the mint and the owner",
			t.svm.getAccount(vault).programAddress === tokenProgram && vaultFields.mint === mint
				&& vaultFields.owner === t.owner.address && vaultFields.state === 1);
		const elsewhere = await t.fresh();
		await t.send("at an address the seeds do not derive", OP.createAtPda, metas(elsewhere.address, false),
			ownerBytes, custom(2006, program));
		t.check("nothing was created there", !t.svm.getAccount(elsewhere.address).exists);

		const funded = await t.fresh();
		const rent = t.svm.minimumBalanceForRentExemption(165n);
		t.svm.airdrop(funded.address, lamports(rent + 5000n));
		const native = NATIVE_MINT[tokenProgram];
		if (!t.svm.getAccount(native).exists) t.put(native, mintData(t.owner.address, 9, 0));
		const nativeMetas = metas(funded.address, true);
		nativeMetas[2] = t.meta(native, false);
		await t.send("for the native mint at a prefunded address", OP.createAtKeypair, nativeMetas, ownerBytes);
		const wrapped = tokenFields(t.svm.getAccount(funded.address));
		t.check("a native account holds the lamports above its rent reserve",
			wrapped.nativeReserve === rent && wrapped.amount === 5000n);
	});

	await scenario(`${name}: InitializeAccount3 refusals`, tokenProgram, async (t) => {
		const mint = await t.mint(6, 1_000_000);
		const blank = async (lamportsShort = 0n) => {
			const made = (await t.fresh()).address;
			t.put(made, new Uint8Array(165));
			if (lamportsShort > 0n) {
				t.svm.setAccount({ ...t.svm.getAccount(made), lamports: lamports(t.svm.minimumBalanceForRentExemption(165n) - lamportsShort) });
			}
			return made;
		};
		const metas = (target, mintAccount) => [
			t.meta(t.payer.address, true, true),
			t.meta(target, true),
			t.meta(mintAccount, false),
			t.meta(tokenProgram, false),
		];
		const ownerBytes = encoder.encode(t.owner.address);
		const target = await blank();
		await t.send("a blank account of the token program", OP.initializeRaw, metas(target, mint), ownerBytes);
		await t.send("an account that is already initialized", OP.initializeRaw, metas(target, mint), ownerBytes,
			custom(6, tokenProgram));
		const unminted = (await t.fresh()).address;
		t.put(unminted, new Uint8Array(82));
		await t.send("a mint that is not initialized", OP.initializeRaw, metas(await blank(), unminted), ownerBytes,
			custom(2, tokenProgram));
		const foreignMint = (await t.fresh()).address;
		t.put(foreignMint, mintData(t.owner.address, 6, 0), tokenProgram === TOKEN ? TOKEN_2022 : TOKEN);
		await t.send("a mint of the other token program", OP.initializeRaw, metas(await blank(), foreignMint), ownerBytes,
			{ error: "IncorrectProgramId", by: tokenProgram });
		await t.send("an account below the rent minimum", OP.initializeRaw, metas(await blank(1n), mint), ownerBytes,
			custom(0, tokenProgram));
		const short = (await t.fresh()).address;
		t.put(short, new Uint8Array(164));
		await t.send("an account of 164 bytes", OP.initializeRaw, metas(short, mint), ownerBytes,
			{ error: "InvalidAccountData", by: tokenProgram });
		const foreign = (await t.fresh()).address;
		t.put(foreign, new Uint8Array(165), program);
		await t.send("an account the token program does not own", OP.initializeRaw, metas(foreign, mint), ownerBytes,
			{ error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram });
	});

	await scenario(`${name}: burn`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const mint = await t.mint(6, 1_000_000);
		const metas = (from, authority, signs = true, mintAccount = mint) => [
			t.meta(from, true),
			t.meta(mintAccount, true),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const amountOf = (account) => tokenFields(t.svm.getAccount(account)).amount;
		const held = await t.token(mint, t.owner.address, 900);
		await t.send("by the owner", OP.burn, metas(held, t.owner.address), u64(250));
		t.check("the account holds 650 and the supply fell by 250",
			amountOf(held) === 650n && supplyOf(t.svm.getAccount(mint)) === 999_750n);
		await t.send("more than the account holds", OP.burn, metas(held, t.owner.address), u64(651),
			custom(1, tokenProgram));
		await t.send("by a signer that is neither owner nor delegate", OP.burn, metas(held, t.payer.address), u64(1),
			custom(4, tokenProgram));
		await t.send("by an owner that did not sign, refused before the CPI", OP.burn,
			metas(held, t.owner.address, false), u64(1), custom(3010, program));
		await t.send("by an owner that did not sign, sent raw", OP.burnRaw,
			metas(held, t.owner.address, false), concat(u64(1), new Uint8Array([6])),
			{ error: "PrivilegeEscalation", by: program });
		await t.send("with decimals that are not the mint's", OP.burnRaw,
			metas(held, t.owner.address), concat(u64(1), new Uint8Array([5])), custom(18, tokenProgram));
		const elsewhere = await t.mint(6, 1_000_000);
		await t.send("against another mint", OP.burn, metas(held, t.owner.address, true, elsewhere), u64(1),
			custom(3, tokenProgram));
		const frozen = await t.token(mint, t.owner.address, 900, { state: 2 });
		await t.send("from a frozen account", OP.burn, metas(frozen, t.owner.address), u64(1),
			custom(17, tokenProgram));
		const native = await t.token(mint, t.owner.address, 900, { nativeReserve: 2_039_280 });
		await t.send("from a native account", OP.burn, metas(native, t.owner.address), u64(1),
			custom(10, tokenProgram));
		const foreign = await t.token(mint, t.owner.address, 900, {}, other);
		await t.send("from an account of the other token program", OP.burn, metas(foreign, t.owner.address), u64(1),
			{ error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram });
		t.check("the refusals changed nothing", amountOf(held) === 650n && amountOf(frozen) === 900n
			&& amountOf(foreign) === 900n && supplyOf(t.svm.getAccount(mint)) === 999_750n);

		const lent = await t.token(mint, t.owner.address, 900, { delegate: t.payer.address, allowance: 300 });
		await t.send("by a delegate beyond its allowance", OP.burn, metas(lent, t.payer.address), u64(301),
			custom(1, tokenProgram));
		await t.send("by a delegate within its allowance", OP.burn, metas(lent, t.payer.address), u64(100));
		let fields = tokenFields(t.svm.getAccount(lent));
		t.check("the burn spent 100 of the allowance", fields.amount === 800n && fields.delegatedAmount === 200n
			&& fields.delegate === t.payer.address);
		await t.send("by a delegate for the rest of its allowance", OP.burn, metas(lent, t.payer.address), u64(200));
		fields = tokenFields(t.svm.getAccount(lent));
		t.check("a spent allowance removes the delegate", fields.amount === 600n && fields.delegatedAmount === 0n
			&& fields.delegate === null);
		t.check(`the delegate's key bytes ${tokenProgram === TOKEN ? "stay behind" : "are zeroed with"} its cleared tag`,
			decoder.decode(t.svm.getAccount(lent).data.subarray(76, 108))
				=== (tokenProgram === TOKEN ? t.payer.address : SYSTEM));
		const blank = (await t.fresh()).address;
		t.put(blank, new Uint8Array(165));
		await t.send("from an account that is not initialized", OP.burnRaw, metas(blank, t.owner.address),
			concat(u64(0), new Uint8Array([6])), { error: "UninitializedAccount", by: tokenProgram });
		await t.send("by the former delegate", OP.burn, metas(lent, t.payer.address), u64(1), custom(4, tokenProgram));

		for (const [what, holder] of [["the System program", SYSTEM], ["the incinerator", INCINERATOR]]) {
			const abandoned = await t.token(mint, holder, 50);
			await t.send(`by any signer, from an account ${what} owns`, OP.burn, metas(abandoned, t.payer.address),
				u64(50));
			t.check("that account is empty", amountOf(abandoned) === 0n);
		}

		const [authority] = await getProgramDerivedAddress({ programAddress: program, seeds: ["authority"] });
		const vault = await t.token(mint, authority, 400);
		await t.send("by a PDA of the program", OP.burnAsPda, metas(vault, authority, false), u64(400));
		t.check("the PDA's account is empty and the supply fell by 400 more",
			amountOf(vault) === 0n && supplyOf(t.svm.getAccount(mint)) === 998_950n);
		await t.send("as a PDA the seeds do not derive", OP.burnAsPda, metas(held, t.owner.address, false), u64(1),
			custom(2006, program));
	});

	await scenario(`${name}: set authority`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const next = (await t.fresh()).address;
		const metas = (target, authority, signs = true) => [
			t.meta(target, true),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const to = (kind, key = next) => key === null
			? new Uint8Array([kind, 0])
			: concat(new Uint8Array([kind, 1]), encoder.encode(key));
		const stored = (account) => t.svm.getAccount(account);
		const keepsClearedKeys = tokenProgram === TOKEN;

		const mint = await t.mint(6, 1_000_000);
		await t.send("a mint's mint authority, by a signer that is not it", OP.setMintAuthority,
			metas(mint, t.payer.address), to(KIND.mintTokens), custom(4, tokenProgram));
		await t.send("a mint's mint authority, by an authority that did not sign", OP.setMintAuthority,
			metas(mint, t.owner.address, false), to(KIND.mintTokens), custom(3010, program));
		await t.send("a mint's freeze authority where the mint has none", OP.setMintAuthority,
			metas(mint, t.owner.address), to(KIND.freezeAccount), custom(16, tokenProgram));
		for (const kind of [KIND.accountOwner, KIND.closeAccount]) {
			await t.send(`authority type ${kind} on a mint`, OP.setMintAuthority, metas(mint, t.owner.address), to(kind),
				custom(15, tokenProgram));
		}
		await t.send("a mint's mint authority", OP.setMintAuthority, metas(mint, t.owner.address), to(KIND.mintTokens));
		t.check("the mint names the next authority", optionalKeyAt(stored(mint), 0) === next);
		await t.send("a mint's mint authority, by the former authority", OP.setMintAuthority,
			metas(mint, t.owner.address), to(KIND.mintTokens), custom(4, tokenProgram));

		const fixed = await t.mint(6, 1_000_000);
		await t.send("a mint's mint authority to none", OP.setMintAuthority, metas(fixed, t.owner.address),
			to(KIND.mintTokens, null));
		t.check("the mint has no mint authority", optionalKeyAt(stored(fixed), 0) === null
			&& decoder.decode(stored(fixed).data.subarray(4, 36)) === (keepsClearedKeys ? t.owner.address : SYSTEM));
		await t.send("the mint authority of a fixed supply", OP.setMintAuthority, metas(fixed, t.owner.address),
			to(KIND.mintTokens), custom(5, tokenProgram));

		const freezable = await t.mint(6, 1_000_000, [], { freeze: t.owner.address });
		await t.send("a mint's freeze authority", OP.setMintAuthority, metas(freezable, t.owner.address),
			to(KIND.freezeAccount));
		t.check("the mint names the next freeze authority and keeps its mint authority",
			optionalKeyAt(stored(freezable), 46) === next && optionalKeyAt(stored(freezable), 0) === t.owner.address);

		const [pda] = await getProgramDerivedAddress({ programAddress: program, seeds: ["authority"] });
		const governed = await t.mint(6, 1_000_000, [], { authority: pda });
		await t.send("a mint's mint authority held by a PDA of the program", OP.setMintAuthorityAsPda,
			metas(governed, pda, false), to(KIND.mintTokens));
		t.check("the PDA handed the mint over", optionalKeyAt(stored(governed), 0) === next);

		const delegate = (await t.fresh()).address;
		const held = await t.token(mint, t.owner.address, 900, { delegate, allowance: 300 });
		await t.send("a token account's owner to none", OP.setAccountAuthority, metas(held, t.owner.address),
			to(KIND.accountOwner, null), custom(12, tokenProgram));
		for (const kind of [KIND.mintTokens, KIND.freezeAccount]) {
			await t.send(`authority type ${kind} on a token account`, OP.setAccountAuthority,
				metas(held, t.owner.address), to(kind), custom(15, tokenProgram));
		}
		await t.send("a token account's owner, by a signer that is not it", OP.setAccountAuthority,
			metas(held, t.payer.address), to(KIND.accountOwner), custom(4, tokenProgram));
		await t.send("a token account's owner", OP.setAccountAuthority, metas(held, t.owner.address),
			to(KIND.accountOwner));
		let fields = tokenFields(stored(held));
		t.check("the account has the next owner, its balance, and no delegate",
			fields.owner === next && fields.amount === 900n && fields.delegate === null
				&& fields.delegatedAmount === 0n && fields.closeAuthority === null);
		t.check(`the delegate's key bytes ${keepsClearedKeys ? "stay behind" : "are zeroed with"} its cleared tag`,
			decoder.decode(stored(held).data.subarray(76, 108)) === (keepsClearedKeys ? delegate : SYSTEM));

		const closable = await t.token(mint, t.owner.address, 900);
		await t.send("a close authority, by the owner of an account that has none", OP.setAccountAuthority,
			metas(closable, t.owner.address), to(KIND.closeAccount, t.payer.address));
		t.check("the account names its close authority and keeps its owner",
			tokenFields(stored(closable)).closeAuthority === t.payer.address
				&& tokenFields(stored(closable)).owner === t.owner.address);
		await t.send("a close authority, by the owner of an account that has one", OP.setAccountAuthority,
			metas(closable, t.owner.address), to(KIND.closeAccount), custom(4, tokenProgram));
		await t.send("a close authority to none, by the close authority", OP.setAccountAuthority,
			metas(closable, t.payer.address), to(KIND.closeAccount, null));
		t.check("the account has no close authority", tokenFields(stored(closable)).closeAuthority === null);

		const frozen = await t.token(mint, t.owner.address, 900, { state: 2 });
		await t.send("the owner of a frozen account", OP.setAccountAuthority, metas(frozen, t.owner.address),
			to(KIND.accountOwner), custom(17, tokenProgram));
		const native = await t.token(mint, t.owner.address, 900,
			{ nativeReserve: 2_039_280, closeAuthority: t.payer.address });
		await t.send("the owner of a native account", OP.setAccountAuthority, metas(native, t.owner.address),
			to(KIND.accountOwner));
		t.check("a native account loses its close authority with its owner",
			tokenFields(stored(native)).owner === next && tokenFields(stored(native)).closeAuthority === null);

		const neither = (await t.fresh()).address;
		t.put(neither, new Uint8Array(100));
		await t.send("an account that is neither a mint nor a token account", OP.setAuthorityRaw,
			metas(neither, t.owner.address), to(KIND.mintTokens),
			{ error: tokenProgram === TOKEN ? "InvalidArgument" : "InvalidAccountData", by: tokenProgram });
		for (const [what, length] of [["mint", 82], ["token account", 165]]) {
			const blank = (await t.fresh()).address;
			t.put(blank, new Uint8Array(length));
			await t.send(`a ${what} that is not initialized`, OP.setAuthorityRaw, metas(blank, t.owner.address),
				to(KIND.mintTokens),
				{ error: tokenProgram === TOKEN ? "UninitializedAccount" : "InvalidAccountData", by: tokenProgram });
		}
		const foreign = await t.token(mint, t.owner.address, 900, {}, other);
		await t.send("a token account of the other token program", OP.setAuthorityRaw,
			metas(foreign, t.owner.address), to(KIND.accountOwner),
			{ error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram });
		t.check("the refused account keeps its owner", tokenFields(stored(foreign)).owner === t.owner.address);
	});

	await scenario(`${name}: approve and revoke`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const mint = await t.mint(6, 1_000_000);
		const delegate = await t.fresh();
		const approving = (source, authority, signs = true, mintAccount = mint, spender = delegate.address) => [
			t.meta(source, true),
			t.meta(mintAccount, false),
			t.meta(spender, false),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const revoking = (source, authority, signs = true) => [
			t.meta(source, true),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const fieldsOf = (account) => tokenFields(t.svm.getAccount(account));
		const delegateBytes = (account) => decoder.decode(t.svm.getAccount(account).data.subarray(76, 108));

		const held = await t.token(mint, t.owner.address, 900);
		await t.send("approve by a signer that is not the owner", OP.approve, approving(held, t.payer.address), u64(300),
			custom(4, tokenProgram));
		await t.send("approve by an owner that did not sign", OP.approve, approving(held, t.owner.address, false),
			u64(300), custom(3010, program));
		const elsewhere = await t.mint(6, 1_000_000);
		await t.send("approve against another mint", OP.approve,
			approving(held, t.owner.address, true, elsewhere), u64(300), custom(3, tokenProgram));
		await t.send("approve with decimals that are not the mint's", OP.approveRaw, approving(held, t.owner.address),
			concat(u64(300), new Uint8Array([5])), custom(18, tokenProgram));
		const frozen = await t.token(mint, t.owner.address, 900, { state: 2, delegate: delegate.address, allowance: 7 });
		await t.send("approve on a frozen account", OP.approve, approving(frozen, t.owner.address), u64(300),
			custom(17, tokenProgram));
		await t.send("revoke on a frozen account", OP.revoke, revoking(frozen, t.owner.address), new Uint8Array(),
			custom(17, tokenProgram));
		const blank = (await t.fresh()).address;
		t.put(blank, new Uint8Array(165));
		await t.send("approve on an account that is not initialized", OP.approveRaw, approving(blank, t.owner.address),
			concat(u64(300), new Uint8Array([6])), { error: "UninitializedAccount", by: tokenProgram });
		const foreign = await t.token(mint, t.owner.address, 900, {}, other);
		await t.send("approve on an account of the other token program", OP.approve,
			approving(foreign, t.owner.address), u64(300),
			{ error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram });
		t.check("the refusals named no delegate", fieldsOf(held).delegate === null && fieldsOf(foreign).delegate === null
			&& fieldsOf(frozen).delegatedAmount === 7n);

		await t.send("approve by the owner", OP.approve, approving(held, t.owner.address), u64(300));
		t.check("the account names the delegate and an allowance of 300, and keeps its balance",
			fieldsOf(held).delegate === delegate.address && fieldsOf(held).delegatedAmount === 300n
				&& fieldsOf(held).amount === 900n && fieldsOf(held).owner === t.owner.address);

		const destination = await t.token(mint, t.payer.address, 0);
		const moving = [
			t.meta(held, true),
			t.meta(destination, true),
			t.meta(mint, false),
			t.meta(delegate.address, false, true),
			t.meta(tokenProgram, false),
		];
		await t.send("a transfer by the delegate beyond its allowance", OP.transfer, moving, u64(301),
			custom(1, tokenProgram));
		await t.send("a transfer by the delegate within its allowance", OP.transfer, moving, u64(100));
		t.check("the transfer moved 100 and spent 100 of the allowance",
			fieldsOf(held).amount === 800n && fieldsOf(destination).amount === 100n
				&& fieldsOf(held).delegatedAmount === 200n && fieldsOf(held).delegate === delegate.address);
		await t.send("a transfer by the delegate for the rest of its allowance", OP.transfer, moving, u64(200));
		t.check("a spent allowance removes the delegate",
			fieldsOf(destination).amount === 300n && fieldsOf(held).delegatedAmount === 0n
				&& fieldsOf(held).delegate === null);
		await t.send("a transfer by the former delegate", OP.transfer, moving, u64(1), custom(4, tokenProgram));

		await t.send("approve beyond the balance, for another delegate", OP.approve,
			approving(held, t.owner.address, true, mint, t.payer.address), u64(5000));
		t.check("the later approval replaced the delegate and the allowance",
			fieldsOf(held).delegate === t.payer.address && fieldsOf(held).delegatedAmount === 5000n);
		await t.send("revoke by a signer that is neither owner nor delegate", OP.revoke,
			revoking(held, delegate.address), new Uint8Array(), custom(4, tokenProgram));
		await t.send("revoke by an owner that did not sign", OP.revoke, revoking(held, t.owner.address, false),
			new Uint8Array(), custom(3010, program));
		await t.send("revoke by the owner", OP.revoke, revoking(held, t.owner.address), new Uint8Array());
		t.check("the account has no delegate and no allowance",
			fieldsOf(held).delegate === null && fieldsOf(held).delegatedAmount === 0n && fieldsOf(held).amount === 600n);
		t.check(`the delegate's key bytes ${tokenProgram === TOKEN ? "stay behind" : "are zeroed with"} its cleared tag`,
			delegateBytes(held) === (tokenProgram === TOKEN ? t.payer.address : SYSTEM));
		await t.send("revoke where there is no delegate", OP.revoke, revoking(held, t.owner.address), new Uint8Array());

		const lent = await t.token(mint, t.owner.address, 900, { delegate: delegate.address, allowance: 300 });
		await t.send("revoke by the delegate itself", OP.revoke, revoking(lent, delegate.address), new Uint8Array());
		t.check("the delegate is gone", fieldsOf(lent).delegate === null && fieldsOf(lent).delegatedAmount === 0n);
		await t.send("revoke by the former delegate", OP.revoke, revoking(lent, delegate.address), new Uint8Array(),
			custom(4, tokenProgram));

		const [pda] = await getProgramDerivedAddress({ programAddress: program, seeds: ["authority"] });
		const vault = await t.token(mint, pda, 400);
		await t.send("approve by a PDA of the program", OP.approveAsPda, approving(vault, pda, false), u64(250));
		t.check("the PDA's account names the delegate and an allowance of 250",
			fieldsOf(vault).delegate === delegate.address && fieldsOf(vault).delegatedAmount === 250n);
		await t.send("revoke by a PDA of the program", OP.revokeAsPda, revoking(vault, pda, false), new Uint8Array());
		t.check("the PDA's account has no delegate", fieldsOf(vault).delegate === null
			&& fieldsOf(vault).delegatedAmount === 0n);
		await t.send("approve as a PDA the seeds do not derive", OP.approveAsPda,
			approving(held, t.owner.address, false), u64(1), custom(2006, program));
		await t.send("revoke as a PDA the seeds do not derive", OP.revokeAsPda,
			revoking(lent, t.owner.address, false), new Uint8Array(), custom(2006, program));
	});

	await scenario(`${name}: raw createAssociatedToken`, tokenProgram, async (t) => {
		const mint = await t.mint(6, 1_000_000);
		const [associated] = await getProgramDerivedAddress({
			programAddress: ASSOCIATED_TOKEN,
			seeds: [encoder.encode(t.owner.address), encoder.encode(tokenProgram), encoder.encode(mint)],
		});
		const metas = (systemSlot) => [
			t.meta(t.payer.address, true, true),
			t.meta(associated, true),
			t.meta(t.owner.address, false),
			t.meta(mint, false),
			t.meta(systemSlot, false),
			t.meta(tokenProgram, false),
			t.meta(ASSOCIATED_TOKEN, false),
			t.meta(SYSTEM, false),
		];
		await t.send("with another account in the system program's place", OP.createAssociatedRaw,
			metas(t.owner.address), new Uint8Array(), { error: "IncorrectProgramId", by: program });
		t.check("nothing was created", !t.svm.getAccount(associated).exists);
		await t.send("with the System program", OP.createAssociatedRaw, metas(SYSTEM), new Uint8Array());
		const stored = t.svm.getAccount(associated);
		t.check("the associated account belongs to the token program and holds the wallet's account of the mint",
			stored.exists && stored.programAddress === tokenProgram && tokenFields(stored).mint === mint
				&& tokenFields(stored).owner === t.owner.address && tokenFields(stored).state === 1);
		const length = tokenProgram === TOKEN ? 165 : 170;
		t.check(`the associated account is ${length} bytes`, stored.data.length === length);
	});
}

await scenario("token-2022: account extensions the mint requires", TOKEN_2022, async (t) => {
	const cases = [
		{ mint: [1], length: 178, account: [2] },
		{ mint: [9], length: 174, account: [13, 7] },
		{ mint: [14], length: 171, account: [15] },
		{ mint: [26], length: 170, account: [27] },
		{ mint: [3], length: 165, account: [] },
		{ mint: [6], length: 165, account: [], state: 2 },
		{ mint: [1, 9, 14, 26], length: 195, account: [2, 13, 7, 15, 27] },
	];
	const immutable = await t.fresh();
	const fixedOwnerMint = await t.mint(6, 1_000_000, [9]);
	await t.send("an account of a non-transferable mint", OP.createAtKeypair, [
		t.meta(t.payer.address, true, true),
		t.meta(immutable.address, true, true),
		t.meta(fixedOwnerMint, false),
		t.meta(SYSTEM, false),
		t.meta(TOKEN_2022, false),
	], encoder.encode(t.owner.address));
	const handOver = [t.meta(immutable.address, true), t.meta(t.owner.address, false, true), t.meta(TOKEN_2022, false)];
	await t.send("the owner of an account with an immutable owner", OP.setAccountAuthority, handOver,
		concat(new Uint8Array([KIND.accountOwner, 1]), encoder.encode(t.payer.address)), custom(34, TOKEN_2022));
	await t.send("the close authority of an account with an immutable owner", OP.setAccountAuthority, handOver,
		concat(new Uint8Array([KIND.closeAccount, 1]), encoder.encode(t.payer.address)));
	t.check("the account keeps its owner and names its close authority",
		tokenFields(t.svm.getAccount(immutable.address)).owner === t.owner.address
			&& tokenFields(t.svm.getAccount(immutable.address)).closeAuthority === t.payer.address);

	for (const { mint: extensions, length, account, state = 1 } of cases) {
		const mint = await t.mint(6, 1_000_000, extensions);
		const created = await t.fresh();
		await t.send(`a mint with extensions ${extensions.join(",")}`, OP.createAtKeypair, [
			t.meta(t.payer.address, true, true),
			t.meta(created.address, true, true),
			t.meta(mint, false),
			t.meta(SYSTEM, false),
			t.meta(TOKEN_2022, false),
		], encoder.encode(t.owner.address));
		const stored = t.svm.getAccount(created.address);
		const kinds = stored.exists ? extensionKinds(stored.data) : [];
		t.check(`the account is ${length} bytes with extensions ${account.join(",") || "none"}`,
			stored.exists && stored.data.length === length && kinds.join(",") === account.join(",")
				&& (length === 165 || stored.data[165] === 2) && tokenFields(stored).state === state);
	}
});

if (failures > 0) {
	console.error(`${failures} check(s) failed`);
	process.exit(1);
}
console.log("token operations against the real token programs: every check passed");
