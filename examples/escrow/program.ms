import {
	Account,
	AssociatedToken,
	External,
	ExternalMutable,
	Mutable,
	Program,
	ProgramError,
	System,
	Writable,
	WritableSigner,
	accounts,
	args,
	associated,
	bump,
	close,
	createPda,
	externalMutable,
	failWith,
	hasOne,
	instruction,
	leBytes,
	seeds,
	signed,
} from "std/solana";
import {
	Mint,
	TokenAccount,
	closeTokenAccount,
	createAssociatedFor,
	expectAssociated,
	transferTokens,
} from "std/solana/token";
import { Escrow, EscrowError, EscrowOp, MakeArgs, escrowError } from "./layout";

export struct MakeAccounts {
	maker: WritableSigner;
	mintA: External<Mint>;
	mintB: External<Mint>;
	@associated(mintA, maker) makerAtaA: ExternalMutable<TokenAccount>;
	escrow: Writable;
	vault: Writable;
	associatedTokenProgram: Program<AssociatedToken>;
	tokenProgram: Account;
	systemProgram: Program<System>;
}

export struct TakeAccounts {
	taker: WritableSigner;
	maker: Writable;
	mintA: External<Mint>;
	mintB: External<Mint>;
	@associated(mintA, taker) takerAtaA: ExternalMutable<TokenAccount>;
	@associated(mintB, taker) takerAtaB: ExternalMutable<TokenAccount>;
	@associated(mintB, maker) makerAtaB: ExternalMutable<TokenAccount>;
	@seeds("escrow", maker, leBytes(escrow.seed)) @bump(escrow.bump)
	@hasOne(maker) @hasOne(mintA) @hasOne(mintB)
	escrow: Mutable<Escrow>;
	@associated(mintA, escrow) vault: ExternalMutable<TokenAccount>;
	tokenProgram: Account;
	systemProgram: Program<System>;
}

export struct RefundAccounts {
	maker: WritableSigner;
	mintA: External<Mint>;
	@associated(mintA, maker) makerAtaA: ExternalMutable<TokenAccount>;
	@seeds("escrow", maker, leBytes(escrow.seed)) @bump(escrow.bump) @hasOne(maker) @hasOne(mintA)
	escrow: Mutable<Escrow>;
	@associated(mintA, escrow) vault: ExternalMutable<TokenAccount>;
	tokenProgram: Account;
	systemProgram: Program<System>;
}

function make(): Result<uint64, ProgramError> {
	const a = try args<MakeArgs>();
	if (a.deposit == 0 || a.receive == 0) {
		return Result.err(escrowError(EscrowError.ZeroAmount));
	}
	const x = try accounts<MakeAccounts>();
	const made = try createPda<Escrow>(x.maker, x.escrow, ["escrow", x.maker, leBytes(a.seed)]);
	const escrow = made.account.data();
	escrow.seed = a.seed;
	escrow.maker = x.maker.key();
	escrow.mintA = x.mintA.key();
	escrow.mintB = x.mintB.key();
	escrow.receive = a.receive;
	escrow.bump = made.bump;
	const escrowAccount = made.account as Account;
	const _vaultMade = try createAssociatedFor(
		x.maker,
		x.vault,
		escrowAccount,
		x.mintA,
		x.systemProgram,
		x.tokenProgram,
	);
	const _vaultKey = try expectAssociated(
		(x.vault as Account).key(),
		escrowAccount.key(),
		x.mintA,
	);
	const vault = try externalMutable<TokenAccount>(5);
	const _deposited = try transferTokens(
		x.makerAtaA,
		vault,
		x.mintA,
		x.maker as Account,
		a.deposit,
	);
	return Result.ok(a.deposit);
}

function take(): Result<uint64, ProgramError> {
	const x = try accounts<TakeAccounts>();
	const escrow = x.escrow.data();
	const escrowAccount = x.escrow as Account;
	const receive = escrow.receive;
	const _paid = try transferTokens(
		x.takerAtaB,
		x.makerAtaB,
		x.mintB,
		x.taker as Account,
		receive,
	);
	const held = (try x.vault.read()).amount;
	const _released = try signed(
		transferTokens(x.vault, x.takerAtaA, x.mintA, escrowAccount, held),
		["escrow", escrow.maker, leBytes(escrow.seed), [escrow.bump]],
	);
	const _vaultClosed = try signed(
		closeTokenAccount(x.vault, x.maker, escrowAccount),
		["escrow", escrow.maker, leBytes(escrow.seed), [escrow.bump]],
	);
	const _escrowClosed = try close(x.escrow, x.maker);
	return Result.ok(held);
}

function refund(): Result<uint64, ProgramError> {
	const x = try accounts<RefundAccounts>();
	const escrow = x.escrow.data();
	const escrowAccount = x.escrow as Account;
	const held = (try x.vault.read()).amount;
	const _returned = try signed(
		transferTokens(x.vault, x.makerAtaA, x.mintA, escrowAccount, held),
		["escrow", escrow.maker, leBytes(escrow.seed), [escrow.bump]],
	);
	const _vaultClosed = try signed(
		closeTokenAccount(x.vault, x.maker.asWritable(), escrowAccount),
		["escrow", escrow.maker, leBytes(escrow.seed), [escrow.bump]],
	);
	const _escrowClosed = try close(x.escrow, x.maker.asWritable());
	return Result.ok(held);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<EscrowOp>()) {
		EscrowOp.Make => make(),
		EscrowOp.Take => take(),
		EscrowOp.Refund => refund(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) {
	entry();
}

when (testBuild) {
	import {
		ASSOCIATED_TOKEN_PROGRAM_ID,
		Discriminator,
		Pubkey,
		SYSTEM_PROGRAM_ID,
		TOKEN_PROGRAM_ID,
		findProgramAddressOf,
		instructionDiscriminator,
	} from "std/solana";
	import { HostAccount, invocations, run, signerIs, textBytes } from "std/solana/host";
	import { associatedTokenAddress } from "std/solana/token";

	function keyOf(seed: uint8): Pubkey {
		let key = Pubkey.zero();
		key.bytes[0] = seed;
		key.bytes[1] = 0x5a;
		return key;
	}

	function programKey(): Pubkey { return keyOf(200); }

	function pushU64(bytes: uint8[], value: uint64): void {
		for (let shift: uint64 = 0; shift < 64; shift += 8) {
			bytes.push(((value >> shift) & 255) as uint8);
		}
	}

	function pushKey(bytes: uint8[], key: Pubkey): void {
		for (let i = 0; i < 32; i++) { bytes.push(key.bytes[i]); }
	}

	function zeros(bytes: uint8[], count: int32): void {
		for (let i = 0; i < count; i++) { bytes.push(0); }
	}

	function account(key: Pubkey, owner: Pubkey, data: uint8[], lamports: uint64): HostAccount {
		return {
			key: key,
			owner: owner,
			lamports: lamports,
			data: data,
			signer: false,
			writable: true,
			executable: false,
		};
	}

	function mintAccount(key: Pubkey): HostAccount {
		const data: uint8[] = [];
		zeros(data, 36);
		pushU64(data, 1000000);
		data.push(6);
		data.push(1);
		zeros(data, 36);
		return account(key, TOKEN_PROGRAM_ID, data, 1461600);
	}

	function associatedKey(wallet: Pubkey, mint: Pubkey): Pubkey {
		const found = associatedTokenAddress(wallet, mint, TOKEN_PROGRAM_ID);
		return found.ok ? found.value.key : Pubkey.zero();
	}

	function tokenAccount(wallet: Pubkey, mint: Pubkey, amount: uint64): HostAccount {
		const data: uint8[] = [];
		pushKey(data, mint);
		pushKey(data, wallet);
		pushU64(data, amount);
		zeros(data, 36);
		data.push(1);
		zeros(data, 56);
		return account(associatedKey(wallet, mint), TOKEN_PROGRAM_ID, data, 2039280);
	}

	function wallet(key: Pubkey): HostAccount {
		return { ...account(key, SYSTEM_PROGRAM_ID, [], 10000000000), signer: true };
	}

	function executable(key: Pubkey): HostAccount {
		return { ...account(key, keyOf(0), [], 1), writable: false, executable: true };
	}

	function blank(key: Pubkey): HostAccount {
		return account(key, SYSTEM_PROGRAM_ID, [], 0);
	}

	function escrowKey(maker: Pubkey, seed: uint64): Pubkey {
		const found = findProgramAddressOf(programKey(), ["escrow", maker, leBytes(seed)]);
		return found.ok ? found.value.key : Pubkey.zero();
	}

	function instructionData(name: string): uint8[] {
		const discriminator = instructionDiscriminator(name);
		const bytes: uint8[] = [];
		for (let i = 0; i < 8; i++) { bytes.push(discriminator.bytes[i]); }
		return bytes;
	}

	function makeData(seed: uint64, deposit: uint64, receive: uint64): uint8[] {
		const bytes = instructionData("Make");
		pushU64(bytes, seed);
		pushU64(bytes, deposit);
		pushU64(bytes, receive);
		return bytes;
	}

	function amountOf(holder: HostAccount): uint64 {
		let value: uint64 = 0;
		for (let i = 71; i >= 64; i--) {
			const byte: uint64 = holder.data[i] as uint64;
			value = (value << 8) | byte;
		}
		return value;
	}

	const maker = keyOf(1);
	const taker = keyOf(2);
	const mintA = keyOf(3);
	const mintB = keyOf(4);

	function makeAccounts(seed: uint64): HostAccount[] {
		const escrow = escrowKey(maker, seed);
		return [
			wallet(maker),
			mintAccount(mintA),
			mintAccount(mintB),
			tokenAccount(maker, mintA, 1000),
			blank(escrow),
			blank(associatedKey(escrow, mintA)),
			executable(ASSOCIATED_TOKEN_PROGRAM_ID),
			executable(TOKEN_PROGRAM_ID),
			executable(SYSTEM_PROGRAM_ID),
		];
	}

	test "make moves the deposit into a vault the escrow PDA owns" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		assert amountOf(made[3]) == 400;
		assert made[5].owner == TOKEN_PROGRAM_ID && amountOf(made[5]) == 600;
		assert made[4].owner == programKey() && made[4].data.length == 8 + 120;
	}

	test "take pays the maker, hands the vault to the taker and closes both accounts" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		const taken: HostAccount[] = [
			wallet(taker),
			{ ...made[0], signer: false },
			made[1],
			made[2],
			tokenAccount(taker, mintA, 0),
			tokenAccount(taker, mintB, 500),
			tokenAccount(maker, mintB, 0),
			made[4],
			made[5],
			made[7],
			made[8],
		];
		const makerBefore = taken[1].lamports;
		assert run(programKey(), taken, instructionData("Take"), entry).result == 0;
		assert amountOf(taken[4]) == 600 && amountOf(taken[5]) == 200 && amountOf(taken[6]) == 300;
		assert taken[7].lamports == 0 && taken[7].data.length == 0;
		assert taken[7].owner == SYSTEM_PROGRAM_ID;
		assert taken[8].lamports == 0;
		assert taken[1].lamports > makerBefore;
	}

	function escrowSeeds(seed: uint64): uint8[][] {
		const found = findProgramAddressOf(programKey(), ["escrow", maker, leBytes(seed)]);
		const makerBytes: uint8[] = [];
		for (let i = 0; i < 32; i++) { makerBytes.push(maker.bytes[i]); }
		const seedBytes: uint8[] = [];
		pushU64(seedBytes, seed);
		return [textBytes("escrow"), makerBytes, seedBytes, [found.ok ? found.value.bump : 0]];
	}

	test "make, take and refund sign with the escrow's seeds and its bump" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		const created = invocations();
		assert created.length == 3 && created[0].signers == 1 && created[1].signers == 0;
		assert signerIs(created[0], 0, escrowSeeds(7));
		const taken: HostAccount[] = [
			wallet(taker),
			{ ...made[0], signer: false },
			made[1],
			made[2],
			tokenAccount(taker, mintA, 0),
			tokenAccount(taker, mintB, 500),
			tokenAccount(maker, mintB, 0),
			made[4],
			made[5],
			made[7],
			made[8],
		];
		assert run(programKey(), taken, instructionData("Take"), entry).result == 0;
		const calls = invocations();
		assert calls.length == 3 && calls[0].signers == 0;
		assert calls[1].signers == 1 && signerIs(calls[1], 0, escrowSeeds(7));
		assert calls[2].signers == 1 && signerIs(calls[2], 0, escrowSeeds(7));
		const again = makeAccounts(9);
		assert run(programKey(), again, makeData(9, 600, 300), entry).result == 0;
		const refunded = [again[0], again[1], again[3], again[4], again[5], again[7], again[8]];
		assert run(programKey(), refunded, instructionData("Refund"), entry).result == 0;
		const returned = invocations();
		assert returned.length == 2;
		assert signerIs(returned[0], 0, escrowSeeds(9)) && signerIs(returned[1], 0, escrowSeeds(9));
	}

	test "refund returns the deposit to the maker and closes both accounts" {
		const made = makeAccounts(9);
		assert run(programKey(), made, makeData(9, 600, 300), entry).result == 0;
		const refunded = [made[0], made[1], made[3], made[4], made[5], made[7], made[8]];
		assert run(programKey(), refunded, instructionData("Refund"), entry).result == 0;
		assert amountOf(refunded[2]) == 1000;
		assert refunded[3].lamports == 0 && refunded[4].lamports == 0;
	}

	test "make refuses a zero amount" {
		const zero = makeAccounts(7);
		assert run(programKey(), zero, makeData(7, 0, 300), entry).result ==
			ProgramError.userError(0).code;
	}

	function takeAccounts(made: HostAccount[]): HostAccount[] {
		return [
			wallet(taker),
			{ ...made[0], signer: false },
			made[1],
			made[2],
			tokenAccount(taker, mintA, 0),
			tokenAccount(taker, mintB, 500),
			tokenAccount(maker, mintB, 0),
			made[4],
			made[5],
			made[7],
			made[8],
		];
	}

	function refused(accounts: HostAccount[]): uint64 {
		return run(programKey(), accounts, instructionData("Take"), entry).result;
	}

	const ESCROW_MAKER = 8 + 8;
	const ESCROW_MINT_A = ESCROW_MAKER + 32;
	const ESCROW_MINT_B = ESCROW_MINT_A + 32;
	const ESCROW_BUMP = ESCROW_MINT_B + 32 + 8;

	test "take refuses an escrow that names another maker, mint A or mint B with ConstraintHasOne" {
		for (const at of [ESCROW_MAKER, ESCROW_MINT_A, ESCROW_MINT_B]) {
			const made = makeAccounts(7);
			assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
			const taken = takeAccounts(made);
			taken[7].data[at + 31] = taken[7].data[at + 31] ^ 1;
			assert refused(taken) == ProgramError.constraintHasOne().code;
		}
	}

	test "take refuses an escrow whose seed or bump does not give its address with ConstraintSeeds" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		const wrongBump = takeAccounts(made);
		wrongBump[7].data[ESCROW_BUMP] = wrongBump[7].data[ESCROW_BUMP] ^ 1;
		assert refused(wrongBump) == ProgramError.constraintSeeds().code;
		const wrongSeed = takeAccounts(made);
		wrongSeed[7].data[8] = wrongSeed[7].data[8] ^ 1;
		assert refused(wrongSeed) == ProgramError.constraintSeeds().code;
		const elsewhere = takeAccounts(made);
		elsewhere[7].key = keyOf(77);
		assert refused(elsewhere) == ProgramError.constraintSeeds().code;
	}

	test "take refuses a token account of another owner with ConstraintTokenOwner and one off the associated address with ConstraintAssociated" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		const stranger = keyOf(9);
		const strangersMaker = takeAccounts(made);
		strangersMaker[1] = { ...wallet(stranger), signer: false };
		assert refused(strangersMaker) == ProgramError.constraintTokenOwner().code;
		const strangersAta = takeAccounts(made);
		strangersAta[4] = tokenAccount(stranger, mintA, 0);
		assert refused(strangersAta) == ProgramError.constraintTokenOwner().code;
		const movedAta = takeAccounts(made);
		movedAta[5].key = keyOf(66);
		assert refused(movedAta) == ProgramError.constraintAssociated().code;
		const movedVault = takeAccounts(made);
		movedVault[8] = { ...made[5], key: keyOf(65) };
		assert refused(movedVault) == ProgramError.constraintAssociated().code;
	}

	test "take refuses someone else's escrow when only the maker account differs" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		const stranger = keyOf(9);
		const taken = takeAccounts(made);
		taken[1] = { ...wallet(stranger), signer: false };
		taken[6] = tokenAccount(stranger, mintB, 0);
		assert refused(taken) == ProgramError.constraintSeeds().code;
	}
}
