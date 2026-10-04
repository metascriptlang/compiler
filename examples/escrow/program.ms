import {
	Account,
	AssociatedToken,
	External,
	ExternalMutable,
	Mutable,
	Program,
	ProgramError,
	Pubkey,
	Seeds,
	System,
	Writable,
	WritableSigner,
	accounts,
	args,
	close,
	createPda,
	expectAddress,
	expectHasOne,
	externalMutable,
	failWith,
	instruction,
	pdaWithBump,
	readArgs,
	selectInstruction,
} from "std/solana";
import {
	Mint,
	TokenAccount,
	closeTokenAccount,
	createAssociatedFor,
	expectAssociated,
	transferTokens,
	transferTokensSigned,
} from "std/solana/token";
import { Escrow, EscrowError, EscrowOp, MakeArgs, escrowError } from "./layout";

export struct MakeAccounts {
	maker: WritableSigner;
	mintA: External<Mint>;
	mintB: External<Mint>;
	makerAtaA: ExternalMutable<TokenAccount>;
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
	takerAtaA: ExternalMutable<TokenAccount>;
	takerAtaB: ExternalMutable<TokenAccount>;
	makerAtaB: ExternalMutable<TokenAccount>;
	escrow: Mutable<Escrow>;
	vault: ExternalMutable<TokenAccount>;
	tokenProgram: Account;
	systemProgram: Program<System>;
}

export struct RefundAccounts {
	maker: WritableSigner;
	mintA: External<Mint>;
	makerAtaA: ExternalMutable<TokenAccount>;
	escrow: Mutable<Escrow>;
	vault: ExternalMutable<TokenAccount>;
	tokenProgram: Account;
	systemProgram: Program<System>;
}

export function escrowSeeds(maker: Pubkey, seed: uint64): Seeds {
	return Seeds.empty(4).addText("escrow").addPubkey(maker).addU64(seed);
}

function make(): Result<uint64, ProgramError> {
	const a = try args<MakeArgs>();
	if (a.deposit == 0 || a.receive == 0) {
		return Result.err(escrowError(EscrowError.ZeroAmount));
	}
	const x = try accounts<MakeAccounts>();
	const _ownAta = try expectAssociated(x.makerAtaA.key(), x.maker.key(), x.mintA);
	const made = try createPda<Escrow>(x.maker, x.escrow, escrowSeeds(x.maker.key(), a.seed));
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
		x.maker.asSigner(),
		a.deposit,
	);
	return Result.ok(a.deposit);
}

function take(): Result<uint64, ProgramError> {
	const x = try accounts<TakeAccounts>();
	const escrow = x.escrow.data();
	const seeds = escrowSeeds(escrow.maker, escrow.seed);
	const verified = try pdaWithBump(x.escrow, seeds, escrow.bump);
	const _maker = try expectHasOne(escrow.maker, x.maker.key());
	const _mintA = try expectAddress(x.mintA.key(), escrow.mintA);
	const _mintB = try expectAddress(x.mintB.key(), escrow.mintB);
	const escrowAccount = x.escrow as Account;
	const _vault = try expectAssociated(x.vault.key(), escrowAccount.key(), x.mintA);
	const _takerA = try expectAssociated(x.takerAtaA.key(), x.taker.key(), x.mintA);
	const _takerB = try expectAssociated(x.takerAtaB.key(), x.taker.key(), x.mintB);
	const _makerB = try expectAssociated(x.makerAtaB.key(), escrow.maker, x.mintB);
	const receive = escrow.receive;
	const _paid = try transferTokens(
		x.takerAtaB,
		x.makerAtaB,
		x.mintB,
		x.taker.asSigner(),
		receive,
	);
	const held = (try x.vault.read()).amount;
	const signer = seeds.withBump(verified.bump);
	const _released = try transferTokensSigned(
		x.vault,
		x.takerAtaA,
		x.mintA,
		escrowAccount,
		held,
		signer,
	);
	const _vaultClosed = try closeTokenAccount(x.vault, x.maker, escrowAccount, signer);
	const _escrowClosed = try close(x.escrow, x.maker);
	return Result.ok(held);
}

function refund(): Result<uint64, ProgramError> {
	const x = try accounts<RefundAccounts>();
	const escrow = x.escrow.data();
	const seeds = escrowSeeds(escrow.maker, escrow.seed);
	const verified = try pdaWithBump(x.escrow, seeds, escrow.bump);
	const _maker = try expectHasOne(escrow.maker, x.maker.key());
	const _mintA = try expectAddress(x.mintA.key(), escrow.mintA);
	const escrowAccount = x.escrow as Account;
	const _vault = try expectAssociated(x.vault.key(), escrowAccount.key(), x.mintA);
	const _ownAta = try expectAssociated(x.makerAtaA.key(), x.maker.key(), x.mintA);
	const held = (try x.vault.read()).amount;
	const signer = seeds.withBump(verified.bump);
	const _returned = try transferTokensSigned(
		x.vault,
		x.makerAtaA,
		x.mintA,
		escrowAccount,
		held,
		signer,
	);
	const _vaultClosed = try closeTokenAccount(
		x.vault,
		x.maker.asWritable(),
		escrowAccount,
		signer,
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
	import { Discriminator, instructionDiscriminator } from "std/solana";
	import { HostAccount, run } from "std/solana/host";
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
		return account(key, Pubkey.tokenProgram(), data, 1461600);
	}

	function associated(wallet: Pubkey, mint: Pubkey): Pubkey {
		const found = associatedTokenAddress(wallet, mint, Pubkey.tokenProgram());
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
		return account(associated(wallet, mint), Pubkey.tokenProgram(), data, 2039280);
	}

	function wallet(key: Pubkey): HostAccount {
		return { ...account(key, Pubkey.systemProgram(), [], 10000000000), signer: true };
	}

	function executable(key: Pubkey): HostAccount {
		return { ...account(key, keyOf(0), [], 1), writable: false, executable: true };
	}

	function blank(key: Pubkey): HostAccount {
		return account(key, Pubkey.systemProgram(), [], 0);
	}

	function escrowKey(maker: Pubkey, seed: uint64): Pubkey {
		const found = escrowSeeds(maker, seed).findProgramAddress(programKey());
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
			blank(associated(escrow, mintA)),
			executable(Pubkey.associatedTokenProgram()),
			executable(Pubkey.tokenProgram()),
			executable(Pubkey.systemProgram()),
		];
	}

	test "make moves the deposit into a vault the escrow PDA owns" {
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		assert amountOf(made[3]) == 400;
		assert made[5].owner == Pubkey.tokenProgram() && amountOf(made[5]) == 600;
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
		assert taken[7].owner == Pubkey.systemProgram();
		assert taken[8].lamports == 0;
		assert taken[1].lamports > makerBefore;
	}

	test "refund returns the deposit to the maker and closes both accounts" {
		const made = makeAccounts(9);
		assert run(programKey(), made, makeData(9, 600, 300), entry).result == 0;
		const refunded = [made[0], made[1], made[3], made[4], made[5], made[7], made[8]];
		assert run(programKey(), refunded, instructionData("Refund"), entry).result == 0;
		assert amountOf(refunded[2]) == 1000;
		assert refunded[3].lamports == 0 && refunded[4].lamports == 0;
	}

	test "make refuses a zero amount and take refuses someone else's escrow" {
		const zero = makeAccounts(7);
		assert run(programKey(), zero, makeData(7, 0, 300), entry).result ==
			ProgramError.userError(0).code;
		const made = makeAccounts(7);
		assert run(programKey(), made, makeData(7, 600, 300), entry).result == 0;
		const stranger = keyOf(9);
		const taken: HostAccount[] = [
			wallet(taker),
			{ ...wallet(stranger), signer: false },
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
		assert run(programKey(), taken, instructionData("Take"), entry).result ==
			ProgramError.constraintHasOne().code;
	}
}
