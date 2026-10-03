import {
	Account,
	Delegated,
	Discriminator,
	Mutable,
	Owned,
	Program,
	ProgramError,
	Pubkey,
	System,
	Writable,
	WritableSigner,
	account,
	accountDiscriminator,
	accounts,
	address,
	args,
	argU8,
	bump,
	constraint,
	close,
	create,
	createPda,
	delegated,
	external,
	externalMutable,
	failWith,
	hasOne,
	instruction,
	mutable,
	owned,
	pda,
	pdaWithBump,
	realloc,
	seeds,
	writable,
	writableSigner,
} from "std/solana";
import { Mint, TokenAccount } from "std/solana/token";

export struct Pet {
	owner: Pubkey;
	points: uint64;
	bump: uint8;
}

export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}

export struct Everything {
	payer: WritableSigner;
	target: Writable;
	pet: Mutable<Pet>;
	peek: Owned<Pet>;
	rolled: Delegated<Pet>;
	fresh: Writable;
	systemProgram: Program<System>;
}

export struct Plain {
	owner: WritableSigner;
	target: Writable;
	pet: Mutable<Pet>;
}

export struct Pinned {
	owner: WritableSigner;
	target: Writable;
	@seeds("pet", owner) @bump(pet.bump) pet: Mutable<Pet>;
}

export struct Canonical {
	owner: WritableSigner;
	target: Writable;
	@seeds("pet", owner) @bump pet: Mutable<Pet>;
}

export struct Related {
	owner: WritableSigner;
	target: Writable;
	@hasOne(owner) pet: Mutable<Pet>;
}

export struct Conditioned {
	owner: WritableSigner;
	target: Writable;
	@constraint(pet.points == 0) pet: Mutable<Pet>;
}

export struct Addressed {
	payer: WritableSigner;
	target: Writable;
	pet: Mutable<Pet>;
	peek: Owned<Pet>;
	rolled: Delegated<Pet>;
	fresh: Writable;
	@address(Pubkey.systemProgram()) systemProgram: Account;
}

export struct Unaddressed {
	payer: WritableSigner;
	target: Writable;
	pet: Mutable<Pet>;
	peek: Owned<Pet>;
	rolled: Delegated<Pet>;
	fresh: Writable;
	systemProgram: Account;
}

export struct Parameters {
	op: uint8;
	amount: uint64;
	flag: boolean;
	owner: Pubkey;
	bump: uint8;
}

export enum Dispatch {
	First,
	Second,
	Third,
	Fourth,
	Fifth,
	Sixth,
	Seventh,
	Last,
}

function idle(): Result<uint64, ProgramError> {
	const _first = try account(0);
	return Result.ok(0);
}

function ownedOne(): Result<uint64, ProgramError> {
	const seen = try owned<Pet>(3);
	return Result.ok(seen.data().points);
}

function mutableOne(): Result<uint64, ProgramError> {
	const held = try mutable<Pet>(2);
	return Result.ok(held.data().points);
}

function delegatedOne(): Result<uint64, ProgramError> {
	const rolled = try delegated<Pet>(4);
	return Result.ok(rolled.data().points);
}

function everything(): Result<uint64, ProgramError> {
	const x = try accounts<Everything>();
	return Result.ok(x.pet.data().points);
}

function plain(): Result<uint64, ProgramError> {
	const x = try accounts<Plain>();
	return Result.ok(x.pet.data().points);
}

function pinned(): Result<uint64, ProgramError> {
	const x = try accounts<Pinned>();
	return Result.ok(x.pet.data().points);
}

function canonical(): Result<uint64, ProgramError> {
	const x = try accounts<Canonical>();
	return Result.ok(x.pet.data().points);
}

function related(): Result<uint64, ProgramError> {
	const x = try accounts<Related>();
	return Result.ok(x.pet.data().points);
}

function conditioned(): Result<uint64, ProgramError> {
	const x = try accounts<Conditioned>();
	return Result.ok(x.pet.data().points);
}

function unaddressed(): Result<uint64, ProgramError> {
	const x = try accounts<Unaddressed>();
	return Result.ok(x.pet.data().points);
}

function addressed(): Result<uint64, ProgramError> {
	const x = try accounts<Addressed>();
	return Result.ok(x.pet.data().points);
}

function parameters(): Result<uint64, ProgramError> {
	const given = try args<Parameters>();
	return Result.ok(given.amount);
}

function createPdaOne(): Result<uint64, ProgramError> {
	const payer = try writableSigner(0);
	const target = try writable(1);
	const made = try createPda<Pet>(payer, target, ["new", payer]);
	return Result.ok(made.bump as uint64);
}

function createOne(): Result<uint64, ProgramError> {
	const payer = try writableSigner(0);
	const fresh = try writable(5);
	const made = try create<Pet>(payer, fresh);
	return Result.ok(made.data().points);
}

function petPda(): Result<uint64, ProgramError> {
	const pet = try mutable<Pet>(2);
	const payer = try writableSigner(0);
	const found = try pda(pet, ["pet", payer]);
	return Result.ok(found.bump as uint64);
}

function petPdaWithBump(): Result<uint64, ProgramError> {
	const pet = try mutable<Pet>(2);
	const payer = try writableSigner(0);
	const found = try pdaWithBump(pet, ["pet", payer], argU8(1));
	return Result.ok(found.bump as uint64);
}

function rolledPda(): Result<uint64, ProgramError> {
	const rolled = try delegated<Pet>(4);
	const payer = try writableSigner(0);
	const bump = try pda(rolled, ["rolled", payer]);
	return Result.ok(bump as uint64);
}

function rolledPdaWithBump(): Result<uint64, ProgramError> {
	const rolled = try delegated<Pet>(4);
	const payer = try writableSigner(0);
	const bump = try pdaWithBump(rolled, ["rolled", payer], argU8(1));
	return Result.ok(bump as uint64);
}

function resized(): Result<uint64, ProgramError> {
	const pet = try mutable<Pet>(2);
	const payer = try writableSigner(0);
	return realloc<Pet>(pet, 200, payer);
}

function closed(): Result<uint64, ProgramError> {
	const pet = try mutable<Pet>(2);
	const payer = try writableSigner(0);
	return close(pet, payer.asWritable());
}

function selected(): Result<uint64, ProgramError> {
	const picked = try instruction<Dispatch>();
	return Result.ok((picked as int32) as uint64);
}

function externalMint(): Result<uint64, ProgramError> {
	const mint = try external<Mint>(7);
	return Result.ok(mint.lamports());
}

function externalToken(): Result<uint64, ProgramError> {
	const token = try externalMutable<TokenAccount>(8);
	return Result.ok(token.lamports());
}

function entry(): void {
	const op = argU8(0);
	let result = idle();
	if (op == 1) { result = ownedOne(); }
	if (op == 2) { result = mutableOne(); }
	if (op == 3) { result = delegatedOne(); }
	if (op == 4) { result = everything(); }
	if (op == 5) { result = parameters(); }
	if (op == 6) { result = createPdaOne(); }
	if (op == 7) { result = createOne(); }
	if (op == 8) { result = petPda(); }
	if (op == 9) { result = petPdaWithBump(); }
	if (op == 10) { result = rolledPda(); }
	if (op == 11) { result = rolledPdaWithBump(); }
	if (op == 12) { result = resized(); }
	if (op == 13) { result = closed(); }
	if (op == 14) { result = selected(); }
	if (op == 15) { result = externalMint(); }
	if (op == 16) { result = externalToken(); }
	if (op == 17) { result = plain(); }
	if (op == 18) { result = pinned(); }
	if (op == 19) { result = canonical(); }
	if (op == 20) { result = related(); }
	if (op == 21) { result = conditioned(); }
	if (op == 22) { result = addressed(); }
	if (op == 23) { result = unaddressed(); }
	if (!result.ok) { failWith(result.error); }
}
entry();
