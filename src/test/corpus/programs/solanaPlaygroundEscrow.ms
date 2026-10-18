// @stdout: ✓ taker pays 300 B and takes the vault: ok
// @stdout: ✓ maker takes the offer back: ok
// @skip-raiser: std/solana has memory and kernel modules for C and JS only
// note: the geass playground's escrow program; the Solana program and its host simulator print the same lines on C and JS. Its enums drop `export`: a JS bundle exports no enum.

import {
	Account, AssociatedToken, Discriminator, External, ExternalMutable, Mutable, Program,
	ProgramError, Pubkey, System, Writable, WritablePda, WritableSigner, accountDiscriminator,
	accounts, args, asAccount, associated, bump, close, createPda, externalMutable, failWith,
	hasOne, instruction, leBytes, seeds, signed,
} from "std/solana";
import {
	Mint, TokenAccount, closeTokenAccount, createAssociatedFor, expectAssociated, transferTokens,
} from "std/solana/token";
import {
	ASSOCIATED_TOKEN_PROGRAM_ID, SYSTEM_PROGRAM_ID, TOKEN_PROGRAM_ID, findProgramAddressOf,
	instructionDiscriminator,
} from "std/solana";
import { HostAccount, run } from "std/solana/host";
import { associatedTokenAddress } from "std/solana/token";

enum EscrowOp {
	Make,
	Take,
	Refund,
}

export struct Escrow {
	seed: uint64;
	maker: Pubkey;
	mintA: Pubkey;
	mintB: Pubkey;
	receive: uint64;
	bump: uint8;
}

export function discriminator(this typeof Escrow): Discriminator {
	return @comptime { return accountDiscriminator("Escrow"); };
}

export struct MakeArgs {
	seed: uint64;
	deposit: uint64;
	receive: uint64;
}

enum EscrowError {
	ZeroAmount,
}

export converter escrowError(error: EscrowError): ProgramError {
	return ProgramError.userError(error as uint32);
}

export struct MakeAccounts {
	maker: WritableSigner;
	mintA: External<Mint>;
	mintB: External<Mint>;
	@associated(mintA, maker) makerAtaA: ExternalMutable<TokenAccount>;
	@seeds("escrow", maker, leBytes(a.seed)) @bump escrow: WritablePda;
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
		return Result.err(EscrowError.ZeroAmount);
	}
	const x = try accounts<MakeAccounts>();
	const made = try createPda<Escrow>(x.maker, x.escrow, ["escrow", x.maker, leBytes(a.seed)]);
	const escrow = made.asMutable().data();
	escrow.seed = a.seed;
	escrow.maker = x.maker.key();
	escrow.mintA = x.mintA.key();
	escrow.mintB = x.mintB.key();
	escrow.receive = a.receive;
	escrow.bump = made.foundBump();
	const escrowAccount = made.asMutable().asAccount();
	const _vaultMade = try createAssociatedFor(
		x.maker,
		x.vault,
		escrowAccount,
		x.mintA,
		x.systemProgram,
		x.tokenProgram,
	);
	const _vaultKey = try expectAssociated(
		x.vault.key(),
		escrowAccount.key(),
		x.mintA,
	);
	const vault = try externalMutable<TokenAccount>(5);
	const _deposited = try transferTokens(
		x.makerAtaA,
		vault,
		x.mintA,
		x.maker.asAccount(),
		a.deposit,
	);
	return Result.ok(a.deposit);
}

function take(): Result<uint64, ProgramError> {
	const x = try accounts<TakeAccounts>();
	const escrow = x.escrow.data();
	const escrowAccount = x.escrow.asAccount();
	const receive = escrow.receive;
	const _paid = try transferTokens(
		x.takerAtaB,
		x.makerAtaB,
		x.mintB,
		x.taker.asAccount(),
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
	const escrowAccount = x.escrow.asAccount();
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

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	key.bytes[1] = 0x5a;
	return key;
}

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
		key: key, owner: owner, lamports: lamports, data: data,
		signer: false, writable: true, executable: false,
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
	return { ...account(key, Pubkey.zero(), [], 1), writable: false, executable: true };
}

function blank(key: Pubkey): HostAccount {
	return account(key, SYSTEM_PROGRAM_ID, [], 0);
}

function call(name: string): uint8[] {
	const tag = instructionDiscriminator(name);
	const bytes: uint8[] = [];
	for (let i = 0; i < 8; i++) { bytes.push(tag.bytes[i]); }
	return bytes;
}

function makeCall(seed: uint64, deposit: uint64, receive: uint64): uint8[] {
	const bytes = call("Make");
	pushU64(bytes, seed);
	pushU64(bytes, deposit);
	pushU64(bytes, receive);
	return bytes;
}

function amountOf(holder: HostAccount): uint64 {
	if (holder.data.length < 72) { return 0; }
	let value: uint64 = 0;
	for (let i = 71; i >= 64; i--) { value = (value << 8) | (holder.data[i] as uint64); }
	return value;
}

function nameOf(code: uint64): string {
	if (code == 6000) { return "EscrowError.ZeroAmount (6000)"; }
	if (code == 2001) { return "ConstraintHasOne (2001)"; }
	if (code == 2006) { return "ConstraintSeeds (2006)"; }
	if (code == 3010) { return "AccountNotSigner (3010)"; }
	return `error ${code}`;
}

function report(label: string, result: uint64): void {
	const mark = result == 0 ? "✓" : "✗";
	const outcome = result == 0 ? "ok" : `refused by the program, ${nameOf(result)}`;
	console.log(`${mark} ${label}: ${outcome}`);
}

const program = keyOf(9);
const maker = keyOf(1);
const taker = keyOf(2);
const mintA = keyOf(3);
const mintB = keyOf(4);

function makeAccounts(seed: uint64): HostAccount[] {
	const found = findProgramAddressOf(program, ["escrow", maker, leBytes(seed)]);
	const escrow = found.ok ? found.value.key : Pubkey.zero();
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

const zero = makeAccounts(7);
report("maker offers 0 of token A", run(program, zero, makeCall(7, 0, 300), entry).result);

const made = makeAccounts(7);
report("maker offers 600 A for 300 B", run(program, made, makeCall(7, 600, 300), entry).result);
console.log(`    maker holds ${amountOf(made[3])} A · vault holds ${amountOf(made[5])} A`);

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
report("taker pays 300 B and takes the vault", run(program, taken, call("Take"), entry).result);
console.log(`    taker holds ${amountOf(taken[4])} A, ${amountOf(taken[5])} B`);
console.log(`    maker holds ${amountOf(taken[6])} B`);
console.log(`    escrow holds ${taken[7].data.length} bytes, ${taken[7].lamports} lamports`);

const again = makeAccounts(9);
report("maker offers 600 A again", run(program, again, makeCall(9, 600, 300), entry).result);

const stolen = [
	wallet(taker), again[1], tokenAccount(taker, mintA, 0), again[4], again[5], again[7], again[8],
];
report("taker refunds the maker's escrow", run(program, stolen, call("Refund"), entry).result);

const refunded = [again[0], again[1], again[3], again[4], again[5], again[7], again[8]];
report("maker takes the offer back", run(program, refunded, call("Refund"), entry).result);
console.log(`    maker holds ${amountOf(refunded[2])} A`);
