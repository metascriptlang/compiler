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
	createAssociatedRaw: 16, mint: 17, mintAsPda: 18, mintRaw: 19, transferAsPda: 20, transferRaw: 21,
	close: 22, closeAsPda: 23, closeRaw: 24, createAssociatedFor: 25, createAssociatedIdempotentRaw: 26,
	initializeMintRaw: 27, forward: 28,
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
	if (authority !== null) {
		data[0] = 1;
		data.set(encoder.encode(authority), 4);
	}
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

	const forward = (step, callee, metas, data, expected = null) => send(step, OP.forward,
		[meta(callee, false), ...metas], concat(new Uint8Array([metas.length]), data), expected);

	await body({ svm, payer, owner, tokenProgram, check, fresh, put, mint, token, meta, send, forward });
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

	await scenario(`${name}: malformed and misdirected`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const SHORT = tokenProgram === TOKEN ? 12 : "InvalidInstructionData";
		const TAKEN = tokenProgram === TOKEN ? null : "InvalidInstructionData";
		const MISSING = "NotEnoughAccountKeys";
		const WRONG_PROGRAM = "IncorrectProgramId";
		const FOREIGN_WRITE = "ExternalAccountDataModified";
		const answer = (expected) => expected === null ? null
			: typeof expected === "number" ? custom(expected, tokenProgram) : { error: expected, by: tokenProgram };
		const ask = (step, metas, data, legacy, extended = legacy) => t.forward(step, tokenProgram, metas, data,
			answer(tokenProgram === TOKEN ? legacy : extended));
		const misdirected = (step, metas, data, legacy) => ask(step, metas, data, legacy, WRONG_PROGRAM);
		const bytes = (...parts) => concat(...parts.map((part) => typeof part === "number" ? new Uint8Array([part]) : part));
		const w = (account) => t.meta(account, true);
		const r = (account) => t.meta(account, false);
		const blank = async (length = 165, owningProgram = tokenProgram) => {
			const made = (await t.fresh()).address;
			t.put(made, new Uint8Array(length), owningProgram);
			return made;
		};
		const mintOf = async (owningProgram) => {
			const made = (await t.fresh()).address;
			t.put(made, mintData(t.owner.address, 6, 1_000_000), owningProgram);
			return made;
		};
		const mint = await t.mint(6, 1_000_000);
		const foreignMint = await mintOf(other);
		const probeMint = await mintOf(program);
		const held = await t.token(mint, t.owner.address, 900);
		const frozen = await t.token(mint, t.owner.address, 900, { state: 2 });
		const ofForeignMint = await t.token(foreignMint, t.owner.address, 900);
		const foreign = await t.token(mint, t.owner.address, 900, {}, other);
		const foreignFrozen = await t.token(mint, t.owner.address, 900, { state: 2 }, other);
		const probeOwned = await t.token(mint, t.owner.address, 900, {}, program);
		const owner = t.meta(t.owner.address, false, true);
		const stranger = t.meta(t.payer.address, false, true);
		const delegate = t.meta((await t.fresh()).address, false);
		const ownerKey = encoder.encode(t.owner.address);
		const next = encoder.encode(t.payer.address);
		const burn = (amount) => bytes(8, u64(amount));
		const approve = (amount, decimals = 6) => bytes(13, u64(amount), decimals);
		const init = bytes(18, ownerKey);

		const burning = [w(held), w(mint), owner];
		const approving = [w(held), r(mint), delegate, owner];
		const naming = [w(mint), owner];
		for (const [what, metas, data] of [
			["Burn without its amount", burning, bytes(8)],
			["Burn with 7 bytes of amount", burning, bytes(8, new Uint8Array(7))],
			["BurnChecked without its amount", burning, bytes(15)],
			["BurnChecked without its decimals", burning, bytes(15, u64(1))],
			["ApproveChecked without its amount", approving, bytes(13)],
			["ApproveChecked without its decimals", approving, bytes(13, u64(1))],
			["SetAuthority without its type", naming, bytes(6)],
			["SetAuthority without its option tag", naming, bytes(6, 0)],
			["SetAuthority with an option tag and no key", naming, bytes(6, 0, 1)],
			["SetAuthority with 31 bytes of key", naming, bytes(6, 0, 1, new Uint8Array(31))],
			["SetAuthority with option tag 2", naming, bytes(6, 0, 2, new Uint8Array(32))],
			["InitializeAccount3 without its owner", [w(await blank()), r(mint)], bytes(18)],
			["InitializeAccount3 with 31 bytes of owner", [w(await blank()), r(mint)], bytes(18, ownerKey.subarray(0, 31))],
		]) {
			await ask(what, metas, data, SHORT);
			await ask(`${what} and its last account`, metas.slice(0, -1), data, SHORT);
		}
		await ask("SetAuthority with authority type 200", naming, bytes(6, 200, 0), 12);
		await ask("Burn without its authority", [w(held), w(mint)], burn(1), MISSING);
		await ask("Burn from a blank account without its authority", [w(await blank()), w(mint)], burn(1), MISSING);
		await ask("ApproveChecked without its owner", [w(held), r(mint), delegate], approve(1), MISSING);
		await ask("ApproveChecked on a frozen account without its owner", [w(frozen), r(mint), delegate], approve(1), MISSING);
		await ask("Revoke without its owner", [w(held)], bytes(5), MISSING);
		await ask("Revoke on a blank account without its owner", [w(await blank())], bytes(5), "UninitializedAccount", MISSING);
		await ask("SetAuthority without its authority", [w(mint)], bytes(6, 0, 0), MISSING);
		await ask("SetAuthority on an account of 100 bytes without its authority", [w(await blank(100))], bytes(6, 0, 0), MISSING);
		await ask("InitializeAccount3 without its mint", [w(await blank())], init, MISSING);
		await ask("InitializeAccount3 of an initialized account without its mint", [w(held)], init, MISSING);

		const target = await t.token(mint, t.owner.address, 0);
		const spare = await t.token(mint, t.owner.address, 0);
		await ask("Burn with a byte after its amount", [w(held), w(mint), owner], bytes(burn(1), 0), TAKEN);
		await ask("BurnChecked with a byte after its decimals", [w(held), w(mint), owner], bytes(15, u64(1), 6, 0), TAKEN);
		await ask("ApproveChecked with a byte after its decimals", [w(held), r(mint), delegate, owner], bytes(approve(1), 0), TAKEN);
		await ask("InitializeAccount3 with a byte after its owner", [w(await blank()), r(mint)], bytes(init, 0), TAKEN);
		await ask("MintTo with a byte after its amount", [w(mint), w(target), owner], bytes(7, u64(1), 0), TAKEN);
		await ask("Transfer with a byte after its amount", [w(held), w(target), owner], bytes(3, u64(1), 0), TAKEN);
		await ask("TransferChecked with a byte after its decimals", [w(held), r(mint), w(target), owner], bytes(12, u64(1), 6, 0), TAKEN);
		await ask("Revoke with bytes after its tag", [w(held), owner], bytes(5, 1, 2, 3), null);
		await ask("CloseAccount with a byte after its tag", [w(spare), w(held), owner], bytes(9, 0), null);
		await ask("SetAuthority to none with bytes after the tag", [w(await t.mint(6, 1)), owner], bytes(6, 0, 0, 9, 9), null);
		await ask("SetAuthority with a byte after its key", [w(await t.mint(6, 1)), owner], bytes(6, 0, 1, next, 0), null);
		await ask("InitializeMint2 with a byte after its freeze tag", [w(await blank(82))], bytes(20, 6, ownerKey, 0, 0), null);

		await misdirected("Burn from an account of the other token program", [w(foreign), w(mint), owner], burn(1), FOREIGN_WRITE);
		await misdirected("Burn of nothing from an account of the other token program", [w(foreign), w(mint), owner], burn(0), WRONG_PROGRAM);
		await misdirected("Burn beyond the balance of an account of the other token program", [w(foreign), w(mint), owner], burn(901), 1);
		await misdirected("Burn by a stranger from an account of the other token program", [w(foreign), w(mint), stranger], burn(1), 4);
		await misdirected("Burn from a frozen account of the other token program", [w(foreignFrozen), w(mint), owner], burn(1), 17);
		await misdirected("Burn from an account a program that is no token program owns", [w(probeOwned), w(mint), owner], burn(1), FOREIGN_WRITE);
		await misdirected("Burn against a mint of the other token program", [w(ofForeignMint), w(foreignMint), owner], burn(1), FOREIGN_WRITE);
		await misdirected("Burn of nothing against a mint of the other token program", [w(ofForeignMint), w(foreignMint), owner], burn(0), WRONG_PROGRAM);
		await misdirected("Burn beyond the balance against a mint of the other token program", [w(ofForeignMint), w(foreignMint), owner], burn(901), 1);
		await misdirected("Burn from a blank account of the other token program", [w(await blank(165, other)), w(mint), owner], burn(0), "UninitializedAccount");
		await ask("Burn without its amount from an account of the other token program", [w(foreign), w(mint), owner], bytes(8), SHORT);
		await misdirected("BurnChecked with wrong decimals from an account of the other token program", [w(foreign), w(mint), owner], bytes(15, u64(1), 5), 18);
		await misdirected("BurnChecked with wrong decimals against a mint of the other token program", [w(ofForeignMint), w(foreignMint), owner], bytes(15, u64(1), 5), 18);

		const foreignLent = await t.token(mint, t.owner.address, 900, { delegate: delegate.address, allowance: 5 }, other);
		await misdirected("ApproveChecked on an account of the other token program", [w(foreign), r(mint), delegate, owner], approve(1), FOREIGN_WRITE);
		await misdirected("ApproveChecked of the delegate and allowance an account of the other token program has", [w(foreignLent), r(mint), delegate, owner], approve(5), null);
		await misdirected("ApproveChecked by a stranger on an account of the other token program", [w(foreign), r(mint), delegate, stranger], approve(1), 4);
		await misdirected("ApproveChecked with wrong decimals on an account of the other token program", [w(foreign), r(mint), delegate, owner], approve(1, 5), 18);
		await misdirected("ApproveChecked on a frozen account of the other token program", [w(foreignFrozen), r(mint), delegate, owner], approve(1), 17);
		await misdirected("ApproveChecked with wrong decimals against a mint of the other token program", [w(ofForeignMint), r(foreignMint), delegate, owner], approve(1, 5), 18);
		await misdirected("ApproveChecked against a mint of the other token program", [w(ofForeignMint), r(foreignMint), delegate, owner], approve(1), null);
		await misdirected("ApproveChecked on an account a program that is no token program owns", [w(probeOwned), r(mint), delegate, owner], approve(1), FOREIGN_WRITE);
		await misdirected("ApproveChecked against a mint a program that is no token program owns", [w(await t.token(probeMint, t.owner.address, 9)), r(probeMint), delegate, owner], approve(1), null);

		await misdirected("Revoke on an account of the other token program that has no delegate", [w(foreign), owner], bytes(5), null);
		await misdirected("Revoke on an account of the other token program that has a delegate", [w(foreignLent), owner], bytes(5), FOREIGN_WRITE);
		await misdirected("Revoke by a stranger on an account of the other token program", [w(foreign), stranger], bytes(5), 4);
		await misdirected("Revoke on a frozen account of the other token program", [w(foreignFrozen), owner], bytes(5), 17);
		await misdirected("Revoke on a blank account of the other token program", [w(await blank(165, other)), owner], bytes(5), "UninitializedAccount");
		await ask("Revoke on a frozen account", [w(frozen), owner], bytes(5), 17);

		await misdirected("SetAuthority on a mint of the other token program", [w(foreignMint), owner], bytes(6, 0, 1, next), FOREIGN_WRITE);
		await misdirected("SetAuthority to the authority a mint of the other token program has", [w(foreignMint), owner], bytes(6, 0, 1, ownerKey), null);
		await misdirected("SetAuthority by a stranger on a mint of the other token program", [w(foreignMint), stranger], bytes(6, 0, 1, next), 4);
		await misdirected("SetAuthority of an unsupported type on a mint of the other token program", [w(foreignMint), owner], bytes(6, 2, 1, next), 15);
		await misdirected("SetAuthority of a freeze authority a mint of the other token program lacks", [w(foreignMint), owner], bytes(6, 1, 1, next), 16);
		await misdirected("SetAuthority on an account of the other token program", [w(foreign), owner], bytes(6, 2, 1, next), FOREIGN_WRITE);
		await misdirected("SetAuthority to the owner an account of the other token program has", [w(foreign), owner], bytes(6, 2, 1, ownerKey), null);
		await misdirected("SetAuthority by a stranger on an account of the other token program", [w(foreign), stranger], bytes(6, 2, 1, next), 4);
		await misdirected("SetAuthority on a frozen account of the other token program", [w(foreignFrozen), owner], bytes(6, 2, 1, next), 17);
		await misdirected("SetAuthority on a blank account of the other token program", [w(await blank(165, other)), owner], bytes(6, 2, 1, next), "UninitializedAccount");
		await misdirected("SetAuthority on a mint a program that is no token program owns", [w(probeMint), owner], bytes(6, 0, 1, next), FOREIGN_WRITE);
		await misdirected("SetAuthority on an account of 100 bytes of the other token program", [w(await blank(100, other)), owner], bytes(6, 0, 1, next), "InvalidArgument");
		await ask("SetAuthority on an account of 100 bytes", [w(await blank(100)), owner], bytes(6, 0, 1, next), "InvalidArgument", "InvalidAccountData");

		await misdirected("InitializeAccount3 of an account of the other token program", [w(await blank(165, other)), r(mint)], init, FOREIGN_WRITE);
		await misdirected("InitializeAccount3 of an account of the other token program for a mint of it", [w(await blank(165, other)), r(foreignMint)], init, WRONG_PROGRAM);
		await misdirected("InitializeAccount3 for a mint of the other token program", [w(await blank()), r(foreignMint)], init, WRONG_PROGRAM);
		await misdirected("InitializeAccount3 of an initialized account of the other token program", [w(foreign), r(mint)], init, 6);
		await misdirected("InitializeAccount3 of 164 bytes of the other token program", [w(await blank(164, other)), r(mint)], init, "InvalidAccountData");
		await misdirected("InitializeAccount3 of an account of the other token program for a blank mint", [w(await blank(165, other)), r(await blank(82))], init, 2);
		await misdirected("InitializeAccount3 of an account a program that is no token program owns", [w(await blank(165, program)), r(mint)], init, FOREIGN_WRITE);
		await misdirected("InitializeAccount3 for a mint a program that is no token program owns", [w(await blank()), r(probeMint)], init, WRONG_PROGRAM);
	});

	await scenario(`${name}: mint`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const foreignWrite = { error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram };
		const mint = await t.mint(6, 1_000_000);
		const metas = (mintAccount, to, authority, signs = true) => [
			t.meta(mintAccount, true),
			t.meta(to, true),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const amountOf = (account) => tokenFields(t.svm.getAccount(account)).amount;
		const held = await t.token(mint, t.payer.address, 0);
		await t.send("by the mint authority", OP.mint, metas(mint, held, t.owner.address), u64(500));
		t.check("the account holds 500 and the supply rose by 500",
			amountOf(held) === 500n && supplyOf(t.svm.getAccount(mint)) === 1_000_500n);
		await t.send("by a signer that is not the mint authority", OP.mint, metas(mint, held, t.payer.address), u64(1),
			custom(4, tokenProgram));
		await t.send("by a mint authority that did not sign", OP.mint, metas(mint, held, t.owner.address, false),
			u64(1), { error: "PrivilegeEscalation", by: program });
		await t.forward("by a mint authority the instruction does not mark as a signer", tokenProgram,
			metas(mint, held, t.owner.address, false).slice(0, 3), concat(new Uint8Array([7]), u64(1)),
			{ error: "MissingRequiredSignature", by: tokenProgram });
		const elsewhere = await t.mint(6, 1_000_000);
		await t.send("to an account of another mint", OP.mint, metas(elsewhere, held, t.owner.address), u64(1),
			custom(3, tokenProgram));
		const frozen = await t.token(mint, t.payer.address, 0, { state: 2 });
		await t.send("to a frozen account", OP.mint, metas(mint, frozen, t.owner.address), u64(1),
			custom(17, tokenProgram));
		const native = await t.token(mint, t.payer.address, 0, { nativeReserve: 2_039_280 });
		await t.send("to a native account", OP.mint, metas(mint, native, t.owner.address), u64(1),
			custom(10, tokenProgram));
		const fixed = await t.mint(6, 1_000_000, [], { authority: null });
		const ofFixed = await t.token(fixed, t.payer.address, 0);
		await t.send("of a mint with no mint authority", OP.mint, metas(fixed, ofFixed, t.owner.address), u64(1),
			custom(5, tokenProgram));
		const full = await t.mint(6, 0xffff_ffff_ffff_ffffn);
		const ofFull = await t.token(full, t.payer.address, 0);
		await t.send("beyond a supply of 2^64 - 1", OP.mint, metas(full, ofFull, t.owner.address), u64(1),
			custom(14, tokenProgram));
		const foreign = await t.token(mint, t.payer.address, 0, {}, other);
		await t.send("to an account of the other token program", OP.mint, metas(mint, foreign, t.owner.address), u64(1),
			foreignWrite);
		const foreignMint = (await t.fresh()).address;
		t.put(foreignMint, mintData(t.owner.address, 6, 0), other);
		const ofForeign = await t.token(foreignMint, t.payer.address, 0);
		await t.send("of a mint of the other token program, sent raw", OP.mintRaw,
			metas(foreignMint, ofForeign, t.owner.address), u64(1), foreignWrite);
		const blank = (await t.fresh()).address;
		t.put(blank, new Uint8Array(165));
		await t.send("to an account that is not initialized", OP.mintRaw, metas(mint, blank, t.owner.address), u64(1),
			{ error: "UninitializedAccount", by: tokenProgram });
		const unminted = (await t.fresh()).address;
		t.put(unminted, new Uint8Array(82));
		const ofUnminted = await t.token(unminted, t.payer.address, 0);
		await t.send("of a mint that is not initialized", OP.mintRaw, metas(unminted, ofUnminted, t.owner.address),
			u64(1), { error: "UninitializedAccount", by: tokenProgram });
		await t.send("to a mint in the account's place", OP.mintRaw, metas(mint, elsewhere, t.owner.address), u64(1),
			{ error: "InvalidAccountData", by: tokenProgram });
		const ofHeld = await t.token(held, t.payer.address, 0);
		await t.send("of a token account in the mint's place", OP.mintRaw, metas(held, ofHeld, t.owner.address), u64(1),
			{ error: "InvalidAccountData", by: tokenProgram });
		t.check("the refusals changed nothing", amountOf(held) === 500n && amountOf(frozen) === 0n
			&& amountOf(foreign) === 0n && supplyOf(t.svm.getAccount(mint)) === 1_000_500n);
		const shortData = tokenProgram === TOKEN ? custom(12, tokenProgram) : { error: "InvalidInstructionData", by: tokenProgram };

		const frozenNative = await t.token(mint, t.payer.address, 0, { state: 2, nativeReserve: 2_039_280 });
		await t.send("to a frozen native account", OP.mint, metas(mint, frozenNative, t.owner.address), u64(1),
			custom(17, tokenProgram));
		const nativeElsewhere = await t.token(elsewhere, t.payer.address, 0, { nativeReserve: 2_039_280 });
		await t.send("to a native account of another mint", OP.mint, metas(mint, nativeElsewhere, t.owner.address),
			u64(1), custom(10, tokenProgram));
		await t.send("to an account of another mint, by a signer that is not the mint authority", OP.mint,
			metas(elsewhere, held, t.payer.address), u64(1), custom(3, tokenProgram));
		await t.send("beyond the supply, by a signer that is not the mint authority", OP.mint,
			metas(full, ofFull, t.payer.address), u64(1), custom(4, tokenProgram));
		const foreignFrozen = await t.token(mint, t.payer.address, 0, { state: 2 }, other);
		await t.send("to a frozen account of the other token program", OP.mint,
			metas(mint, foreignFrozen, t.owner.address), u64(1),
			tokenProgram === TOKEN ? custom(17, tokenProgram) : { error: "IncorrectProgramId", by: tokenProgram });
		await t.forward("MintTo without its amount", tokenProgram, metas(mint, held, t.owner.address).slice(0, 3),
			new Uint8Array([7]), shortData);
		const brimming = await t.token(mint, t.payer.address, 0xffff_ffff_ffff_ffffn);
		await t.send("beyond an account balance of 2^64 - 1", OP.mint, metas(mint, brimming, t.owner.address), u64(2),
			tokenProgram === TOKEN ? null : custom(14, tokenProgram));
		t.check(`the account balance ${tokenProgram === TOKEN ? "wraps to 1" : "is kept"}`,
			amountOf(brimming) === (tokenProgram === TOKEN ? 1n : 0xffff_ffff_ffff_ffffn));
		await t.send("of nothing", OP.mint, metas(mint, held, t.owner.address), u64(0));
		await t.send("of nothing, to an account of the other token program", OP.mint,
			metas(mint, foreign, t.owner.address), u64(0), { error: "IncorrectProgramId", by: tokenProgram });

		const [authority] = await getProgramDerivedAddress({ programAddress: program, seeds: ["authority"] });
		const governed = await t.mint(6, 0, [], { authority });
		const ofGoverned = await t.token(governed, t.payer.address, 0);
		await t.send("by a PDA of the program", OP.mintAsPda, metas(governed, ofGoverned, authority, false), u64(70));
		t.check("the PDA minted 70", amountOf(ofGoverned) === 70n && supplyOf(t.svm.getAccount(governed)) === 70n);
		await t.send("as a PDA the seeds do not derive", OP.mintAsPda, metas(mint, held, t.owner.address, false), u64(1),
			custom(2006, program));
	});

	await scenario(`${name}: transfer`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const foreignWrite = { error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram };
		const mint = await t.mint(6, 1_000_000);
		const metas = (from, to, authority, signs = true, mintAccount = mint) => [
			t.meta(from, true),
			t.meta(to, true),
			t.meta(mintAccount, false),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const checked = (amount, decimals = 6) => concat(u64(amount), new Uint8Array([decimals]));
		const fieldsOf = (account) => tokenFields(t.svm.getAccount(account));
		const source = await t.token(mint, t.owner.address, 900);
		const destination = await t.token(mint, t.payer.address, 0);
		await t.send("by the owner", OP.transfer, metas(source, destination, t.owner.address), u64(250));
		t.check("250 moved", fieldsOf(source).amount === 650n && fieldsOf(destination).amount === 250n);
		await t.send("more than the account holds", OP.transfer, metas(source, destination, t.owner.address), u64(651),
			custom(1, tokenProgram));
		await t.send("by a signer that is neither owner nor delegate", OP.transfer,
			metas(source, destination, t.payer.address), u64(1), custom(4, tokenProgram));
		await t.send("by an owner that did not sign", OP.transfer, metas(source, destination, t.owner.address, false),
			u64(1), { error: "PrivilegeEscalation", by: program });
		const unsigned = [t.meta(source, true), t.meta(mint, false), t.meta(destination, true), t.meta(t.owner.address, false)];
		await t.forward("by an owner the instruction does not mark as a signer", tokenProgram, unsigned,
			concat(new Uint8Array([12]), checked(1)), { error: "MissingRequiredSignature", by: tokenProgram });
		await t.send("with decimals that are not the mint's", OP.transferRaw,
			metas(source, destination, t.owner.address), checked(1, 5), custom(18, tokenProgram));
		const elsewhere = await t.mint(6, 1_000_000);
		await t.send("against another mint", OP.transfer, metas(source, destination, t.owner.address, true, elsewhere),
			u64(1), custom(3, tokenProgram));
		const ofElsewhere = await t.token(elsewhere, t.payer.address, 0);
		await t.send("to an account of another mint", OP.transfer, metas(source, ofElsewhere, t.owner.address), u64(1),
			custom(3, tokenProgram));
		const frozen = await t.token(mint, t.owner.address, 900, { state: 2 });
		await t.send("from a frozen account", OP.transfer, metas(frozen, destination, t.owner.address), u64(1),
			custom(17, tokenProgram));
		await t.send("to a frozen account", OP.transfer, metas(source, frozen, t.owner.address), u64(1),
			custom(17, tokenProgram));
		const foreign = await t.token(mint, t.owner.address, 900, {}, other);
		await t.send("from an account of the other token program", OP.transfer,
			metas(foreign, destination, t.owner.address), u64(1), foreignWrite);
		await t.send("to an account of the other token program", OP.transfer,
			metas(source, foreign, t.owner.address), u64(1), foreignWrite);
		await t.send("of nothing, to an account of the other token program", OP.transfer,
			metas(source, foreign, t.owner.address), u64(0), { error: "IncorrectProgramId", by: tokenProgram });
		const foreignMint = (await t.fresh()).address;
		t.put(foreignMint, mintData(t.owner.address, 6, 0), other);
		const fromForeignMint = await t.token(foreignMint, t.owner.address, 900);
		const toForeignMint = await t.token(foreignMint, t.payer.address, 0);
		await t.send("against a mint of the other token program, sent raw", OP.transferRaw,
			metas(fromForeignMint, toForeignMint, t.owner.address, true, foreignMint), checked(1),
			tokenProgram === TOKEN ? null : { error: "IncorrectProgramId", by: tokenProgram });
		t.check(`the mint's owner ${tokenProgram === TOKEN ? "is not checked: 1 moved" : "is checked: nothing moved"}`,
			fieldsOf(toForeignMint).amount === (tokenProgram === TOKEN ? 1n : 0n));
		const blank = (await t.fresh()).address;
		t.put(blank, new Uint8Array(165));
		await t.send("from an account that is not initialized", OP.transferRaw,
			metas(blank, destination, t.owner.address), checked(1), { error: "UninitializedAccount", by: tokenProgram });
		await t.send("to an account that is not initialized", OP.transferRaw,
			metas(source, blank, t.owner.address), checked(1), { error: "UninitializedAccount", by: tokenProgram });
		await t.send("to a mint in the account's place", OP.transferRaw,
			metas(source, elsewhere, t.owner.address), checked(1), { error: "InvalidAccountData", by: tokenProgram });
		await t.send("to itself, refused before the CPI", OP.transfer, metas(source, source, t.owner.address), u64(100),
			custom(2040, program));
		await t.send("to itself, sent raw", OP.transferRaw, metas(source, source, t.owner.address), checked(100));
		await t.send("to itself, more than the account holds", OP.transferRaw, metas(source, source, t.owner.address),
			checked(651), custom(1, tokenProgram));
		await t.send("to itself, by a signer that is not the owner", OP.transferRaw,
			metas(source, source, t.payer.address), checked(1), custom(4, tokenProgram));
		t.check("the refusals and the transfer to itself changed nothing", fieldsOf(source).amount === 650n
			&& fieldsOf(destination).amount === 250n && fieldsOf(frozen).amount === 900n
			&& fieldsOf(foreign).amount === 900n);

		await t.send("from a frozen account, more than it holds", OP.transfer,
			metas(frozen, destination, t.owner.address), u64(901), custom(17, tokenProgram));
		await t.send("more than the account holds, to an account of another mint", OP.transfer,
			metas(source, ofElsewhere, t.owner.address), u64(651), custom(1, tokenProgram));
		await t.send("more than the account holds, against another mint", OP.transfer,
			metas(source, destination, t.owner.address, true, elsewhere), u64(651), custom(1, tokenProgram));
		await t.send("to an account of another mint, by a signer that is not the owner", OP.transfer,
			metas(source, ofElsewhere, t.payer.address), u64(1), custom(tokenProgram === TOKEN ? 3 : 4, tokenProgram));
		await t.send("with decimals that are not the mint's, by a signer that is not the owner", OP.transferRaw,
			metas(source, destination, t.payer.address), checked(1, 5), custom(18, tokenProgram));
		await t.send("to a frozen account, by a signer that is not the owner", OP.transfer,
			metas(source, frozen, t.payer.address), u64(1), custom(tokenProgram === TOKEN ? 17 : 4, tokenProgram));
		await t.send("more than the account holds, to an account that is not initialized", OP.transferRaw,
			metas(source, blank, t.owner.address), checked(651),
			tokenProgram === TOKEN ? { error: "UninitializedAccount", by: tokenProgram } : custom(1, tokenProgram));
		const foreignFrozen = await t.token(mint, t.owner.address, 900, { state: 2 }, other);
		await t.send("from a frozen account of the other token program", OP.transfer,
			metas(foreignFrozen, destination, t.owner.address), u64(1),
			tokenProgram === TOKEN ? custom(17, tokenProgram) : { error: "IncorrectProgramId", by: tokenProgram });
		await t.send("from an account of the other token program, by a signer that is not the owner", OP.transfer,
			metas(foreign, destination, t.payer.address), u64(1),
			tokenProgram === TOKEN ? custom(4, tokenProgram) : { error: "IncorrectProgramId", by: tokenProgram });
		await t.forward("TransferChecked without its decimals", tokenProgram, [unsigned[0], unsigned[1], unsigned[2],
			t.meta(t.owner.address, false, true)], concat(new Uint8Array([12]), u64(1)),
			tokenProgram === TOKEN ? custom(12, tokenProgram) : { error: "InvalidInstructionData", by: tokenProgram });
		const brimming = await t.token(mint, t.payer.address, 0xffff_ffff_ffff_ffffn);
		const spending = await t.token(mint, t.owner.address, 10);
		await t.send("beyond an account balance of 2^64 - 1", OP.transfer, metas(spending, brimming, t.owner.address),
			u64(2), tokenProgram === TOKEN ? null : custom(14, tokenProgram));
		t.check(`the account balance ${tokenProgram === TOKEN ? "wraps to 1" : "is kept"}`,
			fieldsOf(brimming).amount === (tokenProgram === TOKEN ? 1n : 0xffff_ffff_ffff_ffffn));
		const hollow = await t.token(mint, t.owner.address, 5000, { nativeReserve: 2_039_280 });
		t.svm.setAccount({ ...t.svm.getAccount(hollow), lamports: lamports(1000n) });
		await t.send("from a native account whose lamports do not cover the amount", OP.transfer,
			metas(hollow, destination, t.owner.address), u64(2000),
			tokenProgram === TOKEN ? { error: "UnbalancedInstruction", by: program } : custom(14, tokenProgram));
		await t.send("of nothing", OP.transfer, metas(source, destination, t.owner.address), u64(0));

		const unchecked = [t.meta(source, true), t.meta(destination, true), t.meta(t.owner.address, false, true)];
		await t.forward("Transfer, without the mint", tokenProgram, unchecked, concat(new Uint8Array([3]), u64(50)));
		t.check("50 more moved", fieldsOf(source).amount === 600n && fieldsOf(destination).amount === 300n);
		await t.forward("Transfer of more than the account holds", tokenProgram, unchecked,
			concat(new Uint8Array([3]), u64(601)), custom(1, tokenProgram));
		await t.forward("Transfer to an account of another mint", tokenProgram,
			[unchecked[0], t.meta(ofElsewhere, true), unchecked[2]], concat(new Uint8Array([3]), u64(1)),
			custom(3, tokenProgram));

		const reserve = 2_039_280n;
		const wrappedFrom = await t.token(mint, t.owner.address, 5000, { nativeReserve: reserve });
		const wrappedTo = await t.token(mint, t.payer.address, 0, { nativeReserve: reserve });
		t.svm.setAccount({ ...t.svm.getAccount(wrappedFrom), lamports: lamports(reserve + 5000n) });
		await t.send("between native accounts", OP.transfer, metas(wrappedFrom, wrappedTo, t.owner.address), u64(2000));
		t.check("the lamports moved with the amount",
			fieldsOf(wrappedFrom).amount === 3000n && fieldsOf(wrappedTo).amount === 2000n
				&& t.svm.getAccount(wrappedFrom).lamports === reserve + 3000n
				&& t.svm.getAccount(wrappedTo).lamports === reserve + 2000n);
		const plainLamports = t.svm.getAccount(destination).lamports;
		await t.send("from a native account to one that is not", OP.transfer,
			metas(wrappedFrom, destination, t.owner.address), u64(1));
		t.check("the source's native flag alone moves the lamports",
			t.svm.getAccount(wrappedFrom).lamports === reserve + 2999n
				&& t.svm.getAccount(destination).lamports === plainLamports + 1n && fieldsOf(destination).amount === 301n);
		await t.send("to a native account from one that is not", OP.transfer,
			metas(source, wrappedTo, t.owner.address), u64(1));
		t.check("no lamports move from a source that is not native",
			t.svm.getAccount(wrappedTo).lamports === reserve + 2000n && fieldsOf(wrappedTo).amount === 2001n);

		const [authority] = await getProgramDerivedAddress({ programAddress: program, seeds: ["authority"] });
		const vault = await t.token(mint, authority, 400);
		await t.send("by a PDA of the program", OP.transferAsPda, metas(vault, destination, authority, false), u64(400));
		t.check("the PDA's account is empty", fieldsOf(vault).amount === 0n && fieldsOf(destination).amount === 701n);
		await t.send("as a PDA the seeds do not derive", OP.transferAsPda,
			metas(source, destination, t.owner.address, false), u64(1), custom(2006, program));
	});

	await scenario(`${name}: close`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const foreignWrite = { error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram };
		const mint = await t.mint(6, 1_000_000);
		const metas = (closing, destination, authority, signs = true) => [
			t.meta(closing, true),
			t.meta(destination, true),
			t.meta(authority, false, signs),
			t.meta(tokenProgram, false),
		];
		const rent = t.svm.minimumBalanceForRentExemption(165n);
		const lamportsOf = (account) => t.svm.getAccount(account).lamports;
		const gone = (account) => !t.svm.getAccount(account).exists;
		const receiver = (await t.fresh()).address;
		t.svm.airdrop(receiver, lamports(1_000_000n));
		const empty = await t.token(mint, t.owner.address, 0);
		const holding = await t.token(mint, t.owner.address, 5);
		await t.send("an account that holds tokens", OP.close, metas(holding, receiver, t.owner.address),
			new Uint8Array(), custom(11, tokenProgram));
		await t.send("by a signer that is not the owner", OP.close, metas(empty, receiver, t.payer.address),
			new Uint8Array(), custom(4, tokenProgram));
		await t.send("by an owner that did not sign", OP.close, metas(empty, receiver, t.owner.address, false),
			new Uint8Array(), { error: "PrivilegeEscalation", by: program });
		await t.forward("by an owner the instruction does not mark as a signer", tokenProgram,
			metas(empty, receiver, t.owner.address, false).slice(0, 3), new Uint8Array([9]),
			{ error: "MissingRequiredSignature", by: tokenProgram });
		await t.send("into itself, refused before the CPI", OP.close, metas(empty, empty, t.owner.address),
			new Uint8Array(), custom(2040, program));
		await t.send("into itself, sent raw", OP.closeRaw, metas(empty, empty, t.owner.address), new Uint8Array(),
			{ error: "InvalidAccountData", by: tokenProgram });
		const lent = await t.token(mint, t.owner.address, 0, { delegate: t.payer.address, allowance: 300 });
		await t.send("by a delegate", OP.close, metas(lent, receiver, t.payer.address), new Uint8Array(),
			custom(4, tokenProgram));
		const foreign = await t.token(mint, t.owner.address, 0, {}, other);
		await t.send("an account of the other token program, sent raw", OP.closeRaw,
			metas(foreign, receiver, t.owner.address), new Uint8Array(),
			tokenProgram === TOKEN ? { error: "ExternalAccountLamportSpend", by: tokenProgram } : foreignWrite);
		const blank = (await t.fresh()).address;
		t.put(blank, new Uint8Array(165));
		await t.send("an account that is not initialized", OP.closeRaw, metas(blank, receiver, t.owner.address),
			new Uint8Array(), { error: "UninitializedAccount", by: tokenProgram });
		await t.send("a mint", OP.closeRaw, metas(mint, receiver, t.owner.address), new Uint8Array(),
			{ error: "InvalidAccountData", by: tokenProgram });
		await t.send("an account that holds tokens, by a signer that is not the owner", OP.close,
			metas(holding, receiver, t.payer.address), new Uint8Array(), custom(11, tokenProgram));
		const foreignHolding = await t.token(mint, t.owner.address, 5, {}, other);
		await t.send("an account of the other token program that holds tokens, sent raw", OP.closeRaw,
			metas(foreignHolding, receiver, t.owner.address), new Uint8Array(),
			tokenProgram === TOKEN ? custom(11, tokenProgram) : { error: "IncorrectProgramId", by: tokenProgram });
		await t.send("an account that is not initialized, into itself", OP.closeRaw,
			metas(blank, blank, t.owner.address), new Uint8Array(), { error: "InvalidAccountData", by: tokenProgram });
		t.check("the refusals closed nothing", lamportsOf(empty) === rent && lamportsOf(holding) === rent
			&& lamportsOf(foreign) === rent && lamportsOf(receiver) === 1_000_000n);

		await t.send("by the owner", OP.close, metas(empty, receiver, t.owner.address), new Uint8Array());
		t.check("the account is gone and its lamports are the receiver's",
			gone(empty) && lamportsOf(receiver) === 1_000_000n + rent);
		const closable = await t.token(mint, t.owner.address, 0, { closeAuthority: t.payer.address });
		await t.send("by the owner of an account that has a close authority", OP.close,
			metas(closable, receiver, t.owner.address), new Uint8Array(), custom(4, tokenProgram));
		await t.send("by the close authority", OP.close, metas(closable, receiver, t.payer.address), new Uint8Array());
		t.check("the close authority closed it", gone(closable));
		const frozen = await t.token(mint, t.owner.address, 0, { state: 2 });
		await t.send("a frozen account that is empty", OP.close, metas(frozen, receiver, t.owner.address),
			new Uint8Array());
		const wrapped = await t.token(mint, t.owner.address, 5000, { nativeReserve: rent });
		t.svm.setAccount({ ...t.svm.getAccount(wrapped), lamports: lamports(rent + 5000n) });
		const before = lamportsOf(receiver);
		await t.send("a native account that holds lamports", OP.close, metas(wrapped, receiver, t.owner.address),
			new Uint8Array());
		t.check("a native account closes with its balance", gone(wrapped) && lamportsOf(receiver) === before + rent + 5000n);
		for (const [what, holder] of [["the System program", SYSTEM], ["the incinerator", INCINERATOR]]) {
			const abandoned = await t.token(mint, holder, 0);
			await t.send(`an account ${what} owns, into another account`, OP.close,
				metas(abandoned, receiver, t.payer.address), new Uint8Array(),
				{ error: "InvalidAccountData", by: tokenProgram });
			t.svm.airdrop(INCINERATOR, lamports(1_000_000n));
			await t.send(`an account ${what} owns, by any signer, into the incinerator`, OP.close,
				metas(abandoned, INCINERATOR, t.payer.address), new Uint8Array());
		}

		const [authority] = await getProgramDerivedAddress({ programAddress: program, seeds: ["authority"] });
		const vault = await t.token(mint, authority, 0);
		await t.send("by a PDA of the program", OP.closeAsPda, metas(vault, receiver, authority, false), new Uint8Array());
		t.check("the PDA's account is gone", gone(vault));
		await t.send("as a PDA the seeds do not derive", OP.closeAsPda, metas(holding, receiver, t.owner.address, false),
			new Uint8Array(), custom(2006, program));
	});

	await scenario(`${name}: InitializeMint2`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const blank = async (length = 82, owningProgram = tokenProgram) => {
			const made = (await t.fresh()).address;
			t.put(made, new Uint8Array(length), owningProgram);
			return made;
		};
		const metas = (target) => [t.meta(target, true), t.meta(tokenProgram, false)];
		const plain = concat(new Uint8Array([6]), encoder.encode(t.owner.address), new Uint8Array([0]));
		const freezing = concat(new Uint8Array([9]), encoder.encode(t.owner.address), new Uint8Array([1]),
			encoder.encode(t.payer.address));
		const target = await blank();
		await t.send("a blank account of the token program", OP.initializeMintRaw, metas(target), plain);
		let stored = t.svm.getAccount(target);
		t.check("the mint has its authority, 6 decimals, no supply and no freeze authority",
			optionalKeyAt(stored, 0) === t.owner.address && stored.data[44] === 6 && stored.data[45] === 1
				&& supplyOf(stored) === 0n && optionalKeyAt(stored, 46) === null && stored.data.length === 82);
		await t.send("a mint that is already initialized", OP.initializeMintRaw, metas(target), plain,
			custom(6, tokenProgram));
		const freezable = await blank();
		await t.send("with a freeze authority", OP.initializeMintRaw, metas(freezable), freezing);
		stored = t.svm.getAccount(freezable);
		t.check("the mint names its freeze authority and 9 decimals",
			optionalKeyAt(stored, 46) === t.payer.address && stored.data[44] === 9);
		const poor = await blank();
		t.svm.setAccount({ ...t.svm.getAccount(poor), lamports: lamports(t.svm.minimumBalanceForRentExemption(82n) - 1n) });
		await t.send("an account below the rent minimum", OP.initializeMintRaw, metas(poor), plain,
			custom(0, tokenProgram));
		t.svm.setAccount({ ...t.svm.getAccount(target), lamports: lamports(1n) });
		await t.send("a mint that is already initialized and below the rent minimum", OP.initializeMintRaw,
			metas(target), plain, custom(tokenProgram === TOKEN ? 6 : 0, tokenProgram));
		await t.forward("InitializeMint2 without its freeze authority tag", tokenProgram, [t.meta(await blank(), true)],
			concat(new Uint8Array([20, 6]), encoder.encode(t.owner.address)),
			tokenProgram === TOKEN ? custom(12, tokenProgram) : { error: "InvalidInstructionData", by: tokenProgram });
		await t.send("an account of 81 bytes", OP.initializeMintRaw, metas(await blank(81)), plain,
			{ error: "InvalidAccountData", by: tokenProgram });
		await t.send("an account of 165 bytes", OP.initializeMintRaw, metas(await blank(165)), plain,
			{ error: "InvalidAccountData", by: tokenProgram });
		await t.send("an account the token program does not own", OP.initializeMintRaw, metas(await blank(82, other)),
			plain, { error: tokenProgram === TOKEN ? "ExternalAccountDataModified" : "IncorrectProgramId", by: tokenProgram });
	});

	await scenario(`${name}: instructions outside the wrappers`, tokenProgram, async (t) => {
		const mint = await t.mint(6, 1_000_000);
		await t.forward("an instruction byte the token program does not know", tokenProgram, [t.meta(mint, true)],
			new Uint8Array([200]), custom(12, tokenProgram));
		await t.forward("no instruction data", tokenProgram, [t.meta(mint, true)], new Uint8Array(),
			custom(12, tokenProgram));
		await t.forward("an instruction byte the associated token program does not know", ASSOCIATED_TOKEN,
			[t.meta(mint, true)], new Uint8Array([3]), { error: "InvalidInstructionData", by: ASSOCIATED_TOKEN });
		await t.forward("a System instruction tag it does not know", SYSTEM, [t.meta(t.payer.address, true, true)],
			new Uint8Array([99, 0, 0, 0]), { error: "InvalidInstructionData", by: SYSTEM });
		await t.forward("System instruction data of 3 bytes", SYSTEM, [t.meta(t.payer.address, true, true)],
			new Uint8Array([2, 0, 0]), { error: "InvalidInstructionData", by: SYSTEM });
	});

	await scenario(`${name}: associated token account`, tokenProgram, async (t) => {
		const other = tokenProgram === TOKEN ? TOKEN_2022 : TOKEN;
		const length = tokenProgram === TOKEN ? 165 : 170;
		const mint = await t.mint(6, 1_000_000);
		const addressOf = async (wallet, mintAccount, tokenProgramSeed = tokenProgram) => (await getProgramDerivedAddress({
			programAddress: ASSOCIATED_TOKEN,
			seeds: [encoder.encode(wallet), encoder.encode(tokenProgramSeed), encoder.encode(mintAccount)],
		}))[0];
		const associated = await addressOf(t.owner.address, mint);
		const metas = (target = associated, fields = {}) => {
			const { wallet = t.owner.address, mintAccount = mint, systemSlot = SYSTEM, tokenSlot = tokenProgram } = fields;
			return [
				t.meta(t.payer.address, true, true),
				t.meta(target, true),
				t.meta(wallet, false),
				t.meta(mintAccount, false),
				t.meta(systemSlot, false),
				t.meta(tokenSlot, false),
				t.meta(ASSOCIATED_TOKEN, false),
				t.meta(SYSTEM, false),
			];
		};
		const none = new Uint8Array();
		await t.send("with another account in the system program's place", OP.createAssociatedRaw,
			metas(associated, { systemSlot: t.owner.address }), none, { error: "IncorrectProgramId", by: program });
		t.check("nothing was created", !t.svm.getAccount(associated).exists);
		const elsewhere = (await t.fresh()).address;
		for (const [form, op] of [["create", OP.createAssociatedRaw], ["idempotent create", OP.createAssociatedIdempotentRaw]]) {
			await t.send(`${form} at an address the wallet and the mint do not derive`, op, metas(elsewhere), none,
				{ error: "InvalidSeeds", by: ASSOCIATED_TOKEN });
			await t.send(`${form} at the address the other token program's id derives`, op,
				metas(await addressOf(t.owner.address, mint, other)), none, { error: "InvalidSeeds", by: ASSOCIATED_TOKEN });
		}
		await t.send("create with the System program", OP.createAssociatedRaw, metas(), none);
		const stored = t.svm.getAccount(associated);
		t.check("the associated account belongs to the token program and holds the wallet's account of the mint",
			stored.exists && stored.programAddress === tokenProgram && tokenFields(stored).mint === mint
				&& tokenFields(stored).owner === t.owner.address && tokenFields(stored).state === 1);
		t.check(`the associated account is ${length} bytes at the rent minimum`, stored.data.length === length
			&& stored.lamports === t.svm.minimumBalanceForRentExemption(BigInt(length)));
		if (tokenProgram === TOKEN_2022) {
			t.check("it carries the immutable owner extension", stored.data[165] === 2
				&& extensionKinds(stored.data).join(",") === "7");
		}
		await t.send("create where the account exists", OP.createAssociatedRaw, metas(), none,
			{ error: "IllegalOwner", by: ASSOCIATED_TOKEN });
		await t.send("idempotent create where the account exists", OP.createAssociatedIdempotentRaw, metas(), none);

		const second = (await t.fresh()).address;
		const ofSecond = await addressOf(second, mint);
		t.put(ofSecond, tokenData(mint, t.payer.address, 0));
		await t.send("idempotent create where the account at the address has another owner",
			OP.createAssociatedIdempotentRaw, metas(ofSecond, { wallet: second }), none, custom(0, ASSOCIATED_TOKEN));
		const otherMint = await t.mint(6, 1_000_000);
		const third = (await t.fresh()).address;
		const ofThird = await addressOf(third, mint);
		t.put(ofThird, tokenData(otherMint, third, 0));
		await t.send("idempotent create where the account at the address has another mint",
			OP.createAssociatedIdempotentRaw, metas(ofThird, { wallet: third }), none,
			{ error: "InvalidAccountData", by: ASSOCIATED_TOKEN });
		const stranger = (await t.fresh()).address;
		const ofStranger = await addressOf(stranger, mint);
		t.put(ofStranger, tokenData(otherMint, t.payer.address, 0));
		await t.send("idempotent create where the account at the address has another owner and another mint",
			OP.createAssociatedIdempotentRaw, metas(ofStranger, { wallet: stranger }), none, custom(0, ASSOCIATED_TOKEN));
		const fourth = (await t.fresh()).address;
		const ofFourth = await addressOf(fourth, mint);
		t.put(ofFourth, new Uint8Array(165));
		await t.send("idempotent create where the token program's account at the address is not initialized",
			OP.createAssociatedIdempotentRaw, metas(ofFourth, { wallet: fourth }), none,
			{ error: "IllegalOwner", by: ASSOCIATED_TOKEN });
		const fifth = (await t.fresh()).address;
		const ofFifth = await addressOf(fifth, mint);
		t.put(ofFifth, new Uint8Array(0), program);
		for (const [form, op] of [["create", OP.createAssociatedRaw], ["idempotent create", OP.createAssociatedIdempotentRaw]]) {
			await t.send(`${form} where another program owns the address`, op, metas(ofFifth, { wallet: fifth }), none,
				{ error: "IllegalOwner", by: ASSOCIATED_TOKEN });
		}

		const sixth = (await t.fresh()).address;
		const ofSixth = await addressOf(sixth, mint);
		t.svm.airdrop(ofSixth, lamports(1_000_000n));
		const before = t.svm.getAccount(t.payer.address).lamports;
		await t.send("create at a prefunded address", OP.createAssociatedRaw, metas(ofSixth, { wallet: sixth }), none);
		const rent = t.svm.minimumBalanceForRentExemption(BigInt(length));
		t.check("the payer tops the address up to the rent minimum",
			t.svm.getAccount(ofSixth).lamports === rent && t.svm.getAccount(ofSixth).data.length === length
				&& before - t.svm.getAccount(t.payer.address).lamports === rent - 1_000_000n + 5000n);

		const foreignMint = (await t.fresh()).address;
		t.put(foreignMint, mintData(t.owner.address, 6, 0), other);
		await t.send("create for a mint of the other token program", OP.createAssociatedRaw,
			metas(await addressOf(t.owner.address, foreignMint), { mintAccount: foreignMint }), none,
			{ error: "IncorrectProgramId", by: tokenProgram });
		const unminted = (await t.fresh()).address;
		t.put(unminted, new Uint8Array(82));
		await t.send("create for a mint that is not initialized", OP.createAssociatedRaw,
			metas(await addressOf(t.owner.address, unminted), { mintAccount: unminted }), none,
			custom(2, tokenProgram));
		const poor = await t.fresh();
		t.svm.airdrop(poor.address, lamports(1_000_000n));
		const seventh = (await t.fresh()).address;
		const poorMetas = metas(await addressOf(seventh, mint), { wallet: seventh });
		poorMetas[0] = t.meta(poor.address, true, true);
		await t.send("create by a payer that cannot fund it", OP.createAssociatedRaw, poorMetas, none, custom(1, SYSTEM));

		const eighth = (await t.fresh()).address;
		const typed = metas(await addressOf(eighth, mint), { wallet: eighth });
		await t.send("createAssociatedFor", OP.createAssociatedFor, typed, none);
		t.check("the wallet's associated account exists",
			tokenFields(t.svm.getAccount(typed[1].address)).owner === eighth);
		const ninth = (await t.fresh()).address;
		await t.send("createAssociatedFor with the other token program's id", OP.createAssociatedFor,
			metas(await addressOf(ninth, mint), { wallet: ninth, tokenSlot: other }), none, custom(2023, program));

		const native = NATIVE_MINT[tokenProgram];
		if (!t.svm.getAccount(native).exists) t.put(native, mintData(t.owner.address, 9, 0));
		const tenth = (await t.fresh()).address;
		const ofTenth = await addressOf(tenth, native);
		t.svm.airdrop(ofTenth, lamports(rent + 5000n));
		await t.send("create for the native mint at a prefunded address", OP.createAssociatedRaw,
			metas(ofTenth, { wallet: tenth, mintAccount: native }), none);
		t.check("a native associated account holds the lamports above its rent reserve",
			tokenFields(t.svm.getAccount(ofTenth)).nativeReserve === rent
				&& tokenFields(t.svm.getAccount(ofTenth)).amount === 5000n);

		const eleventh = (await t.fresh()).address;
		const forwarded = metas(await addressOf(eleventh, mint), { wallet: eleventh }).slice(0, 6);
		await t.forward("create sent with no instruction data", ASSOCIATED_TOKEN, forwarded, none);
		t.check("no instruction data creates the account", t.svm.getAccount(forwarded[1].address).exists);
		forwarded[0] = t.meta(t.owner.address, true, false);
		const twelfth = (await t.fresh()).address;
		forwarded[1] = t.meta(await addressOf(twelfth, mint), true);
		forwarded[2] = t.meta(twelfth, false);
		await t.forward("create by a payer the instruction does not mark as a signer", ASSOCIATED_TOKEN, forwarded,
			new Uint8Array([0]), { error: "PrivilegeEscalation", by: ASSOCIATED_TOKEN });
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

for (const extensions of [[1], [3], [6], [9], [14], [26], [1, 3, 14, 26], [1, 9]]) {
	await scenario(`token-2022: a mint with zeroed extensions ${extensions.join(",")}`, TOKEN_2022, async (t) => {
		const mint = await t.mint(6, 0, extensions);
		if (extensions.includes(DEFAULT_ACCOUNT_STATE)) {
			const data = t.svm.getAccount(mint).data.slice();
			data[170] = 1;
			t.put(mint, data);
		}
		const amountOf = (account) => tokenFields(t.svm.getAccount(account)).amount;
		const create = async (holder) => {
			const made = await t.fresh();
			await t.send("create a token account", OP.createAtKeypair, [
				t.meta(t.payer.address, true, true),
				t.meta(made.address, true, true),
				t.meta(mint, false),
				t.meta(SYSTEM, false),
				t.meta(TOKEN_2022, false),
			], encoder.encode(holder));
			return made.address;
		};
		const from = await create(t.owner.address);
		const to = await create(t.payer.address);
		const spare = await create(t.owner.address);
		await t.send("mint", OP.mint, [t.meta(mint, true), t.meta(from, true), t.meta(t.owner.address, false, true),
			t.meta(TOKEN_2022, false)], u64(100));
		t.check("100 minted", amountOf(from) === 100n && supplyOf(t.svm.getAccount(mint)) === 100n);
		const moving = [t.meta(from, true), t.meta(to, true), t.meta(mint, false), t.meta(t.owner.address, false, true),
			t.meta(TOKEN_2022, false)];
		const fixed = extensions.includes(9);
		await t.send("transfer", OP.transfer, moving, u64(40), fixed ? custom(37, TOKEN_2022) : null);
		t.check(fixed ? "a non-transferable mint moves nothing" : "40 moved, with no fee withheld",
			amountOf(from) === (fixed ? 100n : 60n) && amountOf(to) === (fixed ? 0n : 40n));
		const needsMint = [1, 14, 26].some((kind) => extensions.includes(kind));
		await t.forward("Transfer, without the mint", TOKEN_2022, [moving[0], moving[1], moving[3]],
			concat(new Uint8Array([3]), u64(1)), fixed ? custom(37, TOKEN_2022) : needsMint ? custom(31, TOKEN_2022) : null);
		const receiver = (await t.fresh()).address;
		t.svm.airdrop(receiver, lamports(1_000_000n));
		await t.send("close an empty account", OP.close, [t.meta(spare, true), t.meta(receiver, true),
			t.meta(t.owner.address, false, true), t.meta(TOKEN_2022, false)], new Uint8Array());
		t.check("the empty account is gone", !t.svm.getAccount(spare).exists);
		const refusal = fixed ? custom(37, TOKEN_2022) : needsMint ? custom(31, TOKEN_2022) : null;
		if (refusal !== null) {
			const stranger = [moving[0], moving[1], moving[2], t.meta(t.payer.address, false, true)];
			const checked = (amount, decimals) => concat(new Uint8Array([12]), u64(amount), new Uint8Array([decimals]));
			const bare = (metas) => [metas[0], metas[1], metas[3]];
			const plain = (amount) => concat(new Uint8Array([3]), u64(amount));
			if (fixed) {
				await t.forward("TransferChecked beyond the balance", TOKEN_2022, moving.slice(0, 4), checked(1000, 6),
					custom(1, TOKEN_2022));
				await t.forward("TransferChecked with wrong decimals", TOKEN_2022, moving.slice(0, 4), checked(1, 5), refusal);
				const other = await t.mint(6, 0);
				await t.forward("TransferChecked with another mint", TOKEN_2022,
					[moving[0], moving[1], t.meta(other, false), moving[3]], checked(1, 6), refusal);
				await t.forward("TransferChecked by a stranger", TOKEN_2022, stranger, checked(1, 6), refusal);
			}
			await t.forward("Transfer beyond the balance", TOKEN_2022, bare(moving), plain(1000), custom(1, TOKEN_2022));
			await t.forward("Transfer by a stranger", TOKEN_2022, bare(stranger), plain(1), refusal);
			const frozen = t.svm.getAccount(from).data.slice();
			frozen[108] = 2;
			t.put(from, frozen);
			await t.forward("Transfer from a frozen account", TOKEN_2022, bare(moving), plain(1), custom(17, TOKEN_2022));
			if (fixed) {
				await t.forward("TransferChecked from a frozen account", TOKEN_2022, moving.slice(0, 4), checked(1, 6),
					custom(17, TOKEN_2022));
			}
		}
	});
}

await scenario("token-2022: associated account extensions the mint requires", TOKEN_2022, async (t) => {
	const cases = [
		{ mint: [1], length: 182, account: [7, 2] },
		{ mint: [9], length: 174, account: [7, 13] },
		{ mint: [14], length: 175, account: [7, 15] },
		{ mint: [26], length: 174, account: [7, 27] },
		{ mint: [3], length: 170, account: [7] },
		{ mint: [6], length: 170, account: [7], state: 2 },
		{ mint: [1, 9, 14, 26], length: 195, account: [7, 2, 13, 15, 27] },
	];
	for (const { mint: extensions, length, account, state = 1 } of cases) {
		const mint = await t.mint(6, 1_000_000, extensions);
		const [associated] = await getProgramDerivedAddress({
			programAddress: ASSOCIATED_TOKEN,
			seeds: [encoder.encode(t.owner.address), encoder.encode(TOKEN_2022), encoder.encode(mint)],
		});
		await t.send(`a mint with extensions ${extensions.join(",")}`, OP.createAssociatedRaw, [
			t.meta(t.payer.address, true, true),
			t.meta(associated, true),
			t.meta(t.owner.address, false),
			t.meta(mint, false),
			t.meta(SYSTEM, false),
			t.meta(TOKEN_2022, false),
			t.meta(ASSOCIATED_TOKEN, false),
		], new Uint8Array());
		const stored = t.svm.getAccount(associated);
		const kinds = stored.exists ? extensionKinds(stored.data) : [];
		t.check(`the associated account is ${length} bytes with extensions ${account.join(",")}`,
			stored.exists && stored.data.length === length && kinds.join(",") === account.join(",")
				&& stored.data[165] === 2 && tokenFields(stored).state === state
				&& stored.lamports === t.svm.minimumBalanceForRentExemption(BigInt(length)));
	}
});

if (failures > 0) {
	console.error(`${failures} check(s) failed`);
	process.exit(1);
}
console.log("token operations against the real token programs: every check passed");
