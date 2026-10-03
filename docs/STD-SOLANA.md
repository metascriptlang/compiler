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
| `std/solana/core.cms` | C, SBF | syscalls, `Account`, the proofs and verifiers, init/close/realloc, the signable System CPIs, `createPdaOf` and the PDA verifiers the seed macros call, dispatch and argument readers, events; re-exports the CPI and buffer types |
| `std/solana/buffer.cms` | C, SBF | `Bytes` and `BorshBuffer`, the little-endian writer over storage the caller declared; a leaf module, so `cpi.cms` can take a `BorshBuffer` |
| `std/solana/cpi.cms` | C, SBF | `InstructionAccount`, `CpiAccount` and `CpiInstruction` (the runtime's `SolAccountMeta`, `SolAccountInfo` and `SolInstruction`), `invokeCpi` and `invokeList`; a leaf module, not in the `std/solana` barrel except the names `core.cms` re-exports |
| `std/solana/invoke.ms` | C, SBF | the `invoke` and `invokeSigned` macros; imports only `cpi.cms`, so `core.cms`, `mint.ms` and `delegation.ms` can use them without a cycle (§4) |
| `std/solana/seed.cms` | C, SBF | `SeedSlice` and `SignerSeeds` (the runtime's seed and signer layouts), the seed builders, `SeedTable`, `signingOf`, and the derivation cores under the seed macros; not in the `std/solana` barrel |
| `std/solana/littleEndian.ms` | all | `leBytes(value)` for `uint16`, `uint32`, `uint64` |
| `std/solana/macro.ms` | C, SBF | `instruction<Op>()`, `args<T>()`, `accounts<T>()`, `emitEvent<E>(value)`, the seed macros `programAddress`, `programAddressOf`, `findProgramAddress`, `findProgramAddressOf`, `pda`, `pdaWithBump`, `createPda<T>`, `createMintPda`, `delegate`, and `signed(call, seeds)` |
| `std/solana/mint.ms` | C, SBF | the token-program check, `initializeMint2` and `createMintPdaAt`, which `createMintPda` calls; kept out of `token.ms` and `macro.ms` for the reason in §4 |
| `std/solana/token.ms` | C, SBF | Mint and token-account layouts, their verifiers, typed token CPIs, associated-account checks; re-exports `initializeMint2` and `createMintPda` |
| `std/solana/delegation.ms` | C, SBF | `DelegationAccounts`, `DelegationConfig` and `delegateAt`, which the `delegate` macro calls; a module `macro.ms` imports must not import `macro.ms` back (§4) |
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
	const made = try createPda<Escrow>(x.maker, x.escrow, ["escrow", x.maker, leBytes(a.seed)]);
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
- **Constraints** that need more than the field's type are calls after `accounts<T>()`: `pda`/`pdaWithBump` (2006, seeds as in §4), `expectHasOne` (2001), `expectAddress` (2012), and in `token.ms` `expectAssociated` (3014), `expectTokenMint` (2014), `expectTokenOwner` (2015).
- `Owned<T>.data()` and `Delegated<T>.data()` are read-only pointers, `Mutable<T>.data()` a writable one, all at offset 8 of the account data. A `Delegated<T>` is the last state the rollup committed to the base layer, and it is accepted only while delegated: an undelegated account is read as `Owned<T>`; `External<T>.read()` decodes the other program's layout (token layouts are packed, so they are read, not overlaid).

## 4. Account data

An account type is a fixed-size value struct declared in a module shared by the program and the client, with one exported static: `export function discriminator(this typeof Escrow): Discriminator { return @comptime { return accountDiscriminator("Escrow"); }; }`. The static must be exported, or the verifier generics in `core.cms` cannot see it. The bytes are Anchor's zero-copy account: the discriminator `sha256("account:" + name)[0..8]`, then the struct in its C layout, which is `#[account(zero_copy)]`'s `repr(C)`. `Pubkey` is `uint8[32]`, so it never adds padding. Anchor's zero-copy types are `bytemuck::Pod`, which has no padding, and its clients read the fields back to back, so a field may not follow C padding and a nested struct may not end with it; `anchorIdl` refuses both with the field's name. Order fields by alignment (64-bit first) or add an explicit padding field. Padding at the end of the account itself moves no field and is allowed (the escrow has 7 bytes).

- `create<T>` and `createPda<T>` follow Anchor's `init` (`anchor-syn-0.31.1/src/codegen/accounts/constraints.rs` `generate_create_account`): a target with no lamports is created with `create_account`; a prefunded one is topped up to rent exemption, allocated and assigned. Paying with the account being created is 4101. The discriminator is written after the account exists; `createPda` takes the canonical bump, signs with the seeds and that bump, and refuses another address (2006).
- `close` is Anchor's (`anchor-lang-0.31.1/src/common.rs` `close`): every lamport to the destination, assigned to the System program, data resized to zero. Closing onto itself is 2011; a destination that would overflow is `ArithmeticOverflow` where Anchor's `unwrap` panics.
- `realloc` grows or shrinks the data, tops rent up from the payer through the System program or returns the excess lamports to the payer, and refuses growth past 10,240 bytes in one instruction (3016).
### PDA seeds

A seed list is written where it is used: `findProgramAddress(["pet", mint, [bump]])`. Anchor builds its seeds at the constraint, on the stack, from the account fields and `to_le_bytes()` (`anchor-syn-0.31.1/src/codegen/accounts/constraints.rs` `generate_constraint_seeds`, lines 1133-1180: `find_program_address(&[…], &program)` without a bump, `create_program_address(&[…, &[b][..]], &program)` with one, a failure of the latter mapped to `ConstraintSeeds`). Pinocchio hands the syscall a `Seed { ptr, len }` table borrowed from the caller (`pinocchio-0.9.3/src/instruction.rs` lines 190-270). MetaScript has no lifetimes and refuses a view as a struct field or array element (`paper/NIM-REF.md` CK-139), so the list is a macro argument: each call expands its list into a table of `SeedSlice`s on the caller's stack and passes it as a `Span<SeedSlice>` to a core in `seed.cms`. There is no `Seeds` value to build, keep, or return from a helper, and nothing touches the heap.

| Seed | Written as | Bytes the syscall reads |
|---|---|---|
| string | `"pet"`, or a `string` value | the string's bytes |
| bytes | `[bump]`, a `uint8[N]`, a `Span<uint8>`, a `uint8[]` | the array in place |
| `Pubkey` | `mint`, `x.maker.key()` | its 32 bytes in place |
| account | `x.maker`, any proof, an `Account` | the key in the runtime's input buffer, at the account's address + 8 |

Any other type, an integer, a boolean or a struct, is a compile error that names the seed: write an integer as bytes, `[x]` for a `uint8` and `leBytes(x)` for a `uint16`, `uint32` or `uint64`, as Anchor makes the author write `to_le_bytes()`. A list that is not an array literal is a compile error too (`solanaSeedIntegerRefused.ms`, `solanaSeedListRequired.ms`). More than 16 seeds, or a seed over 32 bytes, is `MaxSeedLengthExceeded`; `findProgramAddress` takes 15 because the bump is the 16th. `pdaWithBump` answers `ConstraintSeeds` for any failure, as Anchor's `map_err` does.

| Macro | Result |
|---|---|
| `programAddress(seeds)`, `programAddressOf(program, seeds)` | `Result<Pubkey, ProgramError>`, `create_program_address`; the list includes the bump |
| `findProgramAddress(seeds)`, `findProgramAddressOf(program, seeds)` | `Result<ProgramAddress, ProgramError>` |
| `pda(account, seeds)`, `pdaWithBump(account, seeds, bump)` | for a `Mutable<T>` a `Pda<T>`, for a `Delegated<T>` the bump; `ConstraintSeeds` (2006) when the address differs |
| `createPda<T>(payer, target, seeds)` | `Result<Pda<T>, ProgramError>`, signed with the seeds and the found bump |
| `createMintPda(payer, mint, seeds, program, decimals, authority, freeze)` | the bump |

`createPda<T>` expands to `createPdaOf<T>`, `instruction<Op>()` to `selectInstruction`, `args<T>()` and `accounts<T>()` to `readArgs`: each macro binds its callee by symbol, so the program imports none of them.

### Signing

A signed CPI writes its signer seeds where the call is written, as Anchor does with `CpiContext::new_with_signer(program, accounts, &[&[b"vault", key.as_ref(), &[bump]]])` (`anchor-lang-0.31.1/src/context.rs:178-210`, a `&[&[&[u8]]]`) and Pinocchio with `invoke_signed(&instruction, &accounts, &[Signer::from(&seeds)])`, a `Signer { seeds: *const Seed, len }` over a slice the caller owns (`pinocchio-0.9.3/src/instruction.rs:238-270`, `src/cpi.rs:126-300`). One macro covers every signing call: `signed(call, seeds)`, where `call` is the unsigned call as the author writes it and `seeds` is one list, or a list of lists for several signers.

```ms
const _released = try signed(
	transferTokens(x.vault, x.takerAtaA, x.mintA, escrowAccount, held),
	["escrow", escrow.maker, leBytes(escrow.seed), [verified.bump]],
);
const _sent = try signed(invoke(program, accounts, data), [["identity", [b1]], ["vrf-payer", [b2]]]);
```

A list is a list of signers when every element is a list that holds a seed (a string, a key, an account), and one signer otherwise, so `[[7]]` is one signer with the seed `[7]`; a list that mixes the two is a compile error. Each signer's seeds become a `SeedSlice` table on the caller's stack, as in §4 above, and the signers a `SignerSeeds` table over them (the runtime's `SolSignerSeeds`: the address of the slices and their count), passed as the call's last argument, `signers: Span<SignerSeeds>`. A signable function declares that parameter with the default `[]`, so the unsigned call takes no seeds argument at all, and `signed` replaces the default with the table. `SignerSeeds` is not in the `std/solana` barrel: an author has no value to build, hold or return. The seed limits are the runtime's, 16 seeds of 32 bytes per signer, and the std does not check them again: the host simulator refuses past them with `MaxSeedLengthExceeded` and the runtime fails the CPI (LiteSVM 1.4.1: 17 seeds `MaxSeedLengthExceeded`, a 33-byte seed `ProgramFailedToComplete`, 16 seeds sent, in `heapExhausted.mjs`; `std/solana/test.cms` pins the same three on the host); the host simulator also refuses more than 16 signers, a limit not measured on the runtime. Nothing on the signing path touches the heap.

`signed` reads the callee's signature from the type of the call it receives, so it names the callee when that has no `signers` parameter (`logU64 takes no signers`), and a signable function is never overloaded (the macro sees one signature). The call is type-checked as written before `signed` expands it, which has two consequences: an argument that the unsigned form refuses is refused (`transferTokens` takes its authority as an `Account`, not a `Signer` proof, because a PDA authority is not a signer of the transaction), and a generic call with a type argument cannot sit inside it (`signed(create<T>(…), …)` fails, §9; the PDA path is `createPda<T>`, and a proof is read into a local first).

| Signable | Takes `signers` |
|---|---|
| `core.cms` | `createAccount`, `assignTo`, `transfer`, `allocate`, `createProgramAccount` |
| `cpi.cms` | `invokeCpi` (what `invoke` and `invokeSigned` expand to) and `invokeList` |
| `token.ms` | `mintTo`, `transferChecked`, `closeAccount`, `createAssociatedToken`, `createAssociatedTokenIdempotent`, `transferTokens`, `mintTokens`, `closeTokenAccount` |
| `vrf.ms` | `requestRandomness` with a callback list: the program identity always signs, a payer PDA is the one signer passed |

`delegate(accounts, seeds, bump, config)` is its own macro because the seeds are also data: the delegation program stores them (without the bump) for the undelegate callback. It expands to `delegateAt` in `delegation.ms`, a module `macro.ms` can import because it does not import `macro.ms` back.

Why the shape is not simpler:

- **A macro cannot pass its argument's type through a second macro with `getType`.** The seed macros hand the list to one macro that builds the table (`seedTable`), and there `getType(element)` fails with `node has no type`; `element.nodeType`, the type-AST of the value, is there and carries the same shapes. Measured on compiler base `da84849e` with `msc run`.
- **A module that defines a macro must not be a module the program links.** `token.ms` with a macro in it kept `std/meta` in the SBF build, and that pulls `runtime/crypto/hash.c`, which clang for SBF cannot compile. `macro.ms` importing `token.ms`, which imports `macro.ms` for its tests, did the same through the cycle. `mint.ms` holds what `createMintPda` calls so that `macro.ms` imports a module that imports nothing from it.
- **A table address must outlive the call that reads it.** `SeedSlice` holds addresses into the frame that built it, so a builder takes a `Span`, never a `Pubkey` by value (a value parameter may be a copy), and `fillWithBump` takes the table by `ref` so the bump byte sits in the caller's frame.

- Rejected: the heap `Seeds` value built by chaining (`Seeds.empty(2).addText("pet").addPubkey(mint)`), deleted: about 200 bytes of the 32 KiB heap per derivation, so 163 PDA checks in one instruction exhausted it, a signed CPI took 112 more bytes than an unsigned one, and a helper could return one built from its own parameters.
- Rejected: the two-byte kind/version head this design started with. It saved six bytes per account and carried a version, but no Anchor client, explorer or indexer can read it, and Anchor's closed-account handling no longer needs a sentinel.

### Cross-program invocations

A CPI lists its accounts and writes its data where the call is written, and takes nothing from the heap. Pinocchio builds the same three things on the caller's stack: the `InstructionAccount` array, the data in a `[u8; N]` written in place (`pinocchio-system-0.5.0/src/instructions/create_account.rs`, `[0; 52]` and `copy_from_slice`), and the `CpiAccount` array the runtime reads, sized by a const generic (`pinocchio-0.9.3/src/cpi.rs:34-300`, `invoke_signed<const ACCOUNTS>`; `slice_invoke_signed` uses a fixed `MAX_CPI_ACCOUNTS` for a count known only at run time). MetaScript has no const generics, so the count is the length of the list the author writes and a macro sizes the arrays from it:

```ms
let storage: uint8[12] = [];
const sent = invoke(
	Pubkey.systemProgram(),
	[InstructionAccount.writableSigner(source), InstructionAccount.writable(destination)],
	borshBuffer(storage).u32(2).u64(lamports),
);
```

- **Shapes.** `invoke(program, accounts, data)` is `invokeSigned(program, accounts, data, [])`; `signed(invoke(…), seeds)` signs it like any call, and a function that forwards its own `signers: Span<SignerSeeds>` calls `invokeSigned`. Both expand to `invokeCpi(program, accounts, <one zeroed CpiAccount per account>, data, signers)`: each element of the list is evaluated once, and the core fills the `CpiAccount` of an `InstructionAccount` from the account record the key points into (the key is the address of the account's key, so the record is 8 bytes below it) with the account's own flags, while the `InstructionAccount` keeps the flags the call asked for. A count known only at run time is `invokeList(program, accounts, data, signers)`, which keeps its `CpiAccount`s in its own frame.
- **Limits.** 16 accounts, the local maximum of the ephemeral-rollups SDK (`ephemeral-rollups-sdk/rust/pinocchio/src/instruction/commit.rs:10` `MAX_LOCAL_CPI_ACCOUNTS`): a longer list written at the call is a compile error that names the limit (`solanaCpiAccountLimit.ms`), and a run-time list, `commit` among them, is `InvalidArgument`, the SDK's answer (`commit.rs:37-41`). Pinocchio's own cap is 64, which would take 3,584 bytes of a 4 KB frame in `CpiAccount`s (56 bytes each, the runtime's layout). The data buffer is the caller's `uint8[N]`: N is a capacity and the cursor is the length. Sizes chosen: the delegation 625 bytes (the SDK's `MAX_DELEGATE_ACCOUNT_ARGS_SIZE` plus the 8-byte discriminator, `rust/pinocchio/src/types.rs:4-8`), a VRF request and a scheduled task 1,024. A write past N poisons the cursor and the CPI answers `InvalidArgument` before it sends, as `BorshBuffer.written()` does; `requestRandomness` answers `InvalidInstructionData`, which the VRF SDK returns for a buffer that is too small (`rust/pinocchio/src/vrf/types.rs:78-81`). The CPI shapes at these limits build inside the frame: `solanaCpiFrame.ms`.
- **A buffer is a view into its frame.** `BorshBuffer` and the `Bytes` its `written()` returns hold the address of the `uint8[N]` that backs them; neither is returned from the function that declared the storage.
- **Why the core fills the `CpiAccount`s.** Building both arrays at the call site from the same list needs each account expression twice, so the macro would have to refuse an expression with a side effect or copy it; a probe of a 3-account CPI measured the call-site arrays at 912 bytes of `.text` and the core fill at 832. A core that keeps all 16 `CpiAccount`s in its frame for every CPI (`slice_invoke_signed`'s shape) measured 904 bytes, but puts the core's 944-byte frame under every CPI; whether a handler with several of them stays inside 4 KB was not measured.
- **Traps.** `invoke.ms` imports only `cpi.cms`, so `core.cms`, `mint.ms` and `delegation.ms` use the macros without importing `macro.ms` (§1, the cycle in §4 above). `signed` rebuilt its callee by name, which dropped the symbol a macro had bound and failed `signed(invoke(…), …)` with `Undefined variable 'invokeCpi'`; it keeps the callee as written. A sized array of length 0 (`AccountMeta[0]`) does not compile (`initializer for aggregate with no elements requires explicit braces`): pass `[]` where a view is wanted. `try scheduleTask(…)` on SBF fails with the overload prototype of §9 (clang: incompatible type for the account argument); `return scheduleTask(…)` builds.
- **What still allocates.** `clock`, `returnData`, `logPubkey`, `emitEvent` and the entry's account table call `msSolAlloc`; no CPI path does. `minimumBalance`, which `createProgramAccount` calls, took 24 bytes of the heap per call and reads the rent into a stack array now.
- Rejected: the heap `Instruction` (`forProgram(program, accountCapacity, dataCapacity)` with `addAccount` and `append…`), deleted: 160 bytes of the heap for a one-account CPI (664 for the probe's 512-byte one), so 50 of those exhausted it, and an overflow was a flag read at the end of the chain.

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
- **Heap exhaustion.** A program that asks for more than its 32 KiB heap logs `std/solana: the 32 KiB program heap is exhausted (asked N more bytes at P)` and ends with the runtime's `abort` syscall; the host simulator prints the same sentence and aborts. No caller ever sees NULL. Pinocchio's `BumpAllocator::alloc` returns null on exhaustion (`pinocchio-0.9.3/src/entrypoint/mod.rs:648-659`) and its panic handlers log and call `abort` (`mod.rs:436-505`); here `msArenaAlloc` (`runtime/manual.h`) is that panic. `node tools/solana/heapExhausted.mjs <heapProbe.so>`, with the probe built by `msc build tools/solana/heapProbe.ms --os=solana`, finds the first failing count on two allocation paths (class instances, one raw request), requires the seeds, CPI and rent paths to leave the heap where it is, and requires the named line, no access violation and fewer than the 1,400,000 CU of the budget, then does the same for a request of 2^64 - n bytes. Measured with LiteSVM 1.4.1: before, 163 PDA checks in one instruction died with `Access violation writing 8 bytes at address 0x18`, 50 CPI builders and 1,022 class instances with the same error, each burning the whole 1,400,000 CU, and a request of 2^64 - 1 bytes succeeded; after, each fails at the same count with the named line (286,873, 6,558 and 16,467 CU) and the largest request that fits fills the heap to its last byte. The seeds path is the fourth probe and no longer allocates: a seed list is a stack table (§4), so 1, 2, 163, 164 and 500 rounds leave the heap position at 0x300000048 and the instruction runs until the compute budget, 823 rounds at 1,398,740 CU, 824 rounds failing with `ComputationalBudgetExceeded`. The same script run against the heap-seed probe built by the old compiler fails 6 checks, the first at 2 rounds, where the heap position has already moved. Not measured: a program that raises its heap with `RequestHeapFrame`, whose size `runtime/manual.h` does not read.
- **Growth.** An array or string that outgrows its block takes a new block and copies the old size into it, which is `GlobalAlloc::realloc`'s default (`library/core/src/alloc/global.rs:286-300`, `copy_nonoverlapping(ptr, new_ptr, min(layout.size(), new_size))`), and Pinocchio's `BumpAllocator` defines only `alloc` and `dealloc` (`mod.rs:645-668`). The runtime's one entry is `msRealloc(old, oldSize, newSize)` (`runtime/manual.h`; hosted builds forward to libc `realloc`); a bare `realloc(` in an arena build is a compile error that names it. The arena shim used to copy the new size out of a block that held the old one, so the first `push` past a capacity ended in `sol_memcpy_`'s `Overlapping copy`, and an append to a string literal faulted writing the literal's `cap` word, because the atomic load of that word lowers to a load plus a store (`msStrCapLoad`, `runtime/core/string.h`, a plain load under `--gc=manual`). `heapProbe.ms` ops 6-9 push `uint64`s, build a literal and push onto it, push structs, and append `"ab"` to a string; `heapExhausted.mjs` reads every element back against a checksum at 1 to 250 elements, then grows each past the heap and requires the named line. Measured with LiteSVM 1.4.1 on tree `6a1cccd68fe1`: the old runtime fails 39 checks (`Overlapping copy` for the arrays, `Access violation writing 8 bytes at address 0x80` for the string), the new one passes all 119: 1,024 `uint64`s still run and the 1,025th names the heap (19,633 CU), likewise 512/513 structs and 4,096/4,097 appends. A block outgrown is not reclaimed, so one array that reaches 8 KiB has used 16,576 bytes of the heap by its next growth. The escrow's `.text` is byte-identical and its CU unchanged (make 35,962, take 32,977, refund 23,642). Not measured: more than one growing array alive at once.
- **Seed lists.** Measured on tree `051cd375cd42` with `msc build examples/escrow/program.ms --os=solana` from a clean working directory, LiteSVM 1.4.1, the same escrow program with its derivations written as lists and its signers still `Seeds`: the `.so` goes from 75,696 to 76,552 bytes, of which `.text` falls from 57,976 to 57,160 and the symbol and string tables grow by 1,673 (the new functions' mangled names carry the module path), make 35,962 to 35,858 CU, take 32,977 to 33,019, refund 23,642 to 23,698, the refused make 613 unchanged. `take` and `refund` write the list for `pdaWithBump` and build the heap `Seeds` for the signer, so each evaluated its seeds twice; the signer is a list too since §4 "Signing". Derivation through each seed kind equals the address the heap seeds derived (`std/solana/test.cms`, six addresses computed with the old compiler), and a changed `keyAddress` offset or seed-count limit fails the account and limit tests.
- **Signers.** Measured at commit `02b3e4a1c` with `msc build examples/escrow/program.ms --os=solana` from `/tmp` directories of one path length (the symbol table carries the module path), LiteSVM 1.4.1, against the previous commit built the same way: the `.so` goes from 74,560 to 73,312 bytes and `.text` from 57,160 to 56,528; make 35,858 to 35,797 CU, take 33,019 to 32,887, refund 23,698 to 23,594, the refused make 613 unchanged; `node tools/solana/escrow.mjs` passes. Taking `take` and `refund` below the heap-`Seeds` build needed the std-side limit check dropped from the signing path (the host simulator and the runtime refuse past 16 seeds of 32 bytes, so a program that exceeds them still fails loudly): with it, take was 33,016 and refund 23,716. The host simulator records each CPI's signer seeds (`HostInvocation.signerSeeds`); `std/solana/test.cms`, `token.ms`, `magicblock.ms`, `vrf.ms` and the escrow assert them for every signing path, and those assertions were written against the `Seeds` build first and kept unchanged through the port, so each path records the same seeds as before (a changed byte in the expected seeds fails four tests). The heap probe's signing path (`heapProbe.ms` ops 10 and 11, a CPI to the program itself) leaves the heap where an unsigned CPI does at 1, 2, 8 and 20 rounds; a CPI took 160 bytes of the heap, all of it the `Instruction` builder, signed or not, and a signed CPI cost 1,514 CU against 1,426 unsigned. The same script against the `Seeds` build fails four checks: a signed CPI took 272 bytes and 1,611 CU against 1,414. The macros bind `selectInstruction`, `readArgs` and `createPdaOf` by symbol: `std/solana/test.cms` imports none of them, and against the previous std it fails with `Undefined variable 'readArgs'`, `'selectInstruction'` and `'createPdaOf'`.
- **CPIs.** Measured on tree `bbc489cca678` with `msc build examples/escrow/program.ms --os=solana` from `/tmp` directories of one path length, against `da84849e`'s compiler loading the std of the commit before (`5533b769a`) from a second directory of the same length, platform-tools v1.57, LiteSVM 1.4.1: the `.so` goes from 73,176 to 69,864 bytes and `.text` from 56,528 to 52,944; make 35,797 to 35,846 CU, take 32,887 to 32,764, refund 23,594 to 23,520, the refused make 613 unchanged; `node tools/solana/escrow.mjs` passes, and the host-simulator assertions on every CPI's program, accounts, flags, data and signer seeds are the ones written against the heap builder (the System, `createAssociatedToken` and `scheduleTask` ones were added first, on that build). Per CPI from `heapExhausted.mjs`, a one-account CPI to the program itself with three data bytes: 160 bytes of the heap and 1,425 CU unsigned (1,513 signed) before, 0 bytes and 1,390 CU unsigned (1,457 signed) after, and the heap position after 1, 2, 8, 20 and 40 unsigned, signed and 512-byte-buffer CPIs, and after 1,000 rent reads, is the seeds path's; the same script against the old build fails 15 checks, and a rent-only probe against the old std (24 bytes per read) fails 4. A function's frame is the highest stack address it touches above the frame floor, read from `llvm-objdump` of the `.so`: the escrow's `take`, `refund` and `make` stay at 2,648, 2,040 and 1,400 bytes; `invokeCpi` takes 88, `invokeList` 944, the core of `commit` 544, `requestRandomness` 2,120, the core of `scheduleTask` 1,896, and a signed 16-account CPI beside a 1 KB buffer 2,776 (`solanaCpiFrame.ms`). Not measured: `--release` or an optimization flag (the escrow's `.so` was the same bytes with `--release` and the same size with `--passC=-O2`), a program that raises its frame, and more than one signed 16-account CPI in one handler.

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
| A user macro named like a directive (`emit`) is silently dropped | the event macro is `emitEvent<E>(value)`, not Anchor's `emit` | `2026-10-01-macro-named-like-a-directive-is-silently-dropped` |
| Names used only in a macro type argument or a `@comptime` block are reported "imported but never used" | none; the warnings are expected in std/solana programs | `2026-10-01-names-used-only-at-compile-time-reported-unused` |
| An overloaded function that returns a struct, called as an initializer or a `try` operand, is declared with its first overload's prototype under `--os=solana` (clang: "too many arguments") | no signable function is overloaded: each takes `signers: Span<SignerSeeds> = []`, and `requestRandomness` lost its single-account overload; measured for `requestRandomness` on the previous std and for `scheduleTask` under `try` on this one (it fails; `return scheduleTask(…)` builds), not for `commit` or `commitAndUndelegate`, which stay overloaded | `2026-10-03-sbf-overload-of-aggregate-return-emits-the-first-overloads-prototype` |
| A call with an explicit type argument inside a `try`, written as a macro argument, leaves `T` unbound | `create<T>` has no signing form (a PDA account is created by `createPda<T>`), and a proof is read into a local before it goes inside `signed(…)` | `2026-10-03-generic-call-with-type-argument-as-a-macro-argument-leaves-t-unbound` |
