# std/solana — design

The on-chain toolkit for MetaScript programs on Solana. Written as the API should read; where the compiler cannot express it yet, the toolkit takes a measured workaround and §14 lists each one with its compiler card, so the debt is paid in one place.

Goals, in priority order:

1. **Safety first.** An account reaches game logic only through a verifier, and the type says what was verified. A wrong account, a missing signer or a bad error code is a compile error where the language can express it, and a typed runtime error otherwise.
2. **Account data reads and writes like ordinary data, and says when it is not.** A field read is a field read. A write goes to the account, and the type at the call site (`Ptr<T>`) makes that visible.
3. **General, incremental.** Any MetaScript developer can write a program with it. Only what a real program needs is built, in the order a real program needs it.
4. **Host and chain tests from day one.** The same program binary runs under a host simulator, in LiteSVM and on devnet.

The surface is MetaScript; what reaches the chain is Anchor's. Account and instruction discriminators, the zero-copy account layout, instruction encoding, error codes and the IDL follow Anchor byte for byte, so an Anchor client, explorer or indexer reads a MetaScript program without knowing it was not written in Rust. The account checks follow Anchor's and Pinocchio's: money is at stake, and an invented check is an unaudited one.

## 1. A program

```ms
import { opcode, args, signer, mutable, clock, exit, ProgramError } from "std/solana";
import { Pet, FeedArgs } from "../rules/layout";

enum PetOp {
	Feed,
	Attack,
}

function feed(): Result<uint64, ProgramError> {
	const owner = try signer(0);
	const petAccount = try mutable<Pet>(1, owner);
	const portions = try args<FeedArgs>();
	const pet = petAccount.data();
	pet[].onFightDay(clock().epoch);
	pet[].eat(portions.count);
	return Result.ok(pet.hearts as uint64);
}

function dispatch(): Result<uint64, ProgramError> {
	return match (try opcode<PetOp>()) {
		PetOp.Feed => feed(),
		PetOp.Attack => attack(),
	};
}

function main(): void { exit(dispatch()); }
main();
```

Every instruction handler is an ordinary function returning `Result<uint64, ProgramError>`. `exit` writes the return code; `main` has no other job. The `rules/` modules that mutate a `Pet` do it through `this ref pet: Pet`, and the same modules compile to the JS client and the native simulator unchanged.

## 2. Values

| Type | Kind | Meaning |
|---|---|---|
| `Pubkey` | value struct, 32 bytes | compared with `==`, printed with `logPubkey`; `Pubkey.of("DELeG…")` decodes base58 at compile time, so a program id is written as the string everyone else uses and costs nothing at run time |
| `Account` | value struct, one word | a pointer into the input buffer, as Pinocchio's `AccountInfo`: `key()`, `owner()`, `lamports()`, `dataLength()`, `isSigner()`, `isWritable()`, `bytes()`. Nothing is copied out of the buffer |
| `Bytes` | value struct | address + length; bounds-checked `readU8…readPubkey`, `writeU8…`, `range`, `copyFrom`, `fillWith` |
| `Seeds` | value struct, stack | up to 16 `{ address, length }` slots: `Seeds.of("pet").key(mint).u8(bump)`; `findProgramAddress`, `createProgramAddress`. Lives in the caller's frame, as Pinocchio's `Seed` arrays do; nothing on the heap |
| `Instruction` | builder, heap | CPI: `Instruction.forProgram(id).writableSigner(a).readonly(b).append(argsStruct).invokeSigned(seeds)` |
| `Clock` | value struct | `clock()`, a syscall; no sysvar account in the list |
| `ProgramError` | value struct, `uint64` code | the ABI error, §5 |

All of them are plain structs with extension functions. `Instruction` bump-allocates in the Solana heap region, which is the whole heap discipline of a program: allocation is fine, freeing does not exist. Everything else is a value in a stack frame, and a sBPF frame is 4 KB: a value copy of a plain-data struct over 1 KB under `--os=solana` is a compile-time diagnostic, so the `Box<Account<…>>` workaround Anchor programs reach for never becomes necessary.

## 3. Proofs

A verifier is the only way to get a proof type, and a function that needs the property takes the proof type.

```ms
type Signer = distinct Account;
type Writable = distinct Account;                // any writable account, e.g. a wallet receiving rent
type Program<P> = distinct Account;              // key == P.programId()
type Owned<T> = distinct Account;                // owner == programId(), head matches T (§4); data is read-only
type Mutable<T> = distinct Owned<T>;             // and isWritable(); data is writable
type External<T> = distinct Account;             // owner == T.ownerProgram(), T.isInitialized(data); another program's account, read-only
type ExternalMutable<T> = distinct External<T>;  // and isWritable()
struct Pda<T> { account: Mutable<T>; bump: uint8; }   // a struct, because a proof is one word and the bump must travel with it
```

```ms
export function signer(index: int32): Result<Signer, ProgramError>;
export function writable(index: int32): Result<Writable, ProgramError>;
export function program<P>(index: int32): Result<Program<P>, ProgramError>;
export function owned<T>(index: int32): Result<Owned<T>, ProgramError>;
export function mutable<T>(index: int32): Result<Mutable<T>, ProgramError>;
export function mutable<T>(index: int32, owner: Signer): Result<Mutable<T>, ProgramError>;   // also T.ownerOf(data) == owner.key()
export function pda<T>(index: int32, seeds: Seeds): Result<Pda<T>, ProgramError>;            // also the address is the PDA of seeds
export function external<T>(index: int32): Result<External<T>, ProgramError>;
export function externalMutable<T>(index: int32): Result<ExternalMutable<T>, ProgramError>;
export function sysvar(index: int32, expected: Pubkey): Result<Account, ProgramError>;
```

`External<T>` is Anchor's `Account<'info, TokenAccount>`: the layout comes from the program that owns it (`std/solana/token` declares `Mint` and `TokenAccount`, with `ownerProgram()` and `isInitialized()`), there is no head, and the program never writes it directly, only through that program's CPI.

- Every proof borrows the `Account` surface (`@borrow`), so `owner.key()` reads as it should. A proof never converts back to `Account` implicitly; `as Account` is explicit and rare (building a CPI account list).
- Converting *into* a proof type (`account as Signer`) outside `std/solana` is a checker error. Without that rule a proof is a convention, as it is in Nim; with it, a proof is a proof.
- `Owned<T>.data()` is `Readonly<Ptr<T>>`: a field write or a `this ref` call through it is a compile error, so writing to an account the transaction did not mark writable fails at build time rather than when the runtime rejects the transaction. `Mutable<T>.data()` is `Ptr<T>`.
- **No two `Mutable` proofs for one account.** The runtime marks a duplicated account in the input buffer; `mutable<T>` refuses an index whose account already produced a `Mutable`, with `ProgramError.accountBorrowFailed()`. Two `Ptr<T>` into one buffer is how an attacker fights their own pet; Pinocchio catches it with the borrow flags in the account header, Anchor only when the program writes a `constraint`. Here it is the verifier's job.

### Accounts as a struct

Positional verifiers are the primitive; a handler that takes more than two accounts declares them:

```ms
struct MakeAccounts {
	maker: Signer;
	mintA: External<Mint>;
	@ata(mintA, maker) makerAtaA: ExternalMutable<TokenAccount>;
	@init(maker) @pda("escrow", maker, args.seed) escrow: Pda<Escrow>;
	@initAta(maker, mintA, escrow) vault: ExternalMutable<TokenAccount>;
	systemProgram: Program<System>;
	tokenProgram: Program<Token>;
}

function make(): Result<uint64, ProgramError> {
	const a = try args<MakeArgs>();
	const x = try accounts<MakeAccounts>(a);
	const escrow = x.escrow.account.data();
	…
}
```

`accounts<T>(args)` is a macro: it reads the struct declaration at compile time and expands to one verifier call per field, with the constraints a field decorator names. No reflection at run time, no table in the binary: the expansion is what a careful programmer would have written by hand, and it is exhaustive by construction. The same declaration gives the client its account order and the writable/signer flags (§11), which is the part of Anchor's IDL that a program cannot do without.

| Decorator | Verifies | Anchor |
|---|---|---|
| `@pda(seed…)` | the key is the PDA of the seeds; the field is `Pda<T>` and carries the bump | `seeds = […], bump` and `ctx.bumps` |
| `@ownedBy(field)` | `T.ownerOf(data) == field.key()` | `has_one = field` |
| `@keyIs(expr)` | the key equals an expression over already-verified fields (`escrow.mintA`) | `constraint = … @ Error` |
| `@distinct(field)` | the key differs from another field's | `constraint = a.key() != b.key()` |
| `@ata(mint, authority)` | the key is the associated token account | `associated_token::mint`, `::authority` |
| `@init(payer)` | the account is uninitialized; the macro emits `create<T>` with the head, paid by `payer` | `init, payer = …, space = …` |
| `@initAta(payer, mint, authority)` | as `@init`, through the Associated Token program | `init, associated_token::…` |

Decorator arguments name sibling fields and the instruction arguments (`args.seed`), so the macro orders the verifier calls by dependency, not by declaration: `@keyIs(escrow.mintA)` on `mintA` runs after `escrow`. The index of each account in the transaction is still its declaration order, which is what the client emits. A cycle is a compile error.

## 4. Account data

An account type is a fixed-size value struct declared once, in a module shared by the program and the client. Its bytes are Anchor's zero-copy account: an 8-byte discriminator, then the struct in its C layout, which is Anchor's `#[account(zero_copy)]` `repr(C)` layout.

```ms
export struct Pet {
	owner: Pubkey;
	hearts: uint8;
	…
}
export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}
export function ownerOf(this typeof Pet, pet: Pet): Pubkey { return pet.owner; }
```

- The discriminator is `sha256("account:" + name)[0..8]`, Anchor's, computed by the compiler: `accountDiscriminator` is a `@comptime` function over a pure MetaScript SHA-256, so the program carries eight bytes, not a hash.
- `Mutable<T>.data(): Ptr<T>` is the account data after the discriminator. `pet.hearts` reads it, `pet.hearts = 3` writes it, in place. `pet[]` is the pointee: `pet[].onFightDay(epoch)` calls a `this ref` method on the account, `pet[].stats()` a value method, `const snapshot = pet[]` copies. Nothing else on a `Ptr<T>` is implicit. This is Anchor's zero-copy overlay and Pinocchio's, with the type system in place of `bytemuck`.
- `owned<T>` checks, in order, as Anchor's `AccountLoader` does: the owner is this program (`AccountOwnedByWrongProgram`, 3007); the data holds at least the discriminator (`AccountDiscriminatorNotFound`, 3001); the discriminator is `T`'s (`AccountDiscriminatorMismatch`, 3002); the data holds `8 + sizeof T` bytes (`AccountDidNotDeserialize`, 3003).
- A closed account is assigned to the System program with zero data, as Anchor closes it, so the owner check refuses it before the discriminator is read; an uninitialized one fails the discriminator check.
- `create<T>` follows Anchor's `init`: a target with no lamports is created through the System program's `create_account`; a prefunded one is topped up to rent exemption, then allocated and assigned. The discriminator is written last. `close` moves the lamports, assigns to the System program and resizes to zero.
- `T` must be plain data: sized integers, `boolean`, enums stored as `uint8`, `BitSet`, `Pubkey`, nested plain structs, fixed arrays `U[N]`. `Pubkey` is 32 bytes with alignment 1, as Pinocchio's `[u8; 32]`, so it never adds padding.
- The wire layout is the C layout of the struct. The client reads accounts through the IDL's layout (§11), generated from the same declaration.

## 5. Errors

`ProgramError` is the ABI: a `uint64` where Solana's builtin errors are `n << 32` and a custom error is its low 32 bits. Its named constructors cover the builtin set (`ProgramError.missingRequiredSignature()`, …) and Anchor's framework codes (`ProgramError.constraintSeeds()` is 2006, `ProgramError.accountNotSigner()` 3010, …), with Anchor's numbers, so a client that decodes Anchor errors decodes these.

Domain code keeps `enum` errors, as `docs/CODE-STYLE.md` §2 asks. The boundary is a `converter`, and the code is Anchor's: 6000 plus the member's ordinal.

```ms
enum StakeError {
	Shielded,
	EmptyHarvest,
}
export converter stakeError(error: StakeError): ProgramError {
	return ProgramError.userError(error as uint32);
}

function attack(): Result<uint64, ProgramError> {
	const stake = try stakeFor(harvest, burrow, shielded);   // Result<uint64, StakeError>: converted
	…
}
```

`try` converts through the converter in scope and refuses a mismatch with no converter (measured, §12).

## 6. Instruction data

Anchor's encoding: 8 bytes of discriminator, `sha256("global:" + name)[0..8]` with the instruction's snake_case name, then the arguments in Borsh. Arguments are fixed-size plain data, where Borsh is the fields in declaration order, little-endian, with no padding.

```ms
export enum PetOp {
	Feed,
	Attack,
}
export struct FeedArgs { count: uint16; }

const op = try instruction<PetOp>();     // the member whose discriminator matches; `feed`, `attack`
const portions = try args<FeedArgs>();   // the bytes after the discriminator, field by field
```

`instruction<Op>()` is a macro: it reads the enum's members at compile time and compares the first eight bytes against each member's discriminator. Short data is `InstructionMissing` (100), no match `InstructionFallbackNotFound` (101), as Anchor's dispatcher. `args<T>()` reads `T`'s fields at their Borsh offsets; short data is `InstructionDidNotDeserialize` (102).

## 7. PDAs and CPI

- `Seeds.of("pet").key(mint)`: at most 16 seeds of at most 32 bytes, checked when built. `findProgramAddress(program)` returns `{ key, bump }`; `.bump(b)` appends the bump for signing.
- `Instruction.forProgram(id)` then `.writableSigner(a)`, `.writable(a)`, `.readonlySigner(a)`, `.readonly(a)`, then `.append<T>(value)` for a plain struct, `.appendBytes`, `.appendU8…`, then `.invoke()` or `.invokeSigned(seeds)`. Capacity errors surface at `invoke`, as `ProgramError.invalidArgument()`.
- System program helpers: `createAccount`, `allocate`, `assign`, `transfer`, `minimumBalance`.
- `std/solana/token`: the `Mint` and `TokenAccount` layouts (SPL Token and Token-2022, the TLV extensions read as `Bytes`), `transferChecked`, `closeAccount`, `mintTo`, the associated-token address and its `create`. Every helper takes proofs (`from: ExternalMutable<TokenAccount>`, `authority: Signer` or a PDA's `Seeds`), so an account list that is wrong for the token program fails at the call.

## 8. MagicBlock and VRF

`std/solana/magicblock`: `delegate(accounts, seeds, bump, config)`, `commit`, `commitAndUndelegate`, `undelegate` (the callback), `isUndelegateCallback`, `scheduleTask`. `std/solana/vrf`: `requestRandomness`, `verifyVrfCallback`. Both are instruction layouts copied from the MagicBlock SDK; program ids and queues are constants in the module, never prose. Their account structs take proofs (`payer: Signer`, `delegated: Writable`), so a wrong account list fails at the call, not inside the CPI.

## 9. Logging and limits

`log(text)` for literals, `logU64(a, b, c, d, e)` for numbers, `logPubkey`, `logComputeUnits`, `remainingComputeUnits`. String building, `String(uint64)` and `process.exit()` are compile errors under `--os=solana`, not runtime aborts.

## 10. Testing

Three lanes, one binary:

1. **Host simulator** (`std/solana/host`, native). Builds the entrypoint input buffer the way the runtime parses it (`msSolParse`), from a test's account list and instruction data, calls `main()` and reads the accounts back. `msc test program/index.ms` runs instruction handlers natively, with UBSan when asked, and compares against the JS model of `rules/`. Its surface is a world, not a buffer: `Simulator.create()`, `wallet()`, `mint(decimals)`, `mintTo`, `run(op, args, accounts)`, `balance`, `kindOf`, `clock(slot)`; CPIs to the System, Token and Associated Token programs are modelled in the simulator, CPIs to anything else are recorded and returned for the test to assert on.

```ms
test "take pays the maker and empties the vault" {
	const world = Simulator.create();
	const maker = world.wallet();
	const taker = world.wallet();
	const mintA = world.mint(6);
	world.mintTo(mintA, maker, 1000);
	const made = world.run(EscrowOp.Make, { seed: 7, deposit: 1000, receive: 500 }, [maker, mintA, …]);
	assert made.ok;
	assert world.balance(mintA, world.ata(mintA, made.value.escrow)) == 1000;
}
```
2. **LiteSVM** (JS harness). The `.so` from `--os=solana`, real syscalls, CU numbers.
3. **Devnet** with the ER, VRF and crank.

A rule of the game changes in `rules/`, and all three lanes pick it up.

## 11. Clients and the IDL

Anchor's IDL is how clients, explorers and indexers find a program's instructions, accounts, types and errors. The toolkit generates the same JSON from the program's own declarations, at compile time: the instructions from the `Op` enum and their argument structs, the account lists from the `accounts<T>()` structs with their signer and writable flags, the account and event types with their discriminators, and the error enum. An Anchor client reads it unchanged.

A MetaScript client needs no IDL: it compiles the program's layout module to JS and uses the same declarations, encoders and discriminators.

## 12. Language features this design depends on

Measured 2026-10-01 with a compiler built from the tree at main `8496efa2`, C and JS, plus `--os=solana` where stated.

| Feature | Used by | Status |
|---|---|---|
| `try` converts the error through a `converter` | §5 | works; no converter is a type error naming the pair |
| `Ptr<T>` field read/write, `p[]` copy, `this ref` call through `p[]`, `Ptr<T>` receiver | §4 | works |
| `distinct` with `@delegate` functions and fields, generic and nested | §3 | works (corpus 661) |
| `T.f()` inside a generic, `sizeof(T)` | verifiers | works |
| `==` on value structs, fixed-array fields included | `Pubkey` | works |
| `@comptime` running string code, returning a struct, folded inside a function under `--os=solana` | discriminators, `Pubkey.of` | works |
| A macro reading a struct's fields (names, written types) and an enum's members | `instruction`, `args`, `accounts`, the IDL | works through `getTypeArg()` and `getImpl(bindSym(…))` |
| Module-level `const` initialized by a `@comptime` call under `--os=solana` | program ids | refused (FREESTANDING E02), §14 |
| Field decorators on structs | constraints in `accounts<T>()` | parse error, §14 |
| `enum E: uint8` storage width | account fields | parse error, §14 |
| `Readonly<Ptr<T>>` refusing writes | `Owned<T>.data()` | not refused, §14 |
| Conversion into a proof type outside its module refused | §3 | not refused, §14 |
| Diagnostic for a value copy over 1 KB under `--os=solana` | §2 | not built |

## 13. Worked example: escrow

Anchor's escrow (`make` / `take` / `refund`) written against this design. Everything it uses is either in the sections above or in §12.

```ms
// escrow/layout.ms — shared by program, client and tests
import { Pubkey, AccountHead, ProgramError } from "std/solana";

export enum EscrowOp {
	Make,
	Take,
	Refund,
}

export enum EscrowKind: uint8 {
	Uninitialized,
	Escrow,
}

export struct Escrow {
	head: AccountHead;
	maker: Pubkey;
	mintA: Pubkey;
	mintB: Pubkey;
	seed: uint64;
	receive: uint64;
	bump: uint8;
}
export function accountKind(this typeof Escrow): EscrowKind { return EscrowKind.Escrow; }
export function accountVersion(this typeof Escrow): uint8 { return 1; }
export function ownerOf(this typeof Escrow, escrow: Escrow): Pubkey { return escrow.maker; }

export struct MakeArgs { seed: uint64; deposit: uint64; receive: uint64; }
export struct TakeArgs { seed: uint64; }
export struct RefundArgs { seed: uint64; }

export enum EscrowError {
	ZeroAmount,
}
export function asProgramError(this error: EscrowError): ProgramError {
	return ProgramError.custom(6000 + (error as int32) as uint32);
}
```

```ms
// escrow/index.ms
import {
	Signer, Writable, Mutable, Pda, External, ExternalMutable, Program, System,
	ProgramError, Seeds, accounts, opcode, args, close, exit,
} from "std/solana";
import { Token, AssociatedToken, Mint, TokenAccount, transferChecked, closeAccount } from "std/solana/token";
import { Escrow, EscrowOp, EscrowError, MakeArgs, TakeArgs, RefundArgs } from "./layout";

struct MakeAccounts {
	maker: Signer;
	mintA: External<Mint>;
	mintB: External<Mint>;
	@ata(mintA, maker) makerAtaA: ExternalMutable<TokenAccount>;
	@init(maker) @pda("escrow", maker, args.seed) escrow: Pda<Escrow>;
	@initAta(maker, mintA, escrow) vault: ExternalMutable<TokenAccount>;
	systemProgram: Program<System>;
	tokenProgram: Program<Token>;
	associatedTokenProgram: Program<AssociatedToken>;
}

struct TakeAccounts {
	taker: Signer;
	maker: Writable;
	@ownedBy(maker) @pda("escrow", maker, args.seed) escrow: Pda<Escrow>;
	@keyIs(escrow.mintA) mintA: External<Mint>;
	@keyIs(escrow.mintB) mintB: External<Mint>;
	@ata(mintA, taker) takerAtaA: ExternalMutable<TokenAccount>;
	@ata(mintB, taker) takerAtaB: ExternalMutable<TokenAccount>;
	@ata(mintB, maker) makerAtaB: ExternalMutable<TokenAccount>;
	@ata(mintA, escrow) vault: ExternalMutable<TokenAccount>;
	systemProgram: Program<System>;
	tokenProgram: Program<Token>;
	associatedTokenProgram: Program<AssociatedToken>;
}

struct RefundAccounts {
	maker: Signer;
	@ownedBy(maker) @pda("escrow", maker, args.seed) escrow: Pda<Escrow>;
	@keyIs(escrow.mintA) mintA: External<Mint>;
	@ata(mintA, maker) makerAtaA: ExternalMutable<TokenAccount>;
	@ata(mintA, escrow) vault: ExternalMutable<TokenAccount>;
	systemProgram: Program<System>;
	tokenProgram: Program<Token>;
}

function escrowSigner(escrow: Pda<Escrow>): Seeds {
	const data = escrow.account.data();
	return Seeds.of("escrow").key(data.maker).u64(data.seed).u8(data.bump);
}

function make(): Result<uint64, ProgramError> {
	const a = try args<MakeArgs>();
	if (a.deposit == 0 || a.receive == 0) { return Result.err(EscrowError.ZeroAmount); }
	const x = try accounts<MakeAccounts>(a);
	const escrow = x.escrow.account.data();
	escrow.maker = x.maker.key();
	escrow.mintA = x.mintA.key();
	escrow.mintB = x.mintB.key();
	escrow.seed = a.seed;
	escrow.receive = a.receive;
	escrow.bump = x.escrow.bump;
	const decimals = x.mintA.data().decimals;
	const _deposited = try transferChecked(x.makerAtaA, x.vault, x.mintA, x.maker, a.deposit, decimals, Seeds.none());
	return Result.ok(a.deposit);
}

function take(): Result<uint64, ProgramError> {
	const a = try args<TakeArgs>();
	const x = try accounts<TakeAccounts>(a);
	const escrow = x.escrow.account.data();
	const signer = escrowSigner(x.escrow);
	const amount = x.vault.data().amount;
	const _paid = try transferChecked(x.takerAtaB, x.makerAtaB, x.mintB, x.taker, escrow.receive, x.mintB.data().decimals, Seeds.none());
	const _released = try transferChecked(x.vault, x.takerAtaA, x.mintA, x.escrow.account, amount, x.mintA.data().decimals, signer);
	const _vaultClosed = try closeAccount(x.vault, x.maker, x.escrow.account, signer);
	const _escrowClosed = try close(x.escrow.account, x.maker);
	return Result.ok(amount);
}

function refund(): Result<uint64, ProgramError> {
	const a = try args<RefundArgs>();
	const x = try accounts<RefundAccounts>(a);
	const signer = escrowSigner(x.escrow);
	const amount = x.vault.data().amount;
	const _released = try transferChecked(x.vault, x.makerAtaA, x.mintA, x.escrow.account, amount, x.mintA.data().decimals, signer);
	const _vaultClosed = try closeAccount(x.vault, x.maker, x.escrow.account, signer);
	const _escrowClosed = try close(x.escrow.account, x.maker);
	return Result.ok(amount);
}

function dispatch(): Result<uint64, ProgramError> {
	return match (try opcode<EscrowOp>()) {
		EscrowOp.Make => make(),
		EscrowOp.Take => take(),
		EscrowOp.Refund => refund(),
	};
}

function main(): void { exit(dispatch()); }
main();
```

What this shows against the Anchor original: no IDL, no Borsh, no `Box`, no `require!`; the head is 2 bytes, not 8; the bump lives in `Pda<Escrow>` and in the account; `make` returns a typed error the client decodes from the same enum; and the tests sit in the same file (§10).

## 14. Compiler debt

Each row is a workaround the toolkit carries until the compiler card closes. Paying it back means removing the workaround named here.

| Gap | Workaround in std/solana | Card |
|---|---|---|
| A module-level `const` initialized by a `@comptime` call is not folded under `--os=solana` (E02) | well-known program ids are static functions returning a `@comptime { … }` block | `2026-10-01-solana-module-const-from-comptime-call` |
| Struct field decorators do not parse | `accounts<T>()` derives each check from the field's proof type; seeds, ATA and key constraints are calls after it (`pda<T>`, `expectAssociated`, `expectKey`) | `2026-10-01-struct-field-decorators` |
| `enum E: uint8` does not parse | account fields store `uint8` and expose the enum through an extension | `2026-10-01-enum-storage-width` |
| A write through `Readonly<Ptr<T>>` is accepted | `Owned<T>.data()` still returns `Readonly<Ptr<T>>`; the type documents the contract, the checker does not hold it | `2026-10-01-readonly-ptr-write-accepted` |
| Converting into a proof type is not restricted to its module | proofs come only from the verifiers by convention; review is the guard | `2026-10-01-proof-conversion-outside-module` |
| On JS, `(x as uint32) << n` with `x: uint8` shifts in the `uint8` width (`1` where C gives `256`) | widen into a typed local first, then shift (`Pubkey.toBase58`) | `2026-10-01-js-shift-after-widening-cast-keeps-narrow-width` |
