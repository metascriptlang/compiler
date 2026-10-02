# std/solana — design

The on-chain toolkit for MetaScript programs on Solana. The surface is MetaScript; what reaches the chain is Anchor's. Account and instruction discriminators, the zero-copy account layout, instruction encoding, error codes, events and the IDL follow Anchor byte for byte, so an Anchor client, explorer or indexer reads a MetaScript program without knowing it was not written in Rust. The account checks follow Anchor's and Pinocchio's: money is at stake, and an invented check is an unaudited one.

Where the compiler cannot express the design yet, the toolkit takes a measured workaround; §9 lists each one with its compiler card, so the debt is paid in one place.

The worked example is Anchor's escrow: `examples/escrow/layout.ms` (shared by program and client), `examples/escrow/program.ms` (the program and its host-simulator tests), `examples/escrow/idl.cms` (its Anchor IDL), `tools/solana/escrow.mjs` (the same program on LiteSVM).

## 1. Modules

| Module | Backends | Owns |
|---|---|---|
| `std/solana/pubkey.ms` | all, `@comptime` | `Pubkey` (32 bytes, alignment 1), base58, `pubkeyOf` at compile time, well-known program ids |
| `std/solana/discriminator.ms` | all, `@comptime` | Anchor's account, instruction and event discriminators, `snakeCase` |
| `std/solana/error.ms` | all | `ProgramError`: the runtime's builtin codes, Anchor's framework codes, `userError` |
| `std/solana/borsh.ms` | all | `BorshWriter`/`BorshReader` for clients |
| `std/crypto/sha256.ms` | all, `@comptime` | the SHA-256 the discriminators are computed with |
| `std/solana/core.cms` | C, SBF | syscalls, `Account`, `Bytes`, `Seeds`, `Instruction`, the proofs and verifiers, init/close/realloc, PDAs, dispatch and argument readers, events |
| `std/solana/macro.ms` | C, SBF | `instruction<Op>()`, `args<T>()`, `accounts<T>()`, `emitEvent<E>(value)` |
| `std/solana/token.ms` | C, SBF | Mint and token-account layouts, their verifiers, typed token CPIs, associated-account checks |
| `std/solana/magicblock.ms` | C, SBF | MagicBlock: `delegate`, `commit`/`commitAndUndelegate` (one account, a list, a list through the fee vault), the `undelegate` callback, `scheduleTask` |
| `std/solana/vrf.ms` | C, SBF | MagicBlock VRF: the scoped `requestRandomness` (one callback account or a list; paid by a signing wallet or by a program PDA signing with its seeds), `verifyVrfCallback` |
| `std/solana/arithmetic.ms` | `when (solana)` | signed `/ % /= %=` through unsigned division |
| `std/solana/idl.ms` | compile time | `anchorIdl<Op>(spec)`: the program's Anchor IDL as a string literal |
| `std/solana/host.cms` | C, host | the simulator: builds the runtime's input buffer, runs an entry function, reads the accounts back, runs System, Token and Associated Token CPIs |
| `std/solana/index.cms` / `index.ms` | C / JS | `std/solana` on chain is `core`; for a JS client it is the neutral modules |

## 2. A program

A handler returns `Result<uint64, ProgramError>` and reads its instruction, arguments and accounts through the macros; `examples/escrow/program.ms` `make` is the full shape. The entry is `when (!testBuild) { entry(); }` so the same file carries its simulator tests.

```ms
function make(): Result<uint64, ProgramError> {
	const a = try args<MakeArgs>();
	const x = try accounts<MakeAccounts>();
	const made = try createPda<Escrow>(x.maker, x.escrow, escrowSeeds(x.maker.key(), a.seed));
	made.account.data().receive = a.receive;
	…
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<EscrowOp>()) {
		EscrowOp.Make => make(),
		EscrowOp.Take => take(),
		EscrowOp.Refund => refund(),
	};
}
```

## 3. Accounts and proofs

A verifier is the only way to get a proof, and a function that needs a property takes the proof. Each proof is a `distinct Account` whose `key()`, `lamports()` and the rest are `@delegate`d to `Account`. `accounts<T>()` verifies a struct of proofs field by field, in declaration order, which is also the order the client lists the accounts.

| Proof | Verifier | Anchor | Checks, in order, and the code a failure returns |
|---|---|---|---|
| `Signer` | `signer(i)` | `Signer` | present (3005), signed (3010) |
| `WritableSigner` | `writableSigner(i)` | `#[account(mut)] Signer` | present, signed (3010), writable (2000) |
| `Writable` | `writable(i)` | `#[account(mut)] UncheckedAccount` | present, writable (2000) |
| `SystemAccount` | `systemAccount(i)` | `SystemAccount` | present, owned by the System program (3011) |
| `Account` | `unchecked(i)` | `UncheckedAccount` | present |
| `Program<P>` | `program<P>(i)` | `Program<'info, P>` | present, key is `P.id()` (3008), executable (3009) |
| `Owned<T>` | `owned<T>(i)` | `AccountLoader<T>` | present, owner is this program (3007), 8 bytes of data (3001), `T.discriminator()` (3002), `8 + sizeof(T)` bytes (3003) |
| `Mutable<T>` | `mutable<T>(i)` | `#[account(mut)] AccountLoader<T>` | as `Owned<T>`, then writable (2000), then exclusive (builtin 12) |
| `External<T>` | `external<T>(i)` | `InterfaceAccount<T>` | present, `T.acceptsOwner(owner)` (3007), `T.decode(data)` (3003) |
| `ExternalMutable<T>` | `externalMutable<T>(i)` | `#[account(mut)] InterfaceAccount<T>` | as `External<T>`, then writable (2000), then exclusive (builtin 12) |
| `Delegated<T>` | `delegated<T>(i)` | `UncheckedAccount` with `seeds`, then `T::try_deserialize` (MagicBlock `magic-actions` `UpdateLeaderboard`) | present, owner is the delegation program (3007), 8 bytes of data (3001), `T.discriminator()` (3002), `8 + sizeof(T)` bytes (3003); the address is checked by `pda`/`pdaWithBump` (2006) |

- **Exclusive.** A `Mutable` or `ExternalMutable` proof claims its account: the runtime marks a duplicated account in the input buffer as a pointer to the first record, and the claim writes the first record's marker byte, so a second mutable proof for the same account, through any index, is `AccountBorrowFailed`. This is Pinocchio's borrow state, which lives in the same byte. Anchor 0.31.1 accepts the duplicate unless the program writes a constraint; two `Ptr<T>` into one account is how a player fights their own pet.
- **Weakening.** `asSigner()` and `asWritable()` turn a `WritableSigner` (or a `Mutable<T>`) into the weaker proof a callee asks for. There is no conversion the other way.
- **Constraints** that need more than the field's type are calls after `accounts<T>()`: `pda`/`pdaWithBump` (2006), `expectHasOne` (2001), `expectAddress` (2012), and in `token.ms` `expectAssociated` (3014), `expectTokenMint` (2014), `expectTokenOwner` (2015).
- `Owned<T>.data()` and `Delegated<T>.data()` are read-only pointers, `Mutable<T>.data()` a writable one, all at offset 8 of the account data. A `Delegated<T>` is the last state the rollup committed to the base layer, and it is accepted only while delegated: an undelegated account is read as `Owned<T>`; `External<T>.read()` decodes the other program's layout (token layouts are packed, so they are read, not overlaid).

## 4. Account data

An account type is a fixed-size value struct declared in a module shared by the program and the client, with one exported static: `export function discriminator(this typeof Escrow): Discriminator { return @comptime { return accountDiscriminator("Escrow"); }; }`. The static must be exported, or the verifier generics in `core.cms` cannot see it. The bytes are Anchor's zero-copy account: the discriminator `sha256("account:" + name)[0..8]`, then the struct in its C layout, which is `#[account(zero_copy)]`'s `repr(C)`. `Pubkey` is `uint8[32]`, so it never adds padding. Anchor's zero-copy types are `bytemuck::Pod`, which has no padding, and its clients read the fields back to back, so a field may not follow C padding and a nested struct may not end with it; `anchorIdl` refuses both with the field's name. Order fields by alignment (64-bit first) or add an explicit padding field. Padding at the end of the account itself moves no field and is allowed (the escrow has 7 bytes).

- `create<T>` and `createPda<T>` follow Anchor's `init` (`anchor-syn-0.31.1/src/codegen/accounts/constraints.rs` `generate_create_account`): a target with no lamports is created with `create_account`; a prefunded one is topped up to rent exemption, allocated and assigned. Paying with the account being created is 4101. The discriminator is written after the account exists; `createPda` takes the canonical bump and refuses another address (2006).
- `close` is Anchor's (`anchor-lang-0.31.1/src/common.rs` `close`): every lamport to the destination, assigned to the System program, data resized to zero. Closing onto itself is 2011; a destination that would overflow is `ArithmeticOverflow` where Anchor's `unwrap` panics.
- `realloc` grows or shrinks the data, tops rent up from the payer through the System program or returns the excess lamports to the payer, and refuses growth past 10,240 bytes in one instruction (3016).
- Rejected: the two-byte kind/version head this design started with. It saved six bytes per account and carried a version, but no Anchor client, explorer or indexer can read it, and Anchor's closed-account handling no longer needs a sentinel.

## 5. Instructions, arguments, errors and events

- **Instruction.** 8 bytes of `sha256("global:" + snake_case(name))[0..8]`, then the arguments in Borsh. `instruction<Op>()` computes every member's discriminator at compile time; short data is `InstructionMissing` (100), no match `InstructionFallbackNotFound` (101).
- **Arguments.** `args<T>()` reads `T`'s fields at their Borsh offsets (sized integers, `boolean`, `Pubkey`); short data or a `bool` byte other than 0 and 1 is `InstructionDidNotDeserialize` (102), as Borsh refuses it.
- **Errors.** `ProgramError` carries the runtime's builtin errors (`n << 32`) and Anchor's codes with Anchor's numbers (`anchor-lang-0.31.1/src/error.rs`). A program's own errors are an enum; its `converter` to `ProgramError` returns `ProgramError.userError(ordinal)`, Anchor's `6000 + n`, and `try` converts through it. `Result.err(member)` in a handler that returns `ProgramError` does not convert (a converter does not apply to an open generic): call the converter by name, as `examples/escrow/program.ms` does.
- **Events.** `emitEvent<E>(local)` logs `sha256("event:" + Name)[0..8]` and the Borsh fields through `sol_log_data`, which a validator prints as `Program data: <base64>`, Anchor's `emit!`.

## 6. Signed division

Signed `/` and `%` on SBF are ~170 CU calls to `__divdi3`; unsigned division is one instruction. `std/solana/arithmetic.ms` overloads `/ % /= %=` on `int32` and `int64` under `when (solana)` to divide magnitudes as unsigned and restore the sign, equal to C's truncating division for every non-UB input (tested over a value matrix, C and JS). A program enables it for every module with one line in `build.ms`: `globalImports: ["std/solana/arithmetic"]`. Measured on the tree below: a program dividing in a module it imports links 20 `__divdi3`/`__moddi3` call sites without the line and 0 with it. A division by a constant power of two becomes a call instead of a shift, because the overload is not inlined across modules.

Rejected: routing every signed division through a runtime helper with an SBF-specific body. It would have made the compiler's emission target-specific; the toolkit owns the cost instead.

## 7. Clients and the IDL

`anchorIdl<Op>(spec)` returns the program's IDL in Anchor's 0.1.0 spec as a string literal built at compile time: instructions with snake_case names, discriminators, accounts with their `writable`/`signer` flags and known program addresses, Borsh arguments (a last `Bytes` argument is `bytes`); account types with discriminators and `bytemuck`/`repr(C)` layouts, a nested struct as a `defined` type listed in `types`, `T[N]` as an `array`, `BitSet<E>` as the integer it is stored in (`u8`, `u16`, `u32`, `u64` up to 8, 16, 32, 64 members, `[u8; ⌈n/8⌉]` above, bit = ordinal); events; the error enum from 6000. A nested struct must be imported where `anchorIdl` is called; any other field type is a compile error. `examples/escrow/idl.cms` prints it (`msc run examples/escrow/idl.cms > escrow.json`); its test parses the JSON on C. Not verified: loading the JSON in Anchor's TypeScript client.

A MetaScript client compiles the program's layout module to JS and uses the same declarations, `Pubkey`, discriminators and `BorshWriter`.

## 8. Testing

- **Host simulator** (`std/solana/host.cms` `run`). Serializes the accounts the way the runtime does, runs an entry function natively, reads the accounts back; System `CreateAccount`/`Assign`/`Transfer`/`Allocate`, Token `Transfer`/`MintTo`/`CloseAccount`/`TransferChecked` and Associated Token create are executed (`runtime/solana/host.c`), every other CPI is recorded. Verifier, dispatch, init/close/realloc, event and token pins: `std/solana/test.cms`, `std/solana/token.ms`; MagicBlock and VRF instruction bytes, checked against `ephemeral-rollups-sdk` (pinocchio `delegate.rs`, `utils.rs`), the VRF SDK and the validator's `process_schedule_commit.rs`: `std/solana/magicblock.ms`, `std/solana/vrf.ms`; the escrow's: `examples/escrow/program.ms`.
- **LiteSVM** (`tools/solana`, `litesvm` 1.4.1, `@solana/kit` 8.2.0). `node tools/solana/escrow.mjs <escrow.so>` runs make, take, refund and a refused make against the real SPL Token and Associated Token programs. Measured on tree `cb9810dbe7c0` with `msc build examples/escrow/program.ms --os=solana` (platform-tools v1.57): make 44,817 CU, take 50,634 CU, refund 32,940 CU (after make 52,317 CU), make with a zero deposit `Custom(6000)` at 587 CU; every balance and closure assertion passed.

## 9. Compiler debt

Each row is a workaround the toolkit carries until the compiler card under `~/metascript/.inbox/compiler/` closes. Paying it back means removing the workaround named here.

| Gap | Workaround in std/solana | Card |
|---|---|---|
|---|---|---|
| A module-level `const` initialized by a `@comptime` call is not folded under `--os=solana` (E02) | well-known program ids are static functions returning a `@comptime { … }` block | `2026-10-01-solana-module-const-from-comptime-call` |
| Struct field decorators do not parse | `accounts<T>()` derives each check from the field's proof type; seeds, ATA and key constraints are calls after it (`pda`, `pdaWithBump`, `expectHasOne`, `expectAddress`, `expectAssociated`) | `2026-10-01-struct-field-decorators` |
| `enum E: uint8` does not parse | account fields store `uint8` and expose the enum through an extension | `2026-10-01-enum-storage-width` |
| A write through `Readonly<Ptr<T>>` is accepted | `Owned<T>.data()` still returns `Readonly<Ptr<T>>`; the type documents the contract, the checker does not hold it | `2026-10-01-readonly-ptr-write-accepted` |
| Converting into a proof type is not restricted to its module | proofs come only from the verifiers by convention; review is the guard | `2026-10-01-proof-conversion-outside-module` |
| On JS, `(x as uint32) << n` with `x: uint8` shifts in the `uint8` width (`1` where C gives `256`) | widen into a typed local first, then shift (`Pubkey.toBase58`) | `2026-10-01-js-shift-after-widening-cast-keeps-narrow-width` |
| `import { A } from "./a"` written before `export * from "./a"` drops `A` from the re-export | `std/solana/core.cms` puts its `export *` lines before its imports | `2026-10-01-export-star-after-import-drops-the-name` |
| `export *` keeps one of a same-named overload set: an extension in a second module, or a static beside a same-named free function, is lost through a hub | proofs and verifiers live in `core.cms` beside `Account`; `AccountMeta` statics are `writableKey`/`readonlyKey` | `2026-10-01-export-star-drops-same-named-extension-of-second-module` |
| An exported `@delegate` whose base is in another module has "no implementation" at the use | delegates sit in `core.cms` with `Account` | `2026-10-01-delegate-base-in-another-module` |
| `msc test` on a module emits its uninstantiated generics (with `try` between generics, or instantiated from a type declared under `when (testBuild)`) | verifiers keep their generic part to `T.discriminator()` and `sizeof(T)`; proof tests live in `std/solana/test.cms` | `2026-10-01-msc-test-emits-uninstantiated-generic-with-try` |
| A macro emitting a call to a generic function through `bindSym` crashes `msc` | `instruction<Op>()`, `args<T>()` and `accounts<T>()` emit plain identifiers for `selectInstruction` and `readArgs`, so a program imports both beside the macro | `2026-10-01-bindsym-of-a-generic-function-crashes-msc` |
| A macro re-exported through an `export *` hub is not expanded | programs import `instruction` and `args` from `std/solana/macro`, not from `std/solana` | `2026-10-01-macro-through-export-star-hub-is-not-expanded` |
| A user macro named like a directive (`emit`) is silently dropped | the event macro is `emitEvent<E>(value)`, not Anchor's `emit` | `2026-10-01-macro-named-like-a-directive-is-silently-dropped` |
| Indexing an array field through a `this ref` receiver emits `.` on a pointer in C | `BorshReader` reads its bytes through value-parameter helpers | `2026-10-01-array-field-through-ref-receiver-emits-dot` |
| Names used only in a macro type argument or a `@comptime` block are reported "imported but never used" | none; the warnings are expected in std/solana programs | `2026-10-01-names-used-only-at-compile-time-reported-unused` |
