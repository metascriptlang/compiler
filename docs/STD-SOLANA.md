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
| `std/solana/index.cms` / `index.ms` | C / JS | `std/solana` on chain is `pubkey`, `error`, `discriminator`, `core` and the macros; for a JS client it is the neutral modules |

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

`anchorIdl<Op>(spec)` returns the program's IDL in Anchor's 0.1.0 spec as a string literal built at compile time: instructions with snake_case names, discriminators, accounts with their `writable`/`signer` flags and known program addresses, Borsh arguments (a last `Bytes` argument is `bytes`); account types with discriminators and `bytemuck`/`repr(C)` layouts, a nested struct as a `defined` type listed in `types`, `T[N]` as an `array`, `BitSet<E>` as the integer it is stored in (`u8`, `u16`, `u32`, `u64` up to 8, 16, 32, 64 members, `[u8; ⌈n/8⌉]` above, bit = ordinal); events; the error enum from 6000. A nested struct must be imported where `anchorIdl` is called; any other field type is a compile error. `examples/escrow/idl.cms` prints it (`msc run examples/escrow/idl.cms > escrow.json`); its test parses the JSON on C, and `tools/solana/escrow.mjs` loads it in Anchor's TypeScript client (§8).

A MetaScript client compiles the program's layout module to JS and uses the same declarations, `Pubkey`, discriminators and `BorshWriter`.

## 8. Testing

- **Host simulator** (`std/solana/host.cms` `run`). Serializes the accounts the way the runtime does, runs an entry function natively, reads the accounts back; System `CreateAccount`/`Assign`/`Transfer`/`Allocate`, Token `Transfer`/`MintTo`/`CloseAccount`/`TransferChecked` and Associated Token create are executed (`runtime/solana/host.c`), every other CPI is recorded. Verifier, dispatch, init/close/realloc, event and token pins: `std/solana/test.cms`, `std/solana/token.ms`; MagicBlock and VRF instruction bytes, checked against `ephemeral-rollups-sdk` (pinocchio `delegate.rs`, `utils.rs`), the VRF SDK and the validator's `process_schedule_commit.rs`: `std/solana/magicblock.ms`, `std/solana/vrf.ms`; the escrow's: `examples/escrow/program.ms`.
- **LiteSVM** (`tools/solana`, `litesvm` 1.4.1, `@solana/kit` 8.2.0, `@coral-xyz/anchor` 0.31.1). `node tools/solana/escrow.mjs <escrow.so> <escrow.json>` builds every instruction with Anchor's client from the IDL and requires its accounts, flags and bytes to equal the hand-built ones, decodes the escrow account with Anchor's coder and names error 6000 from the IDL, then runs make, take, refund and a refused make against the real SPL Token and Associated Token programs. A field order swapped in the IDL's `Escrow` type, or a `writable` flag set on `mint_a`, fails it. Measured on tree `978fdc672e29` with `msc build examples/escrow/program.ms --os=solana` (platform-tools v1.57): make 35,961 CU, take 32,989 CU, refund 23,626 CU (after make 43,461 CU), make with a zero deposit `Custom(6000)` at 605 CU; every assertion passed. Tree `cb9810dbe7c0` measured 44,817 / 50,634 / 32,940 CU.
- **Heap exhaustion.** A program that asks for more than its 32 KiB heap logs `std/solana: the 32 KiB program heap is exhausted (asked N more bytes at P)` and ends with the runtime's `abort` syscall; the host simulator prints the same sentence and aborts. No caller ever sees NULL. Pinocchio's `BumpAllocator::alloc` returns null on exhaustion (`pinocchio-0.9.3/src/entrypoint/mod.rs:648-659`) and its panic handlers log and call `abort` (`mod.rs:436-505`); here `msArenaAlloc` (`runtime/manual.h`) is that panic. `node tools/solana/heapExhausted.mjs <heapProbe.so>`, with the probe built by `msc build tools/solana/heapProbe.ms --os=solana`, finds the first failing count on four allocation paths (PDA seeds, CPI builders, class instances, one raw request) and requires the named line, no access violation and fewer than the 1,400,000 CU of the budget, then does the same for a request of 2^64 - n bytes. Measured with LiteSVM 1.4.1: before, 163 PDA checks in one instruction died with `Access violation writing 8 bytes at address 0x18`, 50 CPI builders and 1,022 class instances with the same error, each burning the whole 1,400,000 CU, and a request of 2^64 - 1 bytes succeeded; after, each fails at the same count with the named line (286,873, 6,558 and 16,467 CU) and the largest request that fits fills the heap to its last byte. Not measured: a program that raises its heap with `RequestHeapFrame`, whose size `runtime/manual.h` does not read.
- **Growth.** An array or string that outgrows its block takes a new block and copies the old size into it, which is `GlobalAlloc::realloc`'s default (`library/core/src/alloc/global.rs:286-300`, `copy_nonoverlapping(ptr, new_ptr, min(layout.size(), new_size))`), and Pinocchio's `BumpAllocator` defines only `alloc` and `dealloc` (`mod.rs:645-668`). The runtime's one entry is `msRealloc(old, oldSize, newSize)` (`runtime/manual.h`; hosted builds forward to libc `realloc`); a bare `realloc(` in an arena build is a compile error that names it. The arena shim used to copy the new size out of a block that held the old one, so the first `push` past a capacity ended in `sol_memcpy_`'s `Overlapping copy`, and an append to a string literal faulted writing the literal's `cap` word, because the atomic load of that word lowers to a load plus a store (`msStrCapLoad`, `runtime/core/string.h`, a plain load under `--gc=manual`). `heapProbe.ms` ops 6-9 push `uint64`s, build a literal and push onto it, push structs, and append `"ab"` to a string; `heapExhausted.mjs` reads every element back against a checksum at 1 to 250 elements, then grows each past the heap and requires the named line. Measured with LiteSVM 1.4.1 on tree `6a1cccd68fe1`: the old runtime fails 39 checks (`Overlapping copy` for the arrays, `Access violation writing 8 bytes at address 0x80` for the string), the new one passes all 119: 1,024 `uint64`s still run and the 1,025th names the heap (19,633 CU), likewise 512/513 structs and 4,096/4,097 appends. A block outgrown is not reclaimed, so one array that reaches 8 KiB has used 16,576 bytes of the heap by its next growth. The escrow's `.text` is byte-identical and its CU unchanged (make 35,962, take 32,977, refund 23,642). Not measured: more than one growing array alive at once.

## 9. Compiler debt

Each row is a workaround the toolkit carries until the compiler card under `~/metascript/.inbox/compiler/` closes. Paying it back means removing the workaround named here.

| Gap | Workaround in std/solana | Card |
|---|---|---|
| A module-level `const` initialized by a `@comptime` call is not folded under `--os=solana` (E02) | well-known program ids are static functions returning a `@comptime { … }` block | `2026-10-01-solana-module-const-from-comptime-call` |
| Struct field decorators do not parse | `accounts<T>()` derives each check from the field's proof type; seeds, ATA and key constraints are calls after it (`pda`, `pdaWithBump`, `expectHasOne`, `expectAddress`, `expectAssociated`) | `2026-10-01-struct-field-decorators` |
| Every enum is 4 bytes; the reference sizes an enum by its range (1 byte up to 256 members) | account fields store `uint8` and expose the enum through an extension | `2026-10-01-enum-storage-width` |
| A `this ref` call or a `ref` argument through `Readonly<Ptr<T>>` still writes; a field write through it is refused | `Owned<T>.data()` returns `Readonly<Ptr<T>>`; a mutating `this ref` call through it is caught by review, not by the checker | `2026-10-01-readonly-ptr-write-accepted` |
| A `private` struct field crashes msc on C and is not enforced on JS, so a proof cannot hide its `Account` | proofs come only from the verifiers by convention; review is the guard | `2026-10-01-proof-conversion-outside-module` |
| `msc test` on a module emits its uninstantiated generics (with `try` between generics, or instantiated from a type declared under `when (testBuild)`) | verifiers keep their generic part to `T.discriminator()` and `sizeof(T)`; proof tests live in `std/solana/test.cms` | `2026-10-01-msc-test-emits-uninstantiated-generic-with-try` |
| A macro emitting a call to a generic function through `bindSym` crashes `msc` | `instruction<Op>()`, `args<T>()` and `accounts<T>()` emit plain identifiers for `selectInstruction` and `readArgs`, so a program imports both beside the macro | `2026-10-01-bindsym-of-a-generic-function-crashes-msc` |
| A user macro named like a directive (`emit`) is silently dropped | the event macro is `emitEvent<E>(value)`, not Anchor's `emit` | `2026-10-01-macro-named-like-a-directive-is-silently-dropped` |
| Names used only in a macro type argument or a `@comptime` block are reported "imported but never used" | none; the warnings are expected in std/solana programs | `2026-10-01-names-used-only-at-compile-time-reported-unused` |
