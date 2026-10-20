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
| `std/solana/core.ms` | C, SBF, JS | syscalls, `Account` and the non-generic cores behind the proofs (`ownedAccount`, `createdPdaAccount`, `closedProgramAccount`, …), init/close/realloc, the signable System CPIs, dispatch and argument readers, `logEvent` (the core under `emit`), the clock and the return data; re-exports the CPI and buffer names |
| `std/solana/typed.ms` | C, SBF, JS | the proofs, the only module that builds one (§3), and every generic entry point: `program<P>`, `owned<T>`, `mutable<T>`, `delegated<T>`, `external<T>`, `externalMutable<T>`, `create<T>`, `createPdaOf<T>`, `verifiedPda`, `verifiedPdaWithBump`, `close<T>`, `realloc<T>`, `selectLiteralInstruction<E>`, `readArgs<T>`, `Pda<T>`; each passes the type's constants to a core in `core.ms` and keeps the typed result (§8, Generic wrappers); `data<T>()` is a `Ptr<T>` into the account on C and a view over the simulated memory on JS (`msSolViewAt<T>` in `memory.jms`), so author code reads and writes the same fields on both |
| `std/solana/buffer.ms` | C, SBF, JS | `Bytes`, a view of the input buffer, and the `put*` functions that write little-endian fields into a caller's `uint8[N]` at an offset; a leaf module, so `core.ms` and its callers share it |
| `std/solana/invoke.ms` | C, SBF, JS | the `invoke` and `invokeSigned` macros; imports only `core.ms`, so `mint.ms` and `delegation.ms` can use them without importing `macro.ms` (§4) |
| `std/solana/seed.ms` | C, SBF, JS | `SeedSlice` and `SignerSeeds` (the runtime's seed and signer layouts), the seed builders, `SeedTable`, `signingOf`, and the derivation cores under the seed macros; not in the `std/solana` barrel |
| `std/solana/littleEndian.ms` | all | `leBytes(value)` for `uint16`, `uint32`, `uint64` |
| `std/solana/macro.ms` | C, SBF, JS | `instruction<Op>()`, `args<T>()`, `accounts<T>()`, `emit<E>(value)`, the seed macros `programAddress`, `programAddressOf`, `findProgramAddress`, `findProgramAddressOf`, `pda`, `pdaWithBump`, `createPda<T>`, `createMintPda`, `delegate`, `signed(call, seeds)`, `signedPda(call, pda, seeds)`, `scratch<T>(count)`, and the field decorators `seeds`, `bump`, `hasOne`, `address`, `associated`, `constraint`, `tokenMint`, `tokenAuthority`, which `accounts<T>()` reads (§3) |
| `std/solana/securityTxt.ms` | C, SBF, JS | the `securityTxt({...})` macro: the `solana-security-txt` block in the program's ELF (§5); on JS it checks the fields and emits nothing |
| `std/solana/mint.ms` | C, SBF, JS | the token-program check, `initializeMint2` and `createMintPdaAt`, which `createMintPda` calls, `associatedTokenAddress`, and the checks behind `associated`, `tokenMint` and `tokenAuthority`; kept out of `token.ms` and `macro.ms` for the reason in §4 |
| `std/solana/token.ms` | C, SBF, JS | Mint and token-account layouts, their verifiers, typed token CPIs, associated-account checks; re-exports `initializeMint2` and `createMintPda` |
| `std/solana/delegation.ms` | C, SBF, JS | `DelegationAccounts`, `DelegationConfig` and `delegateAt`, which the `delegate` macro calls; a module `macro.ms` imports must not import `macro.ms` back (§4) |
| `std/solana/magicblock.ms` | C, SBF, JS | MagicBlock: `delegate`, `commit`/`commitAndUndelegate` (one account, a list, a list through the fee vault), the `undelegate` callback, `scheduleTask` |
| `std/solana/vrf.ms` | C, SBF, JS | MagicBlock VRF: the scoped `requestRandomness` (one callback account or a list; paid by a signing wallet or by a program PDA signing with its seeds), `verifyVrfCallback` |
| `std/solana/hydra.ms` | C, SBF, JS | Hydra cranks on the ephemeral rollup: `createCrank` (one scheduled instruction, one-shot or repeating), `cancelCrank`, `crankAddress`, `legacyCrankAddress`, `crankSpent`; `HYDRA_PROGRAM_ID`, `MAGIC_VAULT_ID` |
| `std/solana/arithmetic.ms` | `when (solana)` | signed `/ % /= %=` through unsigned division |
| `std/solana/idl.ms` | compile time | `anchorIdl<Op>(spec)`: the program's Anchor IDL as a string literal |
| `std/solana/host.ms` | C host, JS | the simulator's surface: builds the runtime's input buffer, runs an entry function, reads the accounts back; `run`, `logs`, `invocations` and the test settings |
| `std/solana/memory.cms` / `memory.jms` | C, SBF / JS | the memory kernel: loads, stores, copy, fill and compare at an integer address, the address of a span, string or table, the account data room and claim record, the fault bridge. On C each is a `solana.h` function. On JS an integer address means nothing without a machine, so `memory.jms` is one: a simulated address space of regions over byte buffers, plain arrays and struct tables, with the runtime's input at `0x400000000` and the heap at `0x300000000`, and `msSolViewAt<T>` behind `data<T>()` |
| `std/solana/kernel.cms` / `kernel.jms` | C, SBF / JS | the syscall kernel: context, logs, sha256, curve check, program addresses, CPI, return data, clock, rent, and the host driver (`msSolHostEnter`, `Leave`, `Result`, …) that `host.ms` calls. On C they are `solana.h` syscalls on SBF and a simulator module on a host; on JS they call the same simulator modules over `memory.jms`. Only the runtime's boundary is split |
| `std/solana/simulator*.ms` | C host, JS | the host simulator's logic, shared by both backends: the host driver (`simulatorHost`: the context at the start of the heap in the runtime's layout, the heap arena, the input buffer, enter and leave; its storage is module arrays on C and mapped regions on JS), the input parse (`simulatorContext`), sha256, curve and address derivation (`simulatorCrypto`, `simulatorCryptoCore`), seed walks (`simulatorSeeds`), CPI metas (`simulatorMetas`), the System program (`simulatorPrograms`), Token, Token-2022 and Associated Token (`simulatorToken`), logs, base58, return data and sysvars (`simulatorLog`, `simulatorLogCore`), held accounts, signers, the CPI dispatcher and the invocation records (`simulatorInvoke`). They import only `./memory` and pure modules; `kernel.cms` pulls them into a host build under `when (!solana)`, each keeping its `solana.h` name with `@exportName`. Three of them are the program's own code on SBF too: the entry parse (`simulatorContext`), the seed walks (`simulatorSeeds`) and the CPI metas (`simulatorMetas`); `solana.h` keeps only their frames, uninitialized, and calls the `…At` routines, while a host or JS caller passes zeroed frames to the same routines. `runtime/solana/host.c` keeps the C half of the memory kernel's fault bridge and byte moves: the fault store, `msSolHostRaise`, copy with the overlap refusal, fill and compare |
| `std/solana/accountCodecKernel.cms` / `.jms` | C / JS | float bit casts and a zeroed byte array for the account codec (§4, Portable account bytes): `runtime/solana/accountCodec.h` on C, a `DataView` on JS |
| `std/solana/index.ms` | C, SBF, JS | `std/solana` is `pubkey`, `error`, `discriminator`, an explicit list from `core` and `typed`, and the macros, one barrel for every backend; the kernels the macros bind (`closedProgramAccount`, `resizedProgramAccount`, `createdAccount`, `createdPdaAccount`, `createAccountAllowPrefund`, the `*Failure`, `*Account` and `seeds*` checks, `keysEqual`, `createPdaOf`/`createPdaProven`/`createPdaAt`) are not on it, so `import { closedProgramAccount } from "std/solana"` is an error (`solanaProofFailurePrivate.ms`); a deep import of `std/solana/core` still reaches them |

## 2. A program

A handler returns `Result<uint64, ProgramError>` and reads its instruction, arguments and accounts through the macros; `examples/escrow/program.ms` `make` is the full shape. The entry is `when (!testBuild) { entry(); }` so the same file carries its simulator tests. A `--os=solana` build whose entry file calls nothing at its top level is refused, because the deployed program would answer success to every instruction without running one (measured 2026-10-15: the guard `solanaEmptyTopLevelRefused.ms` builds a `.so` on the previous compiler and is refused on this one; 79 Solana programs of `examples/`, `tools/solana/` and the guards build as before).

```ms
function make(): Result<uint64, ProgramError> {
	const a = try args<MakeArgs>();
	const x = try accounts<MakeAccounts>();
	const made = try createPda<Escrow>(x.maker, x.escrow, ["escrow", x.maker, leBytes(a.seed)]);
	made.asMutable().data().receive = a.receive;
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

### The program id

A program declares its id in the `defines` of its project's `build.ms`, the place Anchor keeps it in `Anchor.toml` beside `declare_id!`; `examples/escrow/build.ms`:

```ms
const config = {
	defines: { programId: "Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS" },
};
export default config;
```

`-d:programId=<base58>` on the command line overrides it. Every module of the program reads the same id; nothing is imported. With an id declared:

- `instruction<Op>()` checks no id at run time (Anchor's entry check, `anchor-syn-0.31.1/src/codegen/program/entry.rs:51-53`, was removed 2026-10-10, about 14 CU an instruction). The id the runtime executes the program under decides every owner check (`ownProgram()` is `msSolProgramId()`), every PDA derived at run time and every CPI signature, so a deploy at another address is a different program with its own state, not a hole in the declared one (evidence under "A program run at another id" below). `instruction<Op>()` still stops the build on a malformed id.
- `createPda<T>` with seeds that are all strings or byte lists written in place derives the address and the bump at compile time and checks the target with one key compare instead of the run-time find (`examples/anchorBench/helloworld/program.ms`, `["counter"]`). Seeds that name an account or an argument are derived at run time.
- `anchorIdl` writes the id as the IDL's `address`; a spec that names another address is a compile error.
- `declaredProgramId()` is the id as a `Pubkey`, for the host-simulator tests (`run(declaredProgramId(), …)`); with no id declared it is a compile error that names both ways to declare one.
- `programKeypair: "target/deploy/<name>-keypair.json"` (a path relative to `build.ms`, or absolute) names the deploy keypair; the build compares only its public half (bytes 32-63 of the `solana-keygen` JSON) and refuses an id that differs, naming the keypair's id, as `anchor keys sync` keeps them equal. Keep the keypair out of version control: name it with `-d:programKeypair=` on the deploy build, or in a `build.ms` that is not committed.

A malformed id is a compile error at `instruction<Op>()` (`solanaProgramIdRefused.ms`), and so is a keypair of another id (`solanaDeployKeypairMismatch.ms`). Without a declared id, `instruction<Op>()` checks no id and every PDA is derived at run time. Measured with `msc build <program> --os=solana --danger`, LiteSVM 1.4.1 and `tools/solana/anchorBench.mjs`, the std before and after, each program at the id its bench deploys it to: helloworld 7,920 to 6,696 bytes and `init` 2,196 to 1,740 CU (the folded PDA, and the id check); vault, whose PDA names the user, 6,144 to 6,376 bytes, `deposit` 1,914 to 1,938 CU and `withdraw` 562 to 587 (the id check alone); the measurements of the `4100` check, removed since, are these. `@seeds` of literal seeds (strings and byte lists written in place) with a bare `@bump` folds the same way, as Anchor v2's `seeds = [b"…"], bump` (lang-v2 derive `parse.rs` `emit_seeds_check`, `pda.rs` `precompute_pda`): `accounts<T>()` compares the key with the folded address, four word compares, and answers 2006 off it; a stored bump (`@bump(account.field)`) on literal seeds folds the same way and compares the stored bump with the folded canonical bump, so an address of a lower bump with its own stored bump is refused, where Anchor's `bump = expr` runs `create_program_address` and accepts it; with a non-literal seed it keeps the run-time hash. Measured on a program whose one instruction checks `@seeds("counter") @bump` on a `Mutable<Counter>` at helloworld's id, `msc build --os=solana --danger`, LiteSVM 1.4.1, the std before and after under the same compiler: 3,136 to 2,424 bytes, 571 to 183 CU, 2006 off the address in both. `src/test/guard/solanaSeedsFolded.ms` pins that the folded builds, bare and stored bump, call neither `sol_sha256` nor `sol_curve_validate_point` while the builds without an id call them, and runs the fixture's host tests (the canonical account accepted, an account one bit off and the address of other literal seeds refused with 2006). Not measured: the bench programs, none of which checks a literal-seed PDA with a bare `@bump`.

#### A program run at another id

The declared id is read at build time by the folded PDAs (`createPda<T>`, `@seeds` with a bare `@bump`), `anchorIdl` and `declaredProgramId()`; the runtime's id by everything else. Why the second is enough: the runtime lets a program change an account's data or debit its lamports only when the account's owner is the key of the program being executed (`solana-transaction-context-4.0.0` `instruction_accounts.rs:120-124, 331-349`), and derives a CPI's PDA signers with the caller's runtime key (`solana-program-runtime-4.0.0` `cpi.rs:886-888`). Pinocchio has no entry id check, and Anchor v2's lives under its default `guardrails` feature, which its own bench disables. A deploy keypair of another id is still a build error (`solanaDeployKeypairMismatch.ms`).

`node tools/solana/foreignDeploy.mjs before=<dir> after=<dir>` loads one `.so` at its declared id D and at a fresh id X in one LiteSVM (LiteSVM 1.4.1, mainnet-inactive feature set; the 13 instructions of the five Anchor bench programs and the escrow's `take` and `refund`, 48 scenarios a build) and asserts each outcome; `before` is the build with the `4100` check, `after` this tree. Measured 2026-10-10, both labels: all assertions hold.

| Scenario | before | after | D's accounts byte-identical, lamports unchanged |
|---|---|---|---|
| 1. instruction at D with D's accounts | ok | ok (14-17 CU less) | n/a |
| 2. instruction at X with D's accounts (modify, withdraw, close, take, refund, rotate) | 4100 | 2006 (vault, multisig `create`), 3007 owner (nested, prop-amm, multisig, escrow) | yes, all 17 refused calls |
| 3. init at X over D's folded PDAs (helloworld `init`, nested `initialize`), also with the PDA prefunded | 4100 | `PrivilegeEscalation` (the CPI signs with PDA(X), not PDA(D)); with PDA(X) accounts 2006 off the folded address | yes; no account at PDA(D) or PDA(X) |
| 3b. prop-amm `initialize` over D's existing oracle | 4100 | system 0 (account in use) | yes |
| 4. X with X-owned accounts | 4100 | runs as its own program (all but the two folded inits, which answer 2006) | yes |

Scenario 4 shows the one outcome that changes beyond the code: a program at X now works on X-owned accounts. prop-amm `initialize` called at X on a fresh keypair account creates an X-owned oracle (before: 4100), which touches nothing of D's. Not verified: a literal `@seeds` attribute with a bare `@bump` on an untyped `Writable` at X (it compares with PDA(D), and the runtime rules above leave X no write or signature for it; only `solanaSeedsFolded.ms`'s host tests run it), other feature sets, mainnet.

## 3. Accounts and proofs

A verifier is the only way to get a proof, and a function that needs a property takes the proof. Each proof is a struct whose one field is a private `Account`, so only `typed.ms` builds one: outside it, `as` from an account, from another proof or from an array or a `Result` of either, and a struct literal, are compile errors (`src/test/guard/solanaProofForgeRefused.ms`). `key()`, `keyAddress()`, `lamports()` and the rest read that account, and `asAccount()` weakens any proof to the `Account` a CPI takes. `accounts<T>()` calls the verifiers of the table below, so its expansion in the program's module builds no proof itself. `accounts<T>()` verifies a struct of proofs field by field, in declaration order, which is also the order the client lists the accounts; fewer accounts than fields is `AccountNotEnoughKeys` (3005) before any field is checked, as in Anchor v2, so a missing account hides an earlier field's other failure (`std/solana/test.ms` pins an unsigned first field with a missing second one).

| Proof | Verifier | Anchor | Checks, in order, and the code a failure returns |
|---|---|---|---|
| `Signer` | `signer(i)` | `Signer` | present (3005), signed (3010) |
| `WritableSigner` | `writableSigner(i)` | `#[account(mut)] Signer` | present, signed (3010), writable (2000) |
| `Writable` | `writable(i)` | `#[account(mut)] UncheckedAccount` | present, writable (2000) |
| `SystemAccount` | `systemAccount(i)` | `SystemAccount` | present, owned by the System program (3011) |
| `Account` | `unchecked(i)` | `UncheckedAccount` | present |
| `Program<P>` | `program<P>(i)` | `Program<'info, P>` | present, key is `P.id()` (3008), executable (3009) |
| `Owned<T>` | `owned<T>(i)` | `AccountLoader<T>` | present, owner is this program (3007), 8 bytes of data (3001), `T.discriminator()` (3002), `8 + sizeof(T)` bytes and valid bool/enum field values (3003) |
| `Mutable<T>` | `mutable<T>(i)` | `#[account(mut)] AccountLoader<T>` | owner/discriminator/length as above, writable (2000), borrow available (builtin 12), valid field values (3003), then exclusive claim |
| `External<T>` | `external<T>(i)` | `InterfaceAccount<T>` | present, then `T.verify(i)`: the owner is one `T.acceptsOwner(owner)` accepts (3007, called by `external<T>` itself, so a `verify` that forgets the owner still refuses a foreign one) and the data has the layout `T.decode` reads (3003), checked without building the value |
| `ExternalMutable<T>` | `externalMutable<T>(i)` | `#[account(mut)] InterfaceAccount<T>` | as `External<T>`, then writable (2000), then exclusive (builtin 12) |
| `Delegated<T>` | `delegated<T>(i)` | `UncheckedAccount` with `seeds`, then `T::try_deserialize` (MagicBlock `magic-actions` `UpdateLeaderboard`) | present, owner is the delegation program (3007), 8 bytes of data (3001), `T.discriminator()` (3002), `8 + sizeof(T)` bytes and valid field values (3003); the address is checked by `pda`/`pdaWithBump` (2006) |

- **Exclusive.** The runtime marks a duplicated account in the input buffer as a pointer to the first record. The entry parse writes 2 (`MS_SOL_DUPLICATED_RECORD`) into byte 4 of the first record, the first of four padding bytes the runtime writes as zero and never reads back, so every writable proof (`Writable`, `WritableSigner`, `WritablePda`, `Mutable`, `ExternalMutable`) whose account appears at more than one index, in the declared struct or as a trailing account, is `ConstraintDuplicateMutableAccount` (2040), and a repeat between read-only fields stays allowed: Anchor v2 sets the dispatch bitvec for both the repeating index and the one it repeats, then refuses when it meets a `mut` field (`lang-v2/src/dispatch.rs:108-111`, `cursor.rs:170-171`, `context.rs:144`). A `Mutable` or `ExternalMutable` proof also claims its account by writing 1 into the same byte, so a second mutable proof for the same index is `AccountBorrowFailed`. Pinocchio keeps its borrow state in byte 0, the runtime's duplicate marker; byte 4 sits beside the signer, writable and executable bytes, so one 32-bit load at byte 1 or 2 proves the flags and an unclaimed, unrepeated account together, and byte 0 stays as the runtime wrote it. Anchor 0.31.1 accepts the duplicate unless the program writes a constraint; two `Ptr<T>` into one account is how a player fights their own pet. A trailing account that repeats a declared writable field is refused when the field is proved, not when the trailing accounts are read, which is stricter than v2's lazy `remaining_accounts()` walk.
- **A `Delegated<T>` field of `accounts<T>()` is pinned** by `@seeds`+`@bump` or by `@address`; without one, any account the delegation program owns with `T`'s discriminator and size would pass, so the struct is a compile error naming the field (`solanaDecoratorRefused.ms`). The seeds may read the account's own data (`@seeds("pet", pet.mint) @bump(pet.bump) pet: Delegated<Pet>`). `delegated<T>(i)` called directly stays, and `pda`/`pdaWithBump` bind its address afterwards.
- **A `WritablePda` field of `accounts<T>()` declares its `@seeds`**; without them any writable account would pass and `createPda<T>` would sign for it with bump 0, so the struct is a compile error naming the field, through a base struct or an import alias too (`solanaWritablePdaNoSeedsRefused.ms`). `Writable` is the type when no derivation is meant. `writablePda(i)` called directly still hands out the proof with no seeds behind it (2026-10-12).
- **The struct `accounts<T>()` reads is the one its module declared.** A base struct's fields are checked first, with the base's decorators. The struct, each base and the data struct of a wrapper (`Owned<T>`, `Mutable<T>`, `Delegated<T>`, `Program<P>`) are told from a namesake where the macro is called: a local struct beside an import alias, or a `Base` other than the one the declaring module extends, is a compile error naming both structs and both modules (`solanaAccountsRootShadowRefused.ms`, `solanaAccountsBaseShadowRefused.ms`, `solanaAccountsDataShadowRefused.ms`; for `anchorIdl`, `solanaIdlBaseShadowRefused.ms` and `solanaIdlFieldTypeShadowRefused.ms`). The call site imports each base under its own name. One honest shape is refused with them: a base the declaring module imports from a third module, read by `accounts<T>()` in yet another module; call `accounts<T>()` in the declaring module (§9).
- **Weakening.** `asSigner()` and `asWritable()` turn a `WritableSigner` (or a `Mutable<T>`) into the weaker proof a callee asks for. There is no conversion the other way.
- **Constraints** that need more than the field's type are decorators on the field (below). The calls they replace stay for code that decides at run time: `pda`/`pdaWithBump` (2006, seeds as in §4), `expectHasOne` (2001), `expectAddress` (2012), and in `token.ms` `expectAssociated` (3014), `expectTokenMint` (2014), `expectTokenOwner` (2015).
- `Owned<T>.data()` and `Delegated<T>.data()` are read-only pointers, `Mutable<T>.data()` a writable one, all at offset 8 of the account data. A `Delegated<T>` is the last state the rollup committed to the base layer, and it is accepted only while delegated: an undelegated account is read as `Owned<T>`; `External<T>.read()` decodes the other program's layout (token layouts are packed, so they are read, not overlaid).

### Field-value boundary

Typed proofs validate raw bytes before exposing a pointer: bool is 0/1, enum is
an exact declared member, including sparse/signed members, nested structs and
fixed arrays. Invalid fields return 3003 without consuming the mutable claim.
The compiler supplies layout; the generated validator uses bounded word loads,
not a copy, heap allocation or runtime schema table.

This is deliberately stricter than an unchecked zero-copy Pod contract. The
source remains a normal boolean or enum instead of requiring wrapper types or
rejecting the field. The bool rule is checked serialization's 0/1 rule rather
than non-zero-is-true, avoiding an invalid C bool read while retaining repr(C)
account bytes.

On the std-solana candidate, LiteSVM 1.4.1/platform-tools v1.57, `--danger`:
one nested bool/enum plus `Species[64]` was **387 CU unchecked, 458 CU checked**.
The scalar per-byte prototype cost **803 vs 389 CU** (+414), so packed validation
reduces that overhead to **+71**, not to zero. `accountValues.mjs` runs all 256
values at each of 66 positions plus mixed/carry-boundary neighbours:
**16,905 cases passed**, invalid data 3003, max valid **458 CU**, cap 465.
The initial isolated consumer's `.so` was **3,192 → 3,816 B**; it is not a
general size estimate for arbitrary enum arrays.


### Constraints on a field

A constraint that needs more than the field's type is a decorator on the field, written where Anchor writes `#[account(…)]`. `accounts<T>()` first verifies every field by its type, as Anchor deserializes every account before any constraint (`anchor-syn-0.31.1/src/codegen/accounts/try_accounts.rs` `generate_constraints`, lines 141-175), then runs each field's constraints in declaration order and, inside a field, in Anchor's order whatever order they are written in (`constraints.rs` `linearize`, lines 71-137: seeds, associated token, has_one, constraint, address, token authority, token mint). The first failure is the answer.

```ms
export struct Take {
	taker: WritableSigner;
	maker: Writable;
	mintA: External<Mint>;
	@associated(mintA, taker) takerAtaA: ExternalMutable<TokenAccount>;
	@seeds("escrow", maker, leBytes(escrow.seed)) @bump(escrow.bump) @hasOne(maker) @hasOne(mintA)
	escrow: Mutable<Escrow>;
	@associated(mintA, escrow) vault: ExternalMutable<TokenAccount>;
}
```

| Decorator | Anchor (`anchor-syn-0.31.1`, `src/codegen/accounts/constraints.rs`) | Checks | Code |
|---|---|---|---|
| `@seeds(a, b, …)` with `@bump(account.field)` | `seeds = [..], bump = account.field`, `generate_constraint_seeds` (1133-1180) | the field's key is `create_program_address(seeds + [bump])`; with every seed a literal and a declared program id, the key is the folded address and the stored bump the folded canonical bump | ConstraintSeeds 2006, also when the address cannot be created, as Anchor's `map_err` |
| `@seeds(a, b, …)` with a bare `@bump` | `seeds = [..], bump` | the key is `find_program_address(seeds)`; with every seed a literal and a declared program id, the key is the address folded at compile time | 2006; the bump found is not returned (Anchor's `ctx.bumps`): read the stored one |
| `@hasOne(name, error?)` | `has_one = name @ error`, `generate_constraint_has_one` (297-334) | the data field `name` of this account equals the key of the sibling `name` | ConstraintHasOne 2001 |
| `@address(key, error?)` | `address = key @ error` (172-190) | the field's key equals `key` | ConstraintAddress 2012 |
| `@constraint(condition, error?)` | `constraint = condition @ error` (348-356) | the condition holds | ConstraintRaw 2003 |
| `@associated(mint, authority)` | `associated_token::mint`, `::authority` (1198-1254) | the token account's owner is the authority, then it is at the associated address of the authority and the mint | ConstraintTokenOwner 2015, then ConstraintAssociated 2009 |
| `@tokenAuthority(key)`, `@tokenMint(key)` | `token::authority`, `token::mint` (1256-1301) | the token account's owner, then its mint, equals `key` | 2015, 2014 |

Codes are `anchor-lang-0.31.1/src/error.rs` (59-101). Each takes the field's own key where it says "the field", so `@associated` is on the token account and names the mint and the authority. A `key` is an account (its key) or a `Pubkey`; the token program of `@associated` is the owner of the mint, and the field must be `External` or `ExternalMutable` of `TokenAccount` or `InterfaceTokenAccount`.

- **Names.** Inside an argument, a name that is a field of the struct is that account, and `field.member` is a member of its data when the field is an `Owned`, `Mutable` or `Delegated` of a struct that has `member` (`escrow.seed`, `config.authority`), else a member of the account (`maker.key()`). Every other name is the compiler's, resolved where `accounts<T>()` is written: a module-level const, function or type, and also a local of the handler, which is how an instruction argument is named (`leBytes(given.seed)` after `const given = try args<T>()`, Anchor's `#[instruction(…)]` by position; a handler without that local gets the compiler's `Undefined variable`, at the decorator). An argument is an account, a member, a call, an operator, a cast or a literal; anything else is a compile error.
- **Errors.** An error given to `@hasOne`, `@address` or `@constraint` is any `ProgramError` expression, or a value a converter turns into one, as Anchor takes any `Into<Error>` (`HibernalError.NotAuthority` where `converter hibernalError(error: HibernalError): ProgramError` is in scope); it is evaluated only when the check fails, where Anchor builds it (`constraints.rs` 297-334, 172-190, 348-356); `std/solana/test.ms` counts the evaluations, none on a success and one per failed check. Measured on the Hibernal-shaped program of `tools/solana/accountTableCost.mjs` (26 instructions, 59 decorated fields) against the eager form: `.so` 66,984 to 67,376 bytes, 64,660 to 64,228 CU over its 26 instructions, and one `@hasOne` or `@address` with an error 56 to 45 and 59 to 48 CU. Anchor's seeds, associated-token and token constraints take no custom error either.
- **Refused at compile time**, naming the struct, the field and the form: a name `accounts<T>()` does not read; `@seeds` without `@bump`, `@bump` without `@seeds` (Anchor's "bump must be provided with seeds", `parser/accounts/constraints.rs:733`), either twice; `@seeds` with no seed; `@hasOne` on a field that is not an `Owned`, `Mutable` or `Delegated` of a struct with that field, or naming something that is not a field; a token decorator on another field type; a `key` that is neither an account nor a `Pubkey`; `@associated` with a third argument (Anchor's `associated_token::token_program`).
- **Not supported:** `init`, `close`, `realloc` (the explicit `create<T>`, `createPda<T>`, `close`, `realloc`), `mut` and `signer` (the field's type), `owner`, `executable`, `rent_exempt`, `token::token_program` and the mint and extension constraints, optional accounts.
- **Position.** A struct with decorators expands to statements ahead of the one that holds `accounts<T>()` (the checker's macro prefix), so it is an initializer, `const x = try accounts<T>();`; inside `&&`, `||` or `?:` it is a compile error. A struct without decorators expands as it did.
- **Needs** the compiler's field decorators (`~/metascript/.inbox/compiler/2026-10-01-struct-field-decorators.md`): `accounts<T>()` reads `interfaceFieldDecorators` of the struct.

### Token accounts: legacy and interface

`Mint` and `TokenAccount` accept only an account the SPL Token program owns, with the exact legacy length (82 and 165 bytes), as Anchor's `Account<Mint>` does. `InterfaceMint` and `InterfaceTokenAccount` accept an account either program owns, as `InterfaceAccount<token_interface::Mint>` does. "Interface" means what the Token-2022 program itself says: it keeps SPL Token's base account layouts and its base instructions (`TransferChecked`, `MintTo`, `Burn`, `Close`, ...), so one set of calls speaks to both; an `InterfaceMint` is "a mint of the token interface", not "any account Token-2022 owns". The token functions (`transferTokens`, `mintTokens`, `burnTokens`, `closeTokenAccount`, `createTokenAccount`, `approveDelegate`, `revokeDelegate`, `setAuthorityOf`, `createAssociatedFor`, `expectAssociated`, `expectTokenMint`, `expectTokenOwner`) are generic over the four types, so a legacy and an interface account may be mixed in one call, and the CPI goes to the owner of the mint, never to a hard-coded program id (`TransferChecked` has one layout in both programs). Anything else in `External<T>` position is a compile error (`T` must satisfy the constraint).

For a Token-2022 account, `verify` and `decode` read the account-type byte at 165 and the extension table (a malformed table is 4 `InvalidAccountData`), and then refuse, by default, every extension that is not known to leave a held amount and a plain transfer as a program reads them. The refusal is `ProgramError.custom(4200)` (`unsupportedExtension` in `token.ms`; Anchor's own codes stop at 4102 and the Token-2022 program's at 48, so it collides with neither), returned by `external<InterfaceMint>(i)` before any CPI, with no account touched. An extension type this std does not know is refused too, so a type added to Token-2022 later is refused until it is read. The list is one place, `inertMintExtension` and `inertAccountExtension` in `token.ms`; an opt-in for one extension is a change to those two functions only.

| Side | Passes | Refused (hazards measured 2026-10-14 against the real Token-2022 program in LiteSVM 1.4.1 through the previous std, which accepted these mints; not a pin, because the std now refuses them before the CPI) |
|---|---|---|
| mint | MintCloseAuthority, InterestBearingConfig, ScaledUiAmount, MetadataPointer, TokenMetadata, GroupPointer, TokenGroup, GroupMemberPointer, TokenGroupMember | TransferFeeConfig (a transfer of 1000 delivers 990), PermanentDelegate (the delegate moves 500 from any holder without the owner), TransferHook (the transfer fails `MissingAccount` without the hook's accounts), NonTransferable, DefaultAccountState (new accounts start frozen), Pausable, ConfidentialTransferMint, ConfidentialTransferFeeConfig, ConfidentialMintBurn, PermissionedBurn and any type not listed |
| account | ImmutableOwner, MemoTransfer, CpiGuard | TransferFeeAmount, NonTransferableAccount, TransferHookAccount, PausableAccount, ConfidentialTransferAccount, ConfidentialTransferFeeAmount and any type not listed |

Why these pass: InterestBearingConfig and ScaledUiAmount change the UI amount only; a transfer of 120 raw units moves exactly 120 (`tools/solana/tokenInterface.mjs`, which also pins every accepted and refused type above, `Mint` against `InterfaceMint` on both programs, and the transfer through each pair of types). The metadata, group and pointer extensions are data about the mint. MintCloseAuthority lets the authority close a mint only once its supply is zero, so no held balance changes meaning. MemoTransfer and CpiGuard make a transfer fail, never move a different amount: with CpiGuard on the source an owner-signed transfer through a CPI fails with code 42 and moves nothing, with MemoTransfer on the destination and no memo it fails with code 36 and moves nothing, so a program that needs them hears about it at the call. A type number is the one `spl-token-2022-interface-2.1.0` `extension/mod.rs:1056-1121` assigns (0 to 27); `PermissionedBurn` (28) is in the std's enum but not that crate, and is refused with every other number above 27.

What the account side does not see: a token account of a mint with PermanentDelegate, DefaultAccountState, MintCloseAuthority or ConfidentialMintBurn carries no extension of its own, so `InterfaceTokenAccount` passes it, and `transferTokens` also takes the `InterfaceMint`, which refuses. Load the mint as `InterfaceMint` wherever a transfer, mint or burn happens; `InterfaceTokenAccount` does not read the mint. The raw readers (`readMint`, `readTokenAccount`, `mintExtension`, `tokenAccountExtension` on `Account`) are the unchecked layer and refuse nothing.

Cost, `tools/solana/checkCost.mjs` (LiteSVM 1.4.1, platform-tools v1.57, the same compiler with the std before and after): `external<Mint>` 194 to 188 CU (the owner test is one key compare, not two), `externalMutable<TokenAccount>` 228 to 222. `tokenInterface.mjs` prints the verify of an instruction that reads one account: `Mint` on a legacy mint 60 CU, `InterfaceMint` 99 CU on a legacy mint, 94 on a Token-2022 mint without extensions, 133 with MetadataPointer, 223 with four inert extensions: the table is walked once, about 40 CU an entry. `createTokenAccount` no longer sizes an account for extensions (no accepted mint requires one), so it allocates 165 bytes for every accepted mint.

## 4. Account data

An account type is a fixed-size value struct declared in a module shared by the program and the client, with one exported static: `export function discriminator(this typeof Escrow): Discriminator { return @comptime { return accountDiscriminator("Escrow"); }; }`. The string must be the type's own name: `owned`, `mutable`, `delegated`, `create` and `createPda` fold the static through `provenDiscriminatorWord` and refuse, at the first use of `Y`, a `discriminator(this typeof Y)` that is not `accountDiscriminator("Y")` (a copy of another type's line would give `Y` that type's bytes); a hand-written byte discriminator is refused there too, and `anchorIdl` already hashes the type's name (`solanaDiscriminatorNameRefused.ms`). The static must be exported, or the generics in `typed.ms` and `accounts<T>()` cannot see it, and it is written with `@comptime` so that a call returns a constant; both fold its word at compile time, `accounts<T>()` through a `@comptime` block in its expansion and each generic through one in its body, evaluated per instance with `T` bound. Measured on the escrow with `msc build examples/escrow/program.ms --os=solana`, LiteSVM 1.4.1, platform-tools v1.57, against the run-time read (`wordOf`, the compiler built from `37c0ad284`): `.so` 45,304 to 45,152 bytes; make 27,155 to 27,128 CU, take 18,287 to 18,239, refund 15,161 to 15,131, the refused make 400 unchanged. Per copy in the nine-type program of `solanaGenericSize.ms`: `owned`, `mutable` and `delegated` 192 bytes, `create` 176, `createPdaOf` 240, `.text` 81,296. The bytes are Anchor's zero-copy account: the discriminator `sha256("account:" + name)[0..8]`, then the struct in its C layout, which is `#[account(zero_copy)]`'s `repr(C)`. `Pubkey` is `uint8[32]`, so it never adds padding. Anchor's zero-copy types are `bytemuck::Pod`, which has no padding, and its clients read the fields back to back, so a field may not follow C padding and a nested struct may not end with it; `anchorIdl` refuses both with the field's name. Order fields by alignment (64-bit first) or add an explicit padding field. Padding at the end of the account itself moves no field and is allowed (the escrow has 7 bytes).

- `create<T>` and `createPda<T>` follow Anchor's `init` (`anchor-syn-0.31.1/src/codegen/accounts/constraints.rs` `generate_create_account`): a target with no lamports is created with `create_account`; a prefunded one is topped up to rent exemption, allocated and assigned. Paying with the account being created is 4101 (the raw `createProgramAccount` and `createProgramAccountSeeded` answer InvalidArgument, `lang-v2/src/cpi.rs:454`), and a space below 8 is AccountDataTooSmall because the discriminator is 8 bytes. The discriminator is written after the account exists; `createPda` takes the canonical bump, signs with the seeds and that bump, and refuses another address (2006).
- `close` is Anchor's (`anchor-lang-0.31.1/src/common.rs` `close`): every lamport to the destination, assigned to the System program, data resized to zero. Closing onto itself is 2011; a destination that would overflow is `ArithmeticOverflow` where Anchor's `unwrap` panics. Before it moves anything it refuses a target or destination that is not writable (2000) and a target this program does not own (3007), and it writes `0xff` over the 8 discriminator bytes before the resize, as `lang-v2/src/accounts/slab.rs` `close` does, so a revived account does not read as its old self.
- `realloc` follows `realloc_account` (`lang-v2/src/cpi.rs:529-580`): growth transfers only the rent deficit from the payer through the System program (a payer that is the account itself with a deficit is InvalidArgument), a shrink refunds `min(old rent - new rent, lamports above the new rent)` to the payer and skips the writes when the payer is the account, a same-size call moves no lamports, the refund is checked (ArithmeticOverflow). It refuses growth past 10,240 bytes in one instruction (3016). Under it, `Account.resize` counts this program's own growth in bytes 5 to 7 of the record and also bounds every growth by where the record ends in the input (`msSolDataRoom`): a callee that grew the account, a `createAccount` CPI for one, moves the length without moving that count, and the end of the record is the one bound it cannot move. `realloc` also refuses a new size other than the current one below `8 + sizeof(T)` (AccountDataTooSmall, `lang-v2/src/accounts/slab.rs:975-985`).

### Portable account bytes

The program and host share the layout declarations; the host does not maintain a
field-offset decoder or load an IDL at runtime. `accountCodec.ms` owns the public
`decode` / `encode` surface and `accountLayout.ms` obtains offsets, sizes and
alignment from the compiler rather than reproducing an ABI in the library.

Use the owner-checking `decode` overload for an RPC account envelope. The byte-only
overload deliberately makes no ownership claim, matching a client account coder
that receives only bytes. Both require the discriminator and complete fixed-size
payload before constructing the value. A boolean byte other than 0/1 or a value
outside the enum's exact member set is 3003, including nested structs and fixed
arrays; sparse enum holes are not accepted. Encoding uses the same offsets and
zeroes padding, so uninitialized host struct padding is never exported.

This retains `alive: boolean` and `kind: Species`, unlike rejecting those fields
under an unchecked zero-copy contract. The boolean rule follows the checked
serialization rule, not a non-zero-is-true Pod boolean; the layout remains repr(C),
not packed Borsh.

Measured on the `wt/std-solana` candidate, 2026-10-07: native
`msc-ready test std/solana/accountCodecTest.ms` passed **27 files / 395 tests**,
including golden padding bytes, all integer widths, exact enum membership, floats,
imported hidden types and BitSet storage. A real `msc-stable run` / `--target=js`
host consumer of nested `Pet` bytes printed
`valid 18446744073709551615 2 badBool 3003` and `badEnum 3003` on both backends.
Measured 2026-10-11 on the `wt/std-solana` candidate: `msc test
std/solana/accountCodecTest.ms --target=js` passed **16 files / 109 tests**; before
that, every JS consumer of `accountCodec.ms` failed to load, because JS also emitted
the uninstantiated `decode<T>` and its `@comptime` discriminator had no value there
(corpus `genericDeclarationEmitsOnlyInstances`). No Android device or
Android32 runtime was exercised; incompatible native 64-bit alignment is refused
instead of silently using another wire layout.

### PDA seeds

A seed list is written where it is used: `findProgramAddress(["pet", mint, [bump]])`. Anchor builds its seeds at the constraint, on the stack, from the account fields and `to_le_bytes()` (`anchor-syn-0.31.1/src/codegen/accounts/constraints.rs` `generate_constraint_seeds`, lines 1133-1180: `find_program_address(&[…], &program)` without a bump, `create_program_address(&[…, &[b][..]], &program)` with one, a failure of the latter mapped to `ConstraintSeeds`). Pinocchio hands the syscall a `Seed { ptr, len }` table borrowed from the caller (`pinocchio-0.9.3/src/instruction.rs` lines 190-270). MetaScript has no lifetimes and refuses a view as a struct field or array element (`paper/NIM-REF.md` CK-139), so the list is a macro argument: each call expands its list into a table of `SeedSlice`s on the caller's stack and passes it as a `Span<SeedSlice>` to a core in `seed.ms`. There is no `Seeds` value to build, keep, or return from a helper, and nothing touches the heap.

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
| `createPda<T>(payer, target, seeds)` | `Result<Pda<T>, ProgramError>`, signed with the seeds and the found bump; the matching bump is not curve-checked (§4, Signing) |
| `createMintPda(payer, mint, seeds, program, decimals, authority, freeze)` | the bump |

Derivation follows Anchor v2 (`lang-v2/src/cpi.rs` `hash_pda_seeds`, `check_off_curve`, `pda_find_loop`): the seeds, the bump, the program id and `"ProgramDerivedAddress"` go to `sol_sha256`, and the hash to `sol_curve_validate_point`, which answers 0 for a point on the curve; a find tries the bumps 255 down to 1, as agave's `try_find_program_address` does. The address syscalls cost 1,500 CU a call or a try, `sol_sha256` 85 plus a unit per two bytes of a slice (at least 10 a slice) and the curve check 159 (`solana-program-runtime-3.1.14/src/execution_budget.rs`). Measured with `node tools/solana/checkCost.mjs`, LiteSVM 1.4.1, platform-tools v1.57, against the syscall form (the std of `37c0ad284` built by its own compiler): `createPda<T>` 3,574 to 2,430 CU, `pda` 3,362 to 1,048 for a `Mutable<T>` and 1,842 to 703 for a `Delegated<T>`, `pdaWithBump` 1,914 to 792 and 1,898 to 776, every refusal still 2006; the escrow make 27,128 to 22,612, take 18,239 to 11,530, refund 15,131 to 8,342, the `.so` 45,152 to 45,968 bytes (the hashing loop is in the program). The host simulator answers `sol_curve_validate_point` with its own on-curve check. Not measured: a seed list of 15 or 16 seeds, a find that needs many bumps.

`createPda<T>` expands to `createPdaOf<T>`, `instruction<Op>()` to `selectLiteralInstruction`, `args<T>()` and `accounts<T>()` to `readArgs`: each macro binds its callee by symbol, so the program imports none of them.

### Signing

A signed CPI writes its signer seeds where the call is written, as Anchor does with `CpiContext::new_with_signer(program, accounts, &[&[b"vault", key.as_ref(), &[bump]]])` (`anchor-lang-0.31.1/src/context.rs:178-210`, a `&[&[&[u8]]]`) and Pinocchio with `invoke_signed(&instruction, &accounts, &[Signer::from(&seeds)])`, a `Signer { seeds: *const Seed, len }` over a slice the caller owns (`pinocchio-0.9.3/src/instruction.rs:238-270`, `src/cpi.rs:126-300`). One macro covers every signing call: `signed(call, seeds)`, where `call` is the unsigned call as the author writes it and `seeds` is one list, or a list of lists for several signers.

```ms
const _released = try signed(
	transferTokens(x.vault, x.takerAtaA, x.mintA, escrowAccount, held),
	["escrow", escrow.maker, leBytes(escrow.seed), [verified.foundBump()]],
);
const _sent = try signed(invoke(program, accounts, data), [["identity", [b1]], ["vrf-payer", [b2]]]);
```

A list is a list of signers when every element is a list that holds a seed (a string, a key, an account), and one signer otherwise, so `[[7]]` is one signer with the seed `[7]`; a list that mixes the two is a compile error. Each signer's seeds become a `SeedSlice` table on the caller's stack, as in §4 above, and the signers a `SignerSeeds` table over them (the runtime's `SolSignerSeeds`: the address of the slices and their count), passed as the call's last argument, `signers: Readonly<Span<SignerSeeds>>`. A signable function declares that parameter with the default `[]`, so the unsigned call takes no seeds argument at all, and `signed` replaces the default with the table. `SignerSeeds` is not in the `std/solana` barrel: an author has no value to build, hold or return. The seed limits are the runtime's, 16 seeds of 32 bytes per signer, and the std does not check them again: the host simulator refuses past them with `MaxSeedLengthExceeded` and the runtime fails the CPI (LiteSVM 1.4.1: 17 seeds `MaxSeedLengthExceeded`, a 33-byte seed `ProgramFailedToComplete`, 16 seeds sent, in `heapExhausted.mjs`; `std/solana/test.ms` pins the same three on the host); the host simulator also refuses more than 16 signers, a limit not measured on the runtime. Nothing on the signing path touches the heap.

#### The curve check at the matching bump

A PDA that signs the CPI which follows its find needs no `sol_curve_validate_point` at the bump whose hash is its key. The runtime derives every signer of a CPI with `create_program_address` before it runs the callee and refuses an address on the curve, both ABIs, with no feature gate (`solana-program-runtime-3.1.14/src/cpi.rs`, `translate_signers`); the failed CPI aborts the program and rolls the transaction back. `CreateAccountAllowPrefund` also needs the new account's signature, so a prefunded on-curve address cannot be created either. Every bump above the match is still curve-checked inside the find (`msSolFindExpectedAddress`), so only the canonical address is taken: a lower off-curve alias returns `ConstraintSeeds` before any CPI. Anchor skipped the check for a PDA that nothing signed with and retired that skip (commit `89930933`); its own TODO at `lang-v2/derive/src/parse.rs:1876-1880` names the condition kept here.

The condition is that the found bump flows into the signer table of the CPI with nothing done with the address in between, so the skip exists in two places and nowhere else:

- `createPda<T>`: `createdPdaAccount` finds with `msSolFindExpectedStaged` in the caller's own seed table, which leaves the bump in the byte the table's bump slice names, and signs the `CreateAccountAllowPrefund` with that table.
- `signedPda(call, pda, seeds)`: `signed` for one PDA whose bump the std finds. `seeds` is one list without the bump; `slottedTable` appends the bump's slice and a byte for it, `foundSigner` leaves the found bump in that byte and the call receives that table as its signers, with the `try` of the find in the argument list so a failed find returns before the call is made.

```ms
return signedPda(
	transfer(x.vault.asAccount(), x.recipient.asAccount(), input.amount),
	x.vault.asAccount(),
	["vault", x.config.key()],
);
```

There is no function that answers "the bump for signing": `foundSigner` is not on the `std/solana` barrel (`solanaProofFailurePrivate.ms`), and its `ok` proves nothing about the address until the CPI has run. A program that needs the bump itself (to store it, or to sign later) uses `canonicalBump`, which keeps the curve check, or an owned proof, which does not need it (`canonicalBumpProven` for `Mutable<T>`: the owner was compared by the proof; `canonicalBumpOwned` compares it itself, for a deep import).

What an author sees: an on-curve address in the `pda` position (or as `createPda`'s target) used to fail with `Custom(2006)` (`ConstraintSeeds`) before any CPI; it now passes the find and fails inside the CPI with `ProgramFailedToComplete` and the log `Could not create program address with signer seeds: Provided seeds do not result in a valid address`, no account changed. Every other refusal keeps its code, and a program with no valid canonical address at all (every bump on the curve, a chance of 2^-255) answers `ConstraintSeeds` where `createPda` answered `InvalidSeeds`. The host simulator derives each signer as the runtime does: an on-curve signer is refused before the call is recorded, with the fault `sol_invoke_signed: Could not create program address with signer seeds` and the status `InvalidSeeds`, so a host test sees the refusal as `HostRun.fault` where the runtime aborts. `std/solana/test.ms` pins the find (the canonical bump, an on-curve hash above it, a lower off-curve alias, 16 seeds), `createPda` and `signedPda` on an on-curve target, and `tools/solana/anchorBench.mjs` replays the same on LiteSVM (`oncurve-pda`, `oncurve-pda-at-rent`, `oncurve-pda-above-rent`: multisig `create` and `execute_transfer` at a bump above the canonical one, `ProgramFailedToComplete`, the BadSeeds log, no `invoke [2]`, accounts unchanged).

`signed` reads the callee's signature from the type of the call it receives, so it names the callee when that has no `signers` parameter (`logU64 takes no signers`, `scheduleTask takes no signers`), and it reads the overload the call resolved to, so a signable function may be overloaded: `signed(requestRandomness(request, seed, discriminator, callbackAccount, args), ["vrf-payer", [bump]])` with the one-account overload signs next to the program identity on the host simulator (`vrf.ms`, the second test of the single-account form). A function that takes `signers: Readonly<Span<SignerSeeds>> = []` is not turned into an overload pair: the call sites are the same and a pair adds a body. The call is type-checked as written before `signed` expands it, which has two consequences: an argument that the unsigned form refuses is refused (`transferTokens` takes its authority as an `Account`, not a `Signer` proof, because a PDA authority is not a signer of the transaction), and a generic call with an explicit type argument sits inside it as it does outside (`signed(create<T>(…), …)`).

| Signable | Takes `signers` |
|---|---|
| `core.ms` | `createAccount`, `assignTo`, `transfer`, `allocate`, `createProgramAccount`, `createdAccount` (what `create<T>` calls: the seeds of the new account, which is a PDA the transaction does not sign for), `invokeCpi` (what `invoke` and `invokeSigned` expand to) and `invokeList` |
| `token.ms` | `mintTo`, `transferChecked`, `closeAccount`, `createAssociatedToken`, `createAssociatedTokenIdempotent`, `transferTokens`, `mintTokens`, `closeTokenAccount` |
| `vrf.ms` | `requestRandomness` with a callback list or one callback account (the same request bytes): the program identity always signs, a payer PDA is the one signer passed |
| `magicblock.ms` | `commit` and `commitAndUndelegate`, all six overloads (one account, a list, a list through the fee vault): `signed(commit(payer, [pet], context, feeVault), ["vrf-payer", [bump]])` or `signedPda(commit(…), payer, ["vrf-payer"])` lets a program PDA pay. The unsigned call still refuses a payer the transaction did not sign (`MissingRequiredSignature`); a signed call leaves that to the runtime, which checks the seeds against the payer's key. Accounts as the validator reads them: payer (writable, signer), context (writable), the fee vault when given (writable), then the committed accounts with their own flags (`magicblock-magic-program-api-0.10.1/src/instruction.rs:26-58`, `ephemeral-rollups-sdk-0.16.2/src/ephem/deprecated/v0.rs:61-100`); host tests `magicblock.ms` "a commit signed by a PDA payer" |

`delegate(accounts, seeds, bump, config)` is its own macro because the seeds are also data: the delegation program stores them (without the bump) for the undelegate callback. It expands to `delegateAt` in `delegation.ms`, a module `macro.ms` can import because it does not import `macro.ms` back.

`delegateAt` writes the seeds into the delegation args before it zeroes the delegated account, and signs the `assign` and the delegation with that copy, so a seed read from the account's own data (`["pet", record.mint]`) signs as it was. Signing through the caller's bytes after the zeroing signed with zeros: `PrivilegeEscalation` on devnet (Hibernal, 2026-10-09). The MagicBlock SDKs also serialize after zeroing and rely on the caller's borrow (`ephemeral-rollups-sdk` `958c5a1`, `rust/pinocchio/src/instruction/delegate.rs:86-122`). The buffer's bump comes from `findExpected`: every bump above the one whose hash is the buffer's key is checked off the curve, so only the canonical buffer is taken, and the match itself skips the curve check because the runtime refuses `createAccount` signed with an on-curve key (`solana-program-runtime-3.1.14/src/cpi.rs:792-793`). A seed list outside 1 to 8 is refused at the `delegate` call (`solanaDelegateNineSeedsRefused.ms`, `solanaDelegateNoSeedsRefused.ms`) and by `delegateAt`, the bounds of the delegation program (`delegation-program` `3a6fbe2`, `src/processor/fast/delegate.rs:160-204`).

Measured 2026-10-10 with `node tools/solana/delegateSeeds.mjs dlp.so old=… new=…` (`tools/solana/delegateSeedsProbe.ms` built `--os=solana` by each std, the delegation program dumped from mainnet, LiteSVM): before, a seed in the account fails with `PrivilegeEscalation` at 4,163 CU and a local seed passes at 30,211 CU; after, both pass, the account belongs to the delegation program and its metadata holds the seed, at 29,153 and 30,010 CU (the local case copies the seed in the probe). One program id and one mint were measured.

Why the shape is not simpler:

- **Forwarded seed type queries.** Compiler base `da84849e` failed at `seedTable`'s `getType(element)` with `node has no type`, while `element.nodeType` carried the shape. This is not a current restriction: on Windows x64, source tree `11fdb5911671` and its rebuilt candidate, `msc test std/solana/test.ms` passes 392/392 and `msc test std/solana/vrf.ms` passes 332/332. The seed cases include string, byte literal, fixed byte array, read-only Span, heap array, Pubkey and account inputs forwarded through the seed macros. Other macro transports and non-native backends were not revalidated here.
- **A module that defines a macro must not be a module the program links.** `token.ms` with a macro in it kept `std/meta` in the SBF build, and that pulls `runtime/crypto/hash.c`, which clang for SBF cannot compile. `macro.ms` importing `token.ms`, which imports `macro.ms` for its tests, did the same through the cycle. `mint.ms` holds what `createMintPda` calls so that `macro.ms` imports a module that imports nothing from it.
- **A table address must outlive the call that reads it.** `SeedSlice` holds addresses into the frame that built it, so a builder takes a `Span`, never a `Pubkey` by value (a value parameter may be a copy), and `fillWithBump` takes the table by `ref` so the bump byte sits in the caller's frame.

- Rejected: the heap `Seeds` value built by chaining (`Seeds.empty(2).addText("pet").addPubkey(mint)`), deleted: about 200 bytes of the 32 KiB heap per derivation, so 163 PDA checks in one instruction exhausted it, a signed CPI took 112 more bytes than an unsigned one, and a helper could return one built from its own parameters.
- Rejected: the two-byte kind/version head this design started with. It saved six bytes per account and carried a version, but no Anchor client, explorer or indexer can read it, and Anchor's closed-account handling no longer needs a sentinel.

### Cross-program invocations

A CPI lists its accounts and writes its data where the call is written, and takes nothing from the heap. Pinocchio builds the same three things on the caller's stack: the `InstructionAccount` array, the data in a `[u8; N]` written in place (`pinocchio-system-0.5.0/src/instructions/create_account.rs`, `[0; 52]` and `copy_from_slice`; `pinocchio-token-0.6.0/src/instructions/transfer.rs:120-131,295-306`, a stack `[UNINIT_BYTE; DATA_LEN]` that `write_instruction_data` fills and answers the length of, sent as `&instruction_data[..written]`, and a buffer shorter than `DATA_LEN` is `InvalidArgument`), and the `CpiAccount` array the runtime reads, sized by a const generic (`pinocchio-0.9.3/src/cpi.rs:34-300`, `invoke_signed<const ACCOUNTS>`; `slice_invoke_signed` uses a fixed `MAX_CPI_ACCOUNTS` for a count known only at run time). MetaScript has no const generics, so the count is the length of the list the author writes and a macro sizes the arrays from it:

```ms
let storage: uint8[12] = [];
const length = storage.putU64(storage.putU32(0, 2), lamports);
const sent = invoke(
	SYSTEM_PROGRAM_ID,
	[InstructionAccount.writableSigner(source), InstructionAccount.writable(destination)],
	storage,
	length,
);
```

- **Shapes.** `invoke(program, accounts, storage, length)` is `invokeSigned(program, accounts, storage, length, [])`; `signed(invoke(…), seeds)` signs it like any call, and a function that forwards its own `signers: Readonly<Span<SignerSeeds>>` calls `invokeSigned`. Both expand to `invokeCpi(program, accounts, <one zeroed CpiAccount per account>, storage, length, signers)`: each element of the list is evaluated once, and the core fills the `CpiAccount` of an `InstructionAccount` from the account record the key points into (the key is the address of the account's key, so the record is 8 bytes below it) with the account's own flags, while the `InstructionAccount` keeps the flags the call asked for. A count known only at run time is `invokeList(program, accounts, storage, length, signers)`, which keeps its `CpiAccount`s in its own frame.
- **Writing data.** `putU8`, `putU16`, `putU32`, `putU64`, the signed ones, `putBool`, `putPubkey`, `putBytes` (a view of the input buffer), `putSpan` and `putPrefix` (the first `length` bytes of a span) are extensions of the storage, written `storage.putU32(at, value)` or `putU32(storage, at, value)`; each takes an offset and the value and answers the offset after the write. A write that does not fit writes nothing and answers `storage.length + 1`, which every later write answers again, so a chain needs no check until the CPI: it answers `InvalidArgument` before it sends when the length is past the storage (`requestRandomness` answers `InvalidInstructionData`, which the VRF SDK returns for a buffer that is too small, `ephemeral-rollups-sdk/rust/pinocchio/src/vrf/types.rs:78-81`; `scheduleTask` answers `InvalidArgument`). N is a capacity and the offset is the length. Sizes chosen: the delegation 625 bytes (the SDK's `MAX_DELEGATE_ACCOUNT_ARGS_SIZE` plus the 8-byte discriminator, `rust/pinocchio/src/types.rs:4-8`), a VRF request and a scheduled task 1,024. A function that embeds data it was given (`requestRandomness`'s callback arguments, `scheduleTask`'s target data) takes a `Readonly<Span<uint8>>`, as the SDK takes a `&[u8]`, and the author passes the array or `storage[0..length]`.
- **Integration measurement, Windows x64, source tree `0e980314b095`, 2026-10-07.** A throwaway native consumer calls `storage.putU32`, free-function `putU64`, overflow `storage.putU8`, and `putSpan` with an immutable sized-array source. It prints `writers 12 13 18 52 86 120 1 0` and `span 2 9 10 86 0`: both call forms work, the 12-byte destination fills exactly, the next write refuses with 13 without changing its last byte, and the readonly source copies two bytes. `out/remote5730/msc.exe test std/solana/test.ms` passes 458/458 tests in 27 modules. The frame/account-count figures above are prior measurements, not reverified by these native consumers; the LTO boundary and the other writer widths are not measured by the throwaway probe.
- **Limits.** 64 accounts, Pinocchio's `MAX_CPI_ACCOUNTS` (`cpi.rs:15`) and the runtime's limit on the account infos a CPI takes when `increase_tx_account_lock_limit` is off (`agave-syscalls-3.0.0/src/cpi.rs:914-925`; 128 when it is on). A run-time list of 65 is `InvalidArgument`, Pinocchio's answer in `slice_invoke_signed` (`cpi.rs:229-250`). A list written at the call of more than 64 is a compile error that names the limit (`solanaCpiAccountLimit.ms`), the const assertion `invoke_signed` reaches through `inner_invoke_signed_with_bounds` (`cpi.rs:126-136,278-284`); the account infos are built in the fixed 64-slot frame of `msSolInvokeMetas` (`runtime/solana/solana.h`), not in the caller's, so a 64-account list written at the call beside a one-byte buffer builds (`solanaCpiFrame.ms`, 2026-10-09). `commit` keeps the 16 of the ephemeral-rollups SDK (`ephemeral-rollups-sdk/rust/pinocchio/src/instruction/commit.rs:10,37-41` `MAX_LOCAL_CPI_ACCOUNTS`): its list is `InvalidArgument` past 16 in total with the payer, the context and the fee vault. `scheduleTask` keeps 16 task accounts: its 1,024-byte buffer holds at most 27, so a larger limit could not be reached. The CPI shapes at these limits build inside the frame: `solanaCpiFrame.ms`.
- **What a program can hold.** A value an author can keep or return points only at memory that lives for the whole instruction: the input buffer (account records, instruction data, the program id), rodata, or the heap, which is never freed. A view into a frame is a parameter, never a value, as the reference's `openArray` is (`paper/NIM-REF.md` CK-139); that is why the writers are functions over a `Span<uint8>` and an offset and not a struct that holds the array's address. `Bytes` points into the input buffer (`instructionData`, `Account.data`, `argBytes` and the ranges of those), `Account` and `InstructionAccount` hold the address of a record in it, `Pda`, `AccountMeta` and `Clock` hold values, `ReturnData` owns its 1,024 bytes (`[u8; MAX_RETURN_DATA]` in Pinocchio's, `pinocchio-0.9.3/src/cpi.rs:488-530`), and `CpiAccount` holds the addresses of the input-buffer fields the runtime reads. `SeedSlice`, `SignerSeeds`, `Signing`, `SeedTable` and `CpiInstruction` hold frame addresses by design and are internals of the macros and of `invokeCpi`: they are not in the `std/solana` barrel, though `seed.ms` and `cpi.cms` export the functions that build them. `std/solana/test.ms` pins where each `Bytes` producer points.
- **Why the core fills the `CpiAccount`s.** Building both arrays at the call site from the same list needs each account expression twice, so the macro would have to refuse an expression with a side effect or copy it; a probe of a 3-account CPI measured the call-site arrays at 912 bytes of `.text` and the core fill at 832. A core that keeps all 16 `CpiAccount`s in its frame for every CPI (`slice_invoke_signed`'s shape) measured 904 bytes, but puts the core's 944-byte frame under every CPI; at 64 the frame of `invokeList` is 3,648 bytes.
- **Traps.** `invoke.ms` imports only `core.ms`, so `mint.ms` and `delegation.ms` use the macros without importing `macro.ms` (§1, the cycle in §4 above). `signed` rebuilt its callee by name, which dropped the symbol a macro had bound and failed `signed(invoke(…), …)` with `Undefined variable 'invokeCpi'`; it keeps the callee as written. A sized array of length 0 (`AccountMeta[0]`) does not compile (`initializer for aggregate with no elements requires explicit braces`): pass `[]` where a view is wanted. A `this` receiver of type `Span<uint8>` does not take a `uint8[N]`, so the writers are free functions (`2026-10-04-extension-with-a-span-receiver-does-not-resolve-on-a-sized-array`). `try scheduleTask(…)` and `const sent = try requestRandomness(…)` over an overloaded function build under `--os=solana` (`src/test/guard/solanaOverloadedAggregateReturn.ms`).
- **What still allocates.** No std/solana function reaches `msSolAlloc`: `grep msSolAlloc std` is empty. The account table is not on the heap: the emitted `entrypoint` (`src/codegen/c/index.ms`) holds it in its own frame, 255 accounts at most, the runtime's limit (agave `program-runtime/src/serialization.rs:23,201-202`), as Pinocchio's entrypoint does (`pinocchio-0.9.3/src/entrypoint/mod.rs:173-176`). `tools/solana/heapExhausted.mjs` logs the heap position of an instruction of 1, 2, 17, 64 and 255 accounts on LiteSVM 1.4.1 and requires one value for all five: 12,884,901,952 (0x300000040) on this tree, where a build that parses into the heap logs 8 more bytes per account and fails four of the five checks; `src/test/guard/solanaEntryAccountTable.ms` pins the emitted entry. The heap is taken by the arrays, strings and class instances a program creates itself. `minimumBalance` reads the rent into a stack array.
- Rejected: the heap `Instruction` (`forProgram(program, accountCapacity, dataCapacity)` with `addAccount` and `append…`), deleted: 160 bytes of the heap for a one-account CPI (664 for the probe's 512-byte one), so 50 of those exhausted it, and an overflow was a flag read at the end of the chain.
- Rejected: `BorshBuffer`, a struct holding the address, capacity and cursor of the caller's `uint8[N]`, with `Bytes` views of what it wrote. It kept the heap out of a CPI, but a function could return one or store it in a struct after its array was gone, and nothing in the checker sees a raw address in a `uint64` field; before it, the heap form was safe only because the heap is never freed. Deleted with `Bytes.written()` and `borshBuffer`.
- Rejected: the clock, the return data and `logPubkey` through `msSolAlloc`, 40, 1,056 and 32 bytes of the heap per call (Pinocchio reads each into a stack value: `sysvars/mod.rs:45-66` `impl_sysvar_get!`, `cpi.rs:488-515`, `pubkey.rs:31`).

### Scratch memory

A program that needs a contiguous `Span<T>` larger than the 4 KB frame (ten Hibernal pets are about 1.8 KB beside their records and the rule frames) takes it from the program heap with `scratch<T>(count)`:

```ms
function load(block: Ptr<Block>, first: int32): Result<uint64, ProgramError> {
	const pets = scratch<Pet>(SEATS);
	const records = scratch<uint64>(SEATS);
	const _filled = try loadPets(block, first, pets, records);
	return Result.ok(livingMates(pets, records, 0));
}
```

It replaces `@include("runtime/solana/solana.h")`, `extern function msSolAlloc` and `msSolAlloc(sizeof X) as Ptr<X>`. A struct of arrays works too: `scratch<BlockPets>(1)` is a `Span<BlockPets>` of one, and `heap[0].pets` passes to a `Span<Pet>` parameter without a copy (probed with `--emit=c`: the call takes the address of the heap field).

- **What it gives.** A `Span<T>` of exactly `count` elements, zero-filled, 8-aligned, in the heap the arrays and class instances of the program also use. Each call advances the bump pointer past its bytes, so two spans never overlap. The heap starts every instruction zeroed and the pointer never moves back (`solana-program-runtime-3.0.0/src/mem_pool.rs:54-57` fills a pooled heap with zeros when it is returned; `msArenaReset` has no caller on Solana), so the bytes are zero without a fill. Nothing frees it, which is also why a view over it is safe to keep: the memory outlives every frame of the instruction, which a view over a stack array does not.
- **What it refuses.** At compile time a `T` that owns managed memory (a string, an array, a class instance, a closure, a lifecycle hook): `in instantiation of 'scratchAddress<Named>': Undefined variable 'scratchTypeOwnsManagedMemory'` at the call, from `isPlainData<T>()` (`std/typetraits`), `solanaScratchRefused.ms`. `Ptr<T>` fields pass `isPlainData` and are allowed; a zeroed one is null. At run time `InvalidArgument` when the heap cannot hold `count * sizeof(T)` more bytes, a negative count, or a count over 262,144 (`SCRATCH_MAX_COUNT`, the most 1-byte elements of the 256 KiB largest heap): the runtime check (`msSolScratch`, `runtime/solana/solana.h`) is made before the bump, so the program returns the error instead of taking the `abort` of a failed `msArenaAlloc` (§8 heap exhaustion). Other allocations that exhaust the heap still abort as before.
- **Shape.** `scratch` is a macro, written inside a function that returns `Result<_, ProgramError>`: it expands to `try scratchAddress<T>(count)`, a cast to `Ptr<T[262144]>`, a dereference and the slice `[0..count]`, the way `signedPda` expands a `try` in front of its call. The pointer never reaches the author. `count` is evaluated twice, so it may hold numbers, locals, fields, casts and arithmetic but no call (a call is refused with that sentence). `T` is a named type.
- **Why not a function.** `scratch<T>(count): Result<Span<T>, ProgramError>` does not compile: `a return value of type Result<Span<Pet>, int32> cannot hold Span<Pet> inside it: a view borrows memory its source can free while the container still holds it` (LANG.md §Spans, rules 2 and 4), and a bare `Span<T>` return is refused for the same reason. The checker cannot tell that this source is the heap and is never freed, so the view is made where it is bound. The consequence for the author is the usual one for a `Span`: it is a local or a parameter, and a function that fills it takes it as a `Span<T>` parameter instead of returning it. `Ptr<T>` slicing (`p[0..n]`) is not a language feature: it reaches codegen as `operator '..' reached codegen unresolved`, so a raw-pointer API could not give a bounds-checked view either; this is reported, not worked around.
- **Not a free list.** There is no way to give scratch back before the instruction ends, and a `scratch` in a loop body takes its bytes every round (583 rounds of 56 bytes fill the heap). Take the span before the loop.

Measured 2026-10-11 on commit `a52f3b78e` plus this change, LiteSVM 1.4.1, `node tools/solana/heapExhausted.mjs` on `tools/solana/heapProbe.ms` (op 21, `Mon` of 56 bytes): 0, 1, 2, 36 and 100 `Mon`s read as zero, read back what was written and move the heap position by exactly `count * 56` bytes (2,016 for 36, in 2,104 CU including the loops); 583 `Mon`s, the most the heap holds from its entry position, run (24,531 CU) and 584 fail with `InvalidArgument` in under 5,000 CU with no `heap is exhausted` line, as does 65,535. Host simulator (`std/solana/test.ms`, three tests): two spans of 10 are zeroed, do not overlap (writing the second leaves the first's sum at 1045) and have the length asked; a bisection finds the largest `uint8` count that fits (between 32,000 and 32,768), the next one is `InvalidArgument`, a following one-byte `scratch` after the largest is `InvalidArgument` and after the largest less 8 it is not; a negative count is `InvalidArgument` and zero gives an empty span. A host test made red by an allocator that does not advance the pointer fails two of the three. The five anchorBench programs build to the same sizes and CU as before (hello 1528; vault 1649, 456; nested 2834, 196, 188; prop-amm 123, 1465, 148; multisig 2595, 2366, 508, 2700): a generic nothing instantiates is not emitted. On JS the macro hands out the same span as a view over the simulator's heap (`msSolArrayAt<T>` in `memory.jms`), with the same failure codes: the scratch tests of `std/solana/test.ms` (a struct, `uint8`, `uint64`, `boolean`, `int16`, the bisection and the negative count) pass on C and on `--target=js`. Not measured: `scratch` inside a generic function (the macro reads `T` as a name), a `T` of alignment above 8, a heap raised with `RequestHeapFrame`.

### Hydra cranks

`std/solana/hydra` schedules an instruction of the program itself on the ephemeral rollup, the way `std/solana/vrf` requests randomness: the module owns the Hydra program id, the Magic rent vault, the `Create` and `Cancel` bytes and the account order, and the program passes what is its own.

```ms
import { CrankAccounts, CrankSchedule, cancelCrank, createCrank, crankAddress } from "std/solana/hydra";

const crank = try crankAddress(x.payer.key(), seed);
if (x.crank.key() != crank) { return Result.err(ProgramError.invalidSeeds()); }
const held: CrankAccounts = { sponsor: x.payer.asAccount(), crank: x.crank, magicVault: x.magicVault, magicProgram: x.magicProgram };
const metas: AccountMeta[2] = [AccountMeta.writable(x.block.key()), AccountMeta.readonly(x.config.key())];
let data: uint8[16] = [];
const _tag = putU64(data, 0, TURN_TAG);
const _seq = putU64(data, 8, block.requests);
const _created = try signed(
	createCrank(held, seed, CrankSchedule.once(dueSlot), programId(), metas, data),
	["vrf-payer", [bump]],
);
const _cancelled = try signed(cancelCrank(held), ["vrf-payer", [bump]]);
```

`CrankSchedule.once(startSlot)` is what Hibernal's `program/hydra.ms` sends: remaining 1, an interval of 1,000,000,000 slots, a tip of 0 and the 1,400,000 CU ceiling; a repeating schedule writes the five fields itself (`remaining` 0 is forever, and Hydra refuses forever with an interval of 0). The sponsor is the crank's authority, so only it can cancel, and it receives the refund. `createCrank` and `cancelCrank` take `signers` as `transfer` does, so a sponsor PDA signs with `signed` or `signedPda`.

- **Wire format, read not guessed.** The checkout `~/projects/hydra` at `a6846416d`: `crates/hydra-api/src/instruction.rs` (`CreateArgs::write_to`: discriminant 0, seed, authority, start slot, interval, remaining, tip, CU limit as u32, then per scheduled instruction the account count as u8, the data length as u16, the program id, a flag byte and key per account, the data), `programs/hydra-ephemeral/src/processor/create.rs:12-20` (accounts sponsor writable signer, crank writable, vault writable, Magic program readonly) and `cancel.rs:8-11` (authority writable signer, crank, recipient, vault, Magic program, data the byte 2), `crates/hydra-api/src/consts.rs` (the ephemeral program id `eHyd5BU8QffvHi4GnXwxrK4WpS7pM2x9UGKHBWii7mf`, a writable flag of 2, the 1,400,000 ceiling), and `magicblock-magic-program-api-0.10.1/src/lib.rs:22` for the vault `MagicVau1t999999999999999999999999999999999`. Host tests in `hydra.ms` assert the bytes from those layouts (a one-shot with two accounts, 101 + 35 + 66 + 16 bytes; a repeating schedule with none; 24 accounts at the buffer's edge), the account flags and order, the signer seeds of a sponsor PDA, and the two PDA addresses against `@solana/kit` `getProgramDerivedAddress`. A throwaway probe linking Hibernal's `program/hydra.ms` and this module in one host run compared `createCrank` for three accounts (251 bytes, 4 metas) and `cancelCrank` (1 byte, 5 metas): byte for byte and flag for flag the same.
- **Two crank addresses.** `crankAddress(sponsor, seed)` is `["crank", sponsor, seed]` under the Hydra program: another payer cannot take the address. `legacyCrankAddress(seed)` is `["crank", seed]`, which Hibernal's `crankAddress` derives. Hydra accepts both today and marks the second deprecated, squattable and to be removed (`crates/hydra-api/src/program/processor.rs:177-199`, the change `3297c06` "bind crank PDA derivation to the payer"). Which one a program uses is the program's decision: the crank account it passes decides it, `createCrank` derives nothing, and Hydra answers `InvalidSeeds` for an address that is neither. Whether the Hydra deployed on a given cluster already has the payer-bound derivation is not something this checkout can say.
- **Limits.** One scheduled instruction per crank (Hydra takes 16), no cancel authority other than the sponsor, and a 944-byte buffer on the stack: `createCrank` answers `InvalidArgument` before it sends when `136 + 33 * accounts + data` is over 944 (24 accounts beside 16 data bytes; Hydra allows 32 accounts and 1,024 data bytes per instruction). A scheduled account with the signer flag is refused with `InvalidArgument` too, as Hydra refuses it (`SignerInScheduledIx`, `processor.rs` `write_tail`). Raise the buffer when a program needs more and has the frame for it. Only the ephemeral program is wrapped: the base-layer one (`Hydra17i1feui9deaxu6d1TzSQMRNHeBRkDR1Awy7zea`) creates through the System program with different accounts.
- **`crankSpent(crank, sponsor)`** is Hibernal's `spentCrankOf`: true when Hydra owns the account, its authority (offset 0) is the sponsor and `remaining` (offset 80, `crates/hydra-api/src/state.rs:19-59`) is 0.
- **Not verified.** A run against the Hydra program itself: LiteSVM has neither the Hydra binary nor the Magic program's ephemeral-account create, so the CPI is recorded by the host simulator, not executed (`guard solanaHydraLinks.ms` builds the module for SBF, signed and unsigned). The stack frame of `createCrank` is not measured beyond that build; the 5,000-block devnet and localnet runs Hibernal made were not repeated.

## 5. Instructions, arguments, errors and events

- **Instruction.** 8 bytes of `sha256("global:" + snake_case(name))[0..8]`, then the arguments in Borsh. `instruction<Op>()` computes every member's discriminator at compile time; short data is `InstructionMissing` (100), no match `InstructionFallbackNotFound` (101).
- **Arguments.** `args<T>()` reads `T`'s fields at their Borsh offsets (sized integers, `boolean`, `Pubkey`); short data or a `bool` byte other than 0 and 1 is `InstructionDidNotDeserialize` (102), as Borsh refuses it.
- **Errors.** `ProgramError` carries the runtime's builtin errors (`n << 32`) and Anchor's codes with Anchor's numbers (`anchor-lang-0.31.1/src/error.rs`). A program's own errors are an enum; its `converter` to `ProgramError` returns `ProgramError.userError(error as uint32)`, Anchor's `6000 + n` with `n` the member's value, and `try` converts through it. The IDL lists each error under `6000 + value` on the assumption that the converter is that one (it does not read the converter); an error enum with a negative value or two members of one value is a compile error in `anchorIdl` (`solanaIdlErrorValueRefused.ms`). `Result.err(EscrowError.ZeroAmount)` in a handler that returns `Result<T, ProgramError>` converts through the same converter, which must be imported where the handler is (`examples/escrow/program.ms`); `Result.ok` and `Result.err` take T and E from the Result the context expects (corpus `converterIntoResultSlot`).
- **Events.** `emit<E>(local)` logs `sha256("event:" + Name)[0..8]` and the Borsh fields through `sol_log_data`, which a validator prints as `Program data: <base64>`, Anchor's `emit!`. Anchor builds the bytes in a `Vec::with_capacity(256)` that grows (`anchor-attribute-event-0.31.1/src/lib.rs:47-56,100-110`); here the macro hands `logEvent` the discriminator, the width of each field and its value (the address of a `Pubkey` field), and the core writes them into a 1,024-byte stack buffer. The size is known where the event is written, so an event over 1,024 bytes is a compile error that names its size (`solanaEventTooLarge.ms`), and one of exactly 1,024 builds (`solanaEventAtLimit.ms`). Writing the event struct's own bytes was rejected: C pads a field after a smaller one, Borsh does not.
- **Security contact.** `securityTxt({ name, projectUrl, contacts, policy, ...optional })` at module scope puts the block explorers read into the program's ELF, laid out as the `security_txt!` macro of `solana-security-txt` 1.1.3 does (`src/lib.rs` `SECURITY_TXT_BEGIN`, `SECURITY_TXT_END` and the macro's `concat!`; the field table in its `README.md`): `=======BEGIN SECURITY.TXT V1=======\0`, `key\0value\0` for each field in the order written, `=======END SECURITY.TXT V1=======\0`. The camelCase fields are `name`, `projectUrl`, `contacts`, `policy` (required) and `preferredLanguages`, `encryption`, `sourceCode`, `sourceRevision`, `sourceRelease`, `auditors`, `acknowledgements`, `expiry`, written to the wire as `project_url`, `preferred_languages` and so on. The macro refuses at compile time, naming the field, a missing required field, an unknown or repeated field, a value that is not a string literal, a value with a NUL byte and a value holding a block marker (a reader would take it for the block's edge); each byte of a value is written as a C octal escape, so quotes, backslashes, newlines, multibyte characters and trigraphs reach the ELF unchanged. It emits `__attribute__((used, retain, visibility("hidden"))) const char msSecurityTxt[]`: `used` alone is dropped by the `--gc-sections` link, `retain` keeps it, and `hidden` keeps it out of the dynamic symbols. A second declaration in a program is a C redefinition of `msSecurityTxt`. The crate puts the block in `.security.txt` on SBF; this one lets the linker place it with `.rodata`, which the inbox card's reproduction showed survives (`src/test/guard/solanaSecurityTxt.ms` reads the block out of the linked `.so`). On JS the macro checks the same fields and emits nothing, since the block belongs to the ELF (`src/test/corpus/programs/solanaSecurityTxtOnJs.ms`: before, the JS build printed the C declaration into the module and node stopped with `SyntaxError: Unexpected token 'const'`). Measured with `tools/solana/securityTxt.mjs` on LiteSVM 1.4.1 and platform-tools v1.57: a program that logs one number is 1,000 bytes without the block and 1,240 with it, 128 CU either way. Not verified: gcc below 11 or a C compiler without `retain` (it would warn and drop the block under `--gc-sections`), the raiser backend (`import { Pubkey } from "std/solana"` already fails there on `./accountCodecKernel`), and a program that also uses `accounts<T>()`: there the macro body fails to compile with `Undefined variable 'msStringConcatArr'` and `'msSpanAccess'`, as does any user macro of that shape called at module scope (measured with the installed `msc` of `f421de59b`; the same call inside a function compiles).

## 6. Signed division

Signed `/` and `%` on SBF are ~170 CU calls to `__divdi3`; unsigned division is one instruction. `std/solana/arithmetic.ms` overloads `/ % /= %=` on `int32` and `int64` under `when (solana)` to divide magnitudes as unsigned and restore the sign, equal to C's truncating division for every non-UB input (tested over a value matrix, C and JS). A program enables it for every module with one line in `build.ms`: `globalImports: ["std/solana/arithmetic"]`. Measured on the tree below: a program dividing in a module it imports links 20 `__divdi3`/`__moddi3` call sites without the line and 0 with it. A division by a constant power of two becomes a call instead of a shift, because the overload is not inlined across modules.

Rejected: routing every signed division through a runtime helper with an SBF-specific body. It would have made the compiler's emission target-specific; the toolkit owns the cost instead.

## 7. Clients and the IDL

`anchorIdl<Op>(spec)` returns the program's IDL in Anchor's 0.1.0 spec as a string literal built at compile time: instructions with snake_case names, discriminators, accounts with their `writable`/`signer` flags and known program addresses, Borsh arguments (a last `Bytes` argument is `bytes`); account types with discriminators and `bytemuck`/`repr(C)` layouts, a nested struct as a `defined` type listed in `types`, `T[N]` as an `array`, `BitSet<E>` as the integer it is stored in (`u8`, `u16`, `u32`, `u64` up to 8, 16, 32, 64 members, `[u8; ⌈n/8⌉]` above, bit = ordinal); an enum as the integer it is stored in (`u8` when its values fit 0 to 255, `u16` up to 65535, `i32` otherwise, as `docs/LANG.md` sizes it; measured 2026-10-05 in `std/solana/test.ms`, `species: Species` of `{ Cat, Dog }` is `u8` and `Pet` is 4 bytes); events; the error enum, each member at 6000 plus its value. A struct's inherited fields are listed base first, for accounts and for data (2026-10-12, `std/solana/test.ms` decodes the program's bytes through the IDL's field list). A nested struct must be imported where `anchorIdl` is called; any other field type is a compile error. `examples/escrow/idl.cms` prints it (`msc run examples/escrow/idl.cms > escrow.json`); its test parses the JSON on C, and `tools/solana/escrow.mjs` loads it in Anchor's TypeScript client (§8).

Addresses and PDAs (2026-10-09): an account gets a fixed `address` for `Program<System|Token|Token2022|AssociatedToken>` and for `@address(CONST)` where `CONST` is a `pubkeyOf` constant visible at the `anchorIdl` call (otherwise a compile error). A field with `@seeds` gets `pda.seeds`: a string or byte list is `const`; an account or `account.key()` is `account`; `leBytes(x.f)` (uint16/32/64) or `[x.f]` (uint8) is `arg` for an instruction argument, or `account` with `path: "field.member"` for a member of an `Owned`/`Mutable`/`Delegated` field. `@bump` adds no seed. A seed outside these forms leaves the account with no `pda`, as Anchor's own IDL builder does, never a partial list; there is no `pda.program` and no associated-token PDA. Pins: `std/solana/idlTest.ms`; `tools/solana/codamaPdaCheck.mjs` (with `CODAMA_DIR` pointing at a `@codama/nodes-from-anchor` install) checks that Codama derives the PDA node and the account default.

A MetaScript client compiles the program's layout module to JS and uses the same declarations, `Pubkey`, discriminators and `BorshWriter`.

## 8. Testing

- **Host simulator** (`std/solana/host.ms` `run`). Serializes the accounts the way the runtime does, runs an entry function in the test process (native code on C, node on JS), reads the accounts back; an instruction of more than 255 accounts is refused before the entry is called, as the runtime refuses it (`MaxAccountsExceeded`, agave `program-runtime/src/serialization.rs:23,201-202`): `result` is `REFUSED` and `fault` names the error, pinned by the `host.ms` test; The System, Token, Token-2022 and Associated Token instructions the std sends are executed (`std/solana/simulatorPrograms.ms`, `simulatorToken.ms`, dispatched by `simulatorInvoke.ms`), every other CPI is recorded. On JS the same simulator runs over `memory.jms` (§1). Measured on tree `8b12544abc21` with the compiler of that tree plus the per-module import fix (inbox `2026-10-19-js-module-emit-import-shadowed-by-local.md`): the four geass playground programs (`src/test/corpus/programs/solanaPlayground{Hello,Counter,Vault,Escrow}.ms`) print the same lines on c, orc, danger, js and esm; `msc test --target=js` passes `std/solana/test.ms` 361/361 and the tests of every other `std/solana` module, as on C; the `.so` of 16 Solana programs (the escrow, debug and `--release`, anchorBench `helloworld`, and 13 probes of `tools/solana`) is byte-identical to the build before the port. Not verified on JS: the Raiser (std/solana has no Raiser kernel: `Cannot resolve module './kernel'`), a browser on msc.wasm, the escrow's "take refuses a token account of another owner" test until the spread-copy fix lands (inbox `2026-10-19-js-spread-in-array-literal-shares-nested-struct.md`), and an integer address kept across `run()` calls, which dangles on JS because each run drops every region but the input. The simulator answers as the runtime does, calibrated case by case against LiteSVM 1.4.1 and the real programs by `node tools/solana/hostFidelity.mjs` and `node tools/solana/tokenOps.mjs` (each on its probe, both in the gate's solana lane; `std/solana/hostTest.ms` holds the host side): a run the runtime aborts reads `result == REFUSED` with the runtime's error named in `fault`, and `NOT_SIMULATED` when the simulator cannot judge (an instruction or a Token-2022 extension it does not model); a CPI that fails ends the run with the callee's error, whatever the program does with the status; a run that does not succeed leaves every account as it was (a created account is gone, a closed one is back), while clock and other test settings stay; a writable account left below rent exemption is `InsufficientFundsForRent`, with the rent `minimumBalance` reads; lamport balance, owner, data and read-only rules are judged at the end of the instruction and at each CPI; a CPI passes only the signer and writable privileges the caller holds, whatever program it calls. Not simulated, listed with the runtime's answer in `hostFidelity.mjs`: a call to an account that is not a program, 64 calls in one instruction, the compute budget, a call nested five deep. After a failed call the program's native code still runs to its end in the test process; nothing it does reaches `run()`, `logs()` or `invocations()`. Verifier, dispatch, init/close/realloc, event and token pins: `std/solana/test.ms`, `std/solana/token.ms`; MagicBlock and VRF instruction bytes, checked against `ephemeral-rollups-sdk` (pinocchio `delegate.rs`, `utils.rs`), the VRF SDK and the validator's `process_schedule_commit.rs`: `std/solana/magicblock.ms`, `std/solana/vrf.ms`; the escrow's: `examples/escrow/program.ms`.
- **LiteSVM** (`tools/solana`, `litesvm` 1.4.1, `@solana/kit` 8.2.0, `@coral-xyz/anchor` 0.31.1). `node tools/solana/escrow.mjs <escrow.so> <escrow.json>` builds every instruction with Anchor's client from the IDL and requires its accounts, flags and bytes to equal the hand-built ones, decodes the escrow account with Anchor's coder and names error 6000 from the IDL, then runs make, take, refund and a refused make against the real SPL Token and Associated Token programs. A field order swapped in the IDL's `Escrow` type, or a `writable` flag set on `mint_a`, fails it. Measured on tree `978fdc672e29` with `msc build examples/escrow/program.ms --os=solana` (platform-tools v1.57): make 35,961 CU, take 32,989 CU, refund 23,626 CU (after make 43,461 CU), make with a zero deposit `Custom(6000)` at 605 CU; every assertion passed. Tree `cb9810dbe7c0` measured 44,817 / 50,634 / 32,940 CU.
- **Heap exhaustion.** A program that asks for more than its 32 KiB heap logs `std/solana: the 32 KiB program heap is exhausted (asked N more bytes at P)` and ends with the runtime's `abort` syscall; the host simulator prints the same sentence and aborts. No caller ever sees NULL. Pinocchio's `BumpAllocator::alloc` returns null on exhaustion (`pinocchio-0.9.3/src/entrypoint/mod.rs:648-659`) and its panic handlers log and call `abort` (`mod.rs:436-505`); here `msArenaAlloc` (`runtime/manual.h`) is that panic. `node tools/solana/heapExhausted.mjs <heapProbe.so>`, with the probe built by `msc build tools/solana/heapProbe.ms --os=solana`, finds the first failing count on two allocation paths (class instances, one raw request), requires the seeds, CPI, rent, clock, return-data, `logPubkey` and event paths to leave the heap where it is, and requires the named line, no access violation and fewer than the 1,400,000 CU of the budget, then does the same for a request of 2^64 - n bytes. Measured with LiteSVM 1.4.1: before, 163 PDA checks in one instruction died with `Access violation writing 8 bytes at address 0x18`, 50 CPI builders and 1,022 class instances with the same error, each burning the whole 1,400,000 CU, and a request of 2^64 - 1 bytes succeeded; after, each fails at the same count with the named line (286,873, 6,558 and 16,467 CU) and the largest request that fits fills the heap to its last byte. The seeds path is the fourth probe and no longer allocates: a seed list is a stack table (§4), so 1, 2, 163, 164 and 500 rounds leave the heap position at 0x300000048 and the instruction runs until the compute budget, 823 rounds at 1,398,740 CU, 824 rounds failing with `ComputationalBudgetExceeded`. The same script run against the heap-seed probe built by the old compiler fails 6 checks, the first at 2 rounds, where the heap position has already moved. Not measured: a program that raises its heap with `RequestHeapFrame`, whose size `runtime/manual.h` does not read.
- **Growth.** An array or string that outgrows its block takes a new block and copies the old size into it, which is `GlobalAlloc::realloc`'s default (`library/core/src/alloc/global.rs:286-300`, `copy_nonoverlapping(ptr, new_ptr, min(layout.size(), new_size))`), and Pinocchio's `BumpAllocator` defines only `alloc` and `dealloc` (`mod.rs:645-668`). The runtime's one entry is `msRealloc(old, oldSize, newSize)` (`runtime/manual.h`; hosted builds forward to libc `realloc`); a bare `realloc(` in an arena build is a compile error that names it. The arena shim used to copy the new size out of a block that held the old one, so the first `push` past a capacity ended in `sol_memcpy_`'s `Overlapping copy`, and an append to a string literal faulted writing the literal's `cap` word, because the atomic load of that word lowers to a load plus a store (`msStrCapLoad`, `runtime/core/string.h`, a plain load under `--gc=manual`). `heapProbe.ms` ops 6-9 push `uint64`s, build a literal and push onto it, push structs, and append `"ab"` to a string; `heapExhausted.mjs` reads every element back against a checksum at 1 to 250 elements, then grows each past the heap and requires the named line. Measured with LiteSVM 1.4.1 on tree `6a1cccd68fe1`: the old runtime fails 39 checks (`Overlapping copy` for the arrays, `Access violation writing 8 bytes at address 0x80` for the string), the new one passes all 119: 1,024 `uint64`s still run and the 1,025th names the heap (19,633 CU), likewise 512/513 structs and 4,096/4,097 appends. A block outgrown is not reclaimed, so one array that reaches 8 KiB has used 16,576 bytes of the heap by its next growth. The escrow's `.text` is byte-identical and its CU unchanged (make 35,962, take 32,977, refund 23,642). Not measured: more than one growing array alive at once.
- **Seed lists.** Measured on tree `051cd375cd42` with `msc build examples/escrow/program.ms --os=solana` from a clean working directory, LiteSVM 1.4.1, the same escrow program with its derivations written as lists and its signers still `Seeds`: the `.so` goes from 75,696 to 76,552 bytes, of which `.text` falls from 57,976 to 57,160 and the symbol and string tables grow by 1,673 (the new functions' mangled names carry the module path), make 35,962 to 35,858 CU, take 32,977 to 33,019, refund 23,642 to 23,698, the refused make 613 unchanged. `take` and `refund` write the list for `pdaWithBump` and build the heap `Seeds` for the signer, so each evaluated its seeds twice; the signer is a list too since §4 "Signing". Derivation through each seed kind equals the address the heap seeds derived (`std/solana/test.ms`, six addresses computed with the old compiler), and a changed `keyAddress` offset or seed-count limit fails the account and limit tests.
- **Signers.** Measured at commit `02b3e4a1c` with `msc build examples/escrow/program.ms --os=solana` from `/tmp` directories of one path length (the symbol table carries the module path), LiteSVM 1.4.1, against the previous commit built the same way: the `.so` goes from 74,560 to 73,312 bytes and `.text` from 57,160 to 56,528; make 35,858 to 35,797 CU, take 33,019 to 32,887, refund 23,698 to 23,594, the refused make 613 unchanged; `node tools/solana/escrow.mjs` passes. Taking `take` and `refund` below the heap-`Seeds` build needed the std-side limit check dropped from the signing path (the host simulator and the runtime refuse past 16 seeds of 32 bytes, so a program that exceeds them still fails loudly): with it, take was 33,016 and refund 23,716. The host simulator records each CPI's signer seeds (`HostInvocation.signerSeeds`); `std/solana/test.ms`, `token.ms`, `magicblock.ms`, `vrf.ms` and the escrow assert them for every signing path, and those assertions were written against the `Seeds` build first and kept unchanged through the port, so each path records the same seeds as before (a changed byte in the expected seeds fails four tests). The heap probe's signing path (`heapProbe.ms` ops 10 and 11, a CPI to the program itself) leaves the heap where an unsigned CPI does at 1, 2, 8 and 20 rounds; a CPI took 160 bytes of the heap, all of it the `Instruction` builder, signed or not, and a signed CPI cost 1,514 CU against 1,426 unsigned. The same script against the `Seeds` build fails four checks: a signed CPI took 272 bytes and 1,611 CU against 1,414. The macros bind `selectInstruction`, `readArgs` and `createPdaOf` by symbol: `std/solana/test.ms` imports none of them, and against the previous std it fails with `Undefined variable 'readArgs'`, `'selectInstruction'` and `'createPdaOf'`.
- **CPIs.** Measured on tree `bbc489cca678` with `msc build examples/escrow/program.ms --os=solana` from `/tmp` directories of one path length, against `da84849e`'s compiler loading the std of the commit before (`5533b769a`) from a second directory of the same length, platform-tools v1.57, LiteSVM 1.4.1: the `.so` goes from 73,176 to 69,864 bytes and `.text` from 56,528 to 52,944; make 35,797 to 35,846 CU, take 32,887 to 32,764, refund 23,594 to 23,520, the refused make 613 unchanged; `node tools/solana/escrow.mjs` passes, and the host-simulator assertions on every CPI's program, accounts, flags, data and signer seeds are the ones written against the heap builder (the System, `createAssociatedToken` and `scheduleTask` ones were added first, on that build). Per CPI from `heapExhausted.mjs`, a one-account CPI to the program itself with three data bytes: 160 bytes of the heap and 1,425 CU unsigned (1,513 signed) before, 0 bytes and 1,390 CU unsigned (1,457 signed) after, and the heap position after 1, 2, 8, 20 and 40 unsigned, signed and 512-byte-buffer CPIs, and after 1,000 rent reads, is the seeds path's; the same script against the old build fails 15 checks, and a rent-only probe against the old std (24 bytes per read) fails 4. A function's frame is the highest stack address it touches above the frame floor, read from `llvm-objdump` of the `.so`: the escrow's `take`, `refund` and `make` stay at 2,648, 2,040 and 1,400 bytes; `invokeCpi` takes 88, `invokeList` 944, the core of `commit` 544, `requestRandomness` 2,120, the core of `scheduleTask` 1,896, and a signed 16-account CPI beside a 1 KB buffer 2,776 (`solanaCpiFrame.ms`). Not measured: `--release` or an optimization flag (the escrow's `.so` was the same bytes with `--release` and the same size with `--passC=-O2`), a program that raises its frame, and more than one signed 16-account CPI in one handler.

- **Immutable reader inputs.** Windows x64, 2026-10-06, source tree `11fdb5911671`: seed, signer and account-descriptor readers accept const-owned tables through read-only views; CPI `infos` and byte storage remain writable. The native `std/solana/test.ms` run prints `Tests 392 passed (392)`; `std/solana/vrf.ms` prints `Tests 332 passed (332)`. A separate public caller using a const callback table and const argument bytes sends both VRF overloads and prints `VRF caller: result=0 calls=2 signers=1,1 data=128,128 tail=7,8`. These runs use the host simulator; SBF/LiteSVM, live VRF fulfilment and compute-unit costs were not rerun.

- **No transient memory held.** Measured on tree `9b1361b76fdd` with `msc build examples/escrow/program.ms --os=solana` from `/tmp` directories of one path length, against `da84849e`'s compiler loading the std of `c63f0ec7b` (the commit before) from a second directory of the same length, platform-tools v1.57, LiteSVM 1.4.1: the `.so` goes from 69,864 to 68,728 bytes and `.text` from 52,944 to 51,976; make 35,846 to 35,697 CU, take 32,764 to 32,649, refund 23,520 to 23,452, the refused make 613 unchanged; `node tools/solana/escrow.mjs` passes, and every host-simulator assertion on a CPI, event, return-data and clock byte is the one written against the previous std (the System, token, MagicBlock and VRF modules changed only their call syntax). Per call from `heapExhausted.mjs`, a read of the clock, of the return data, a `logPubkey` and an `emit` of 49 bytes took 40, 1,056, 32 and 56 bytes of the heap and 177, 292, 129 and 408 CU before; after, 0 bytes each and 176, 320, 107 and 461 CU (the return data copies its 1,024 bytes, the event core is one loop for every event; the return-data loop reads one byte in both, and the loop the probe runs now also checks the program and four bytes, 710 CU); the heap position after 1, 2, 8, 20 and 40 of each equals the seeds path's, the same script against the old build fails 20 checks, and it requires the clock's five fields, the base58 of `logPubkey`, the Borsh bytes of the event and the program, length and bytes of the return data to come back as written. A CPI through a run-time list of 1, 16, 17, 63 and 64 accounts is sent and one of 65 is `InvalidArgument` (`heapProbe.ms` op 19); per CPI 1,344 CU unsigned and 1,418 signed against 1,390 and 1,457. Frames from `llvm-objdump` of the `.so`, as above: `invokeList` 3,648 bytes (944 at 16), `logEvent` 1,048, `returnData` 72 (its 1,056 bytes sit in the caller's frame, 1,120 in the probe's loop), `requestRandomness` 2,112, the core of `scheduleTask` 1,776, `commit` 512, a signed 16-account CPI beside a 1 KB buffer 2,736, and 44 accounts beside a one-byte buffer 4,008; the escrow's `take`, `refund` and `make` stay at 2,648, 2,040 and 1,400. Not measured: a handler with several run-time lists of 64 in one frame, a caller whose own frame is near 4 KB when it calls `returnData`, `--release` or an optimization flag.

- **Generic wrappers.** A generic costs one body per type it is instantiated for, and the instance is emitted into the module that defines it, so without LTO it is never inlined into its caller (SBF whole-module linking is selected by `--danger` or explicit LTO, not by `--os=solana` alone; see `docs/BARE.md` "Solana LTO follows the optimization flags" for the measured flag matrix. The per-copy sizes below are of builds without it, and `solanaGenericSize.ms` builds with `--lto=off` because the merged module leaves no copy to read). The checks therefore live in non-generic cores in `core.ms` (`ownedAccount`, `mutableAccount`, `delegatedAccount`, `createdAccount`, `createdPdaAccount`, `closedProgramAccount`, `resizedProgramAccount`, `canonicalBump`, `givenBump`, `selectedInstruction`), which take what differs between types as arguments (the discriminator word, `sizeof(T)`, the space, the seeds), and the generic in `typed.ms` passes those and keeps the typed result (`Mutable<T>`, `Pda<T>`, `T`). Every check and every error code is the one the generic had: `tools/solana/checkCost.mjs` runs the same refusals against the old std and this one on LiteSVM and requires each code to match (3001, 3002, 3003, 3007, 2000, 2006, 101, 102), and `std/solana/test.ms`, `token.ms`, `magicblock.ms`, `vrf.ms` and the escrow's host tests pass unchanged. Measured on tree `ae605451a0bf` with `msc run src/test/guard/solanaGenericSize.ms` (it writes a program that instantiates every generic for nine account types, builds it with `--os=solana`, platform-tools v1.57, and reads the symbol sizes of the `.debug` copy), against the std of `99d28088c` loaded by the same compiler, bytes per copy before to after: `close` 752 to 112, `realloc` 824 to 112, `createPdaOf` 920 to 312, `verifiedPda` 512 to 224 for a `Mutable<T>` and 520 to 112 for a `Delegated<T>`, `verifiedPdaWithBump` 384 to 224 and 336 to 112, `mutable` 360 to 208, `owned` and `delegated` 232 to 208, `create` 288 to 224, `selectInstruction` 688 to 192 (its core is 448, one copy), `external` 384 to 400, `externalMutable` 504 to 496, `readArgs` 248 (the escrow's structs) and `read` 168 unchanged. The instances of the nine-type program were 53,968 bytes and are 23,736, plus 3,912 for the cores they share; `.text` goes from 114,736 to 83,424 bytes. A pass-through wrapper (`Delegated<T>`, `close`, `realloc`) is 14 instructions and a typed one that rebuilds its `Result` 26 to 39: the emitted C writes a zeroed temporary, calls the core and copies it to the result slot, and builds the typed variant with a `memset` of the whole variant. `external`, `externalMutable` and `read` hold the type's own `acceptsOwner` and `decode`, which nothing shares (`external` and `externalMutable` have called the type's `verify` since the account-checks bullet below). The bounds in the guard sit 16 to 48 bytes above these sizes; `owned`, `delegated`, `mutable`, `create`, `verifiedPda`, `verifiedPdaWithBump`, `createPdaOf`, `realloc`, `close` and `selectInstruction` are over their bound on the old std. Three changes beside the wrappers: `accounts<T>()` emitted `@comptime { return T.discriminator().word(); }` where it used to call both at run time (24 bytes less a field, and 33 CU less in the escrow's `take` and in its `refund`, one `Mutable` field each), and was reverted because that block runs the first overload of `discriminator` for every account type (§9; the numbers below are of that tree); the input parser (`msSolParse`, `runtime/solana/solana.h`) was `static inline` and clang put its 536-byte loop into every function that reads an account, the instruction data or the program id, seven copies in the escrow, and is now a weak `noinline` function behind the inline check; `selectInstruction` compared 8 bytes at a time with a signed `table.length / 8`, which linked `__divdi3` (1,296 bytes, §6's 170 CU per call) and is now one word compare per member and a shift (`instruction<Dispatch>` 331 to 135 CU). Compute units per check, `node tools/solana/checkCost.mjs checkProbe.so control.so` on LiteSVM 1.4.1 with `tools/solana/checkProbe.ms` built by each std, each total less the 234 CU of an instruction that only reads one account: `owned<T>` 567 to 516, `mutable<T>` 570 to 528, `delegated<T>` 563 to 513, `accounts<T>()` of seven fields 2,463 to 2,197, `args<T>()` of five fields 329 to 271, `createPda<T>` 4,037 to 3,997, `create<T>` 1,934 to 1,875, `pda` 4,208 to 4,158 and 2,695 to 2,634 for a `Delegated<T>`, `pdaWithBump` 2,776 to 2,718 and 2,762 to 2,693, `realloc<T>` 875 to 824, `close<T>` 785 to 733, `instruction<T>` 331 to 135. The escrow, built by the same compiler (the `.so` is stripped, so the path the std was loaded from does not enter its size), `.so` 52,592 to 48,040 bytes and `.text` 51,960 to 47,408; make 35,695 to 35,324 CU, take 32,647 to 32,206, refund 23,450 to 23,097, the refused make 611 to 425; commit by commit the `.so` is 49,152 after the parser, 49,056 after the discriminator fold and 48,040 after the wrappers, so for a program with one account type the wrappers and the cores add about 330 bytes (the 1,016 of that commit less the 1,296 of `__divdi3` and the 48 of `selectInstruction`, taken by subtraction, not built apart) and the parser and the division carry the gain. `node tools/solana/escrow.mjs` and `heapExhausted.mjs` pass. Rejected: wrappers in `core.ms` beside their cores, because clang then inlines a core that is small enough into every wrapper (`owned<T>` went from 208 to 456 bytes the moment the parser stopped being inlined into `ownedAccount`), which is why the generics have a module; building the `Result` at the call site in `args<T>()` and `accounts<T>()` to drop `readArgs` (`(fits ? Result.ok(…) : Result.err(…)) as Result<T, ProgramError>` compiles), because the cast names `ProgramError` in the user's module and a module whose handlers return another error type through a converter does not import it. Each `accounts<T>()` and `args<T>()` site still carries its `readArgs` instance, 152 bytes for a one-field struct, 304 for four and 248 for each of the escrow's three accounts structs (7, 9 and 11 fields), about 40% of a site (`accounts<{x: Signer}>` costs 392 bytes a site and `accounts<{4 × Signer}>` 704, from a program with one such site and one with two, subtracted). Not measured: Hibernal's own program, `--release` or an optimization flag, any platform-tools but v1.57, a program with more than one instruction enum, the JS backend (the touched modules are `.cms`).

- **Proofs as structs.** A proof became a struct with a private `Account` (§3), built only in `typed.ms`, so the proofs, their readers and the non-generic verifiers moved there from `core.ms`, the cores that created an account take `Account`, and `accounts<T>()` calls `program<P>`, `owned<T>`, `mutable<T>`, `delegated<T>`, `external<T>` and `externalMutable<T>` where it called the cores and converted the result with `as`. The first four are `@inline`. Measured with `msc build <program> --os=solana --danger` (platform-tools v1.57; the compiler built from `d69b8474d`), the std before and after, LiteSVM 1.4.1 with `tools/solana/anchorBench.mjs` and `escrow.mjs`: helloworld 8,096 to 7,920 bytes and `init` 2,208 to 2,196 CU; vault 6,200 to 6,144 bytes, `deposit` 1,920 to 1,914, `withdraw` 562 unchanged; the escrow 31,072 to 31,016 bytes, `make` 20,342 to 20,351, `take` 8,161 to 8,224, `refund` 6,168 to 6,190, a `take` refused by `@hasOne` 3,214 to 3,256 (an `External` or `ExternalMutable` field rebuilds the `Result` the type's `verify` returned). With `--lto=off`: 11,960, 9,728 and 43,104 bytes to 11,768, 9,960 and 43,728. `solanaGenericSize.ms` passes (`.text` 76,968 to 76,288). Rejected, measured on the same programs: the generics in `core.ms` beside the proofs, because without LTO clang inlines the cores into every copy (`Mutable_verifiedPda` 176 to 504 bytes, `.text` 82,944), and `@noinline` on those cores keeps the guard green but stops LTO from inlining a core used once (helloworld 8,568 bytes); `@inline` on `external` and `externalMutable` changes no byte or CU under LTO and leaves the guard no copy to measure. Not measured: Hibernal's program, the JS backend (the modules are `.cms`).
- **Account checks and field decorators.** Measured on tree `ad589d68ab98` with `node tools/solana/checkCost.mjs checkProbe.so control.so` (`tools/solana/checkProbe.ms` built by each std with the compiler built at `99d28088c`; the control is the std of `79c78317b`), LiteSVM 1.4.1, platform-tools v1.57. The probe lists nine accounts now, two more than the paragraph above, so its idle instruction costs 264 CU and the control's figures are 2 CU off that paragraph's. Compute units of the check, control to this tree, each total less the idle one: `owned<T>` 518 to 106, `mutable<T>` 531 to 116, `delegated<T>` 512 to 112, `accounts<T>()` of seven fields 2,198 to 573, `external<Mint>` 751 to 219, `externalMutable<TokenAccount>` 917 to 246, `pda` 4,160 to 3,377 and 2,634 to 1,864 for a `Delegated<T>`, `pdaWithBump` 2,719 to 1,934 and 2,693 to 1,925, `createPda<T>` 3,998 to 3,590, `create<T>` 1,873 to 1,797, `realloc<T>` 824 to 379, `close<T>` 733 to 283; `args<T>()` and `instruction<T>` are unchanged. Of the 412 CU `owned<T>` lost, 340 were the comparison of the owner with the program id: `==` on a `Pubkey` is a loop of 32 byte compares of 11 instructions each, 352 CU for equal keys, and Pinocchio compares a word at a time for that reason (`pinocchio-0.9.3/src/pubkey.rs:44-54`, `pubkey_eq`); `pubkey.ms` overloads `==` on a `Pubkey` as four word compares under `--os=solana` (measured alone: 516 to 176). The other 72 were the account table read twice (a bounds and a parse check each), the owner and the program id copied out of the input buffer before the compare, and the `Result` of the core rebuilt by the generic; the cores now compare the 32 bytes in place, return a code, and the generic builds its `Result` from it. What is left, 106, is against the reference's owner compare, discriminator compare and length check, about 35 instructions counted from the disassembly and not measured apart: the generic reads the discriminator word at run time (§9) and builds a typed `Result`. `external<T>` and `externalMutable<T>` called `T.decode` to validate a mint or token account, which builds the whole value; they call `T.verify`, which checks the owner, the length and the state byte `decode` checks, and `std/solana/token.ms` runs both over 720 accounts (three owners, ten lengths, the extension byte, the initialized and state bytes) and requires the same answer. Constraints, over the same three-field struct without them (`checkProbe.ms` ops 17 to 23): `@seeds` with `@bump(account.field)` +1,721 CU (one `create_program_address`), a bare `@bump` +3,177 (`find_program_address`), `@hasOne` +47, `@constraint` +20, `@address` +51. The escrow, built by the same compiler: `.so` 48,040 to 47,896 bytes and `.text` 47,408 to 47,264; make 35,324 to 27,473 CU, take 32,206 to 18,671, refund 23,097 to 15,382, the refused make 425 unchanged; its program part is 172 lines from 190, and `take` and `refund` hold no constraint call (26 lines from 38). The pins: `checkCost.mjs` fails an op that costs more than 8 CU above its baseline (the control fails 14 of them) and runs each refusal against both builds; `std/solana/test.ms` runs each decorator on the host simulator with its code and the order in which constraints and type checks run; `node tools/solana/escrow.mjs` passes and its `constraints` scenario refuses a take whose escrow names another maker, mint A or mint B (2001), a stored bump or seed that does not give the escrow's address (2006), a token account of another authority (2015) and one off the associated address (2009), where the escrow built before the port answers 2006, 2012 and 2006 and fails it; `src/test/guard/solanaDecoratorRefused.ms` pins each refused form. Not measured: Hibernal's own program, any platform-tools but v1.57, `--release` or an optimization flag, a struct declared in another module than the call of `accounts<T>()`, the JS backend (the touched modules are `.cms`), `solanaGenericSize.ms` against its bounds on the old std (it passes on this tree with `owned`, `mutable` and `delegated` at 224 bytes a copy, their bound).

### Account checks as a table — measured, not adopted

Hibernal's size ask: one const table per accounts struct in `.rodata` and one shared walker instead of one call per field. `node tools/solana/accountTableCost.mjs --msc <msc> --form std|table|chain --suite matrix|decorators|hibernal|escrow|refusals` builds the same programs in three forms and runs them on LiteSVM 1.4.1 (platform-tools v1.57, tree `c8f30adc0`, the compiler built from that branch). `std` is `accounts<T>()` as written. `table` is `tools/solana/accountTableProto.cms`: a word per field (kind, flags), the program ids beside it, the constraints as a second table of seeds, has_one, address, associated and token entries, with the discriminator word, `sizeof(T)` and the address of a data member passed at run time as the macro passes them today. `chain` keeps one call per field but each returns a failure code and a struct has one failure site. The 28 refusals of `--suite refusals` (every field kind, each decorator, a missing account, field order) answer the same code in the three forms, and the escrow with its three structs in `table` or `chain` passes `escrow.mjs`.

| field kind | bytes (.text + .rodata) std, table, chain | compute units std, table, chain |
|---|---|---|
| Signer, WritableSigner, Writable | 119, 54, 96 | 40, 29, 27-29 |
| Account | 119, 54, 96 | 37, 29, 23 |
| SystemAccount | 119, 54, 96 | 46, 56, 33 |
| Program\<System> | 255, 54, 104 | 90, 68, 47 |
| Owned\<T> | 169, 102, 142 | 76, 84, 56 |
| Mutable\<T> | 169, 102, 142 | 96, 88, 62 |
| Delegated\<T> | 169, 102, 142 | 95, 82, 54 |
| External\<Mint>, External\<TokenAccount> | 119, 54, 159 | 188, 212, 183 |
| ExternalMutable\<TokenAccount> | 191, 54, 235 | 211, 216, 207 |

Each figure is per field, from a program that lists 1 and 8 fields of the kind; the compute units are less the 16 CU the runtime's input parse costs for every account an instruction lists, in every form. A data field's bytes held about 90 for reading the type's discriminator word at run time, in the three forms; that word now folds at compile time (§4) and these figures were not measured again. A struct costs more than its fields: one `Signer` field is 69, 100 and 38 CU and a one-field program 2,704, 8,016 and 2,272 bytes, because `table` links a walker of 1.0 KB, its slow path of 0.8 KB and the token verifiers (3.1 KB, which `std` links with its first External field), and a struct with constraints adds a second call and a constraint walker of 3.0 KB with the associated-address and seed derivations it calls (2.3 KB, which `std` links with its first `@associated` or `@seeds`); the first `@hasOne` costs +48 CU and +440 bytes in `std`, +127 and +6,440 in `table`, +66 and +608 in `chain`, and the first `@seeds @bump(account.field)` +1,720, +1,803 and +1,736 CU.

| program | .so bytes std, table, chain | compute units std, table, chain |
|---|---|---|
| Hibernal-shaped: 26 instructions, 174 fields, 59 decorated, the sum over the 26 less the idle instruction | 66,984, 50,632, 56,632 | 64,660, 66,965, 60,695 |
| `examples/escrow`: make, take, refund | 46,488, 44,560, 45,016 | 27,398, 18,615, 15,338 in `std`; 27,523, 19,017, 15,581 in `table`; 27,280, 18,518, 15,219 in `chain` |

`table` is 24% smaller on the Hibernal-shaped program and 4% on the escrow, and costs 3.6% more compute units on the first and 0.5%, 2.2% and 1.6% on the escrow's three instructions: bytes down and compute units up past a few CU a field, so it is not adopted. A macro cannot declare a module `const` where `accounts<T>()` is called, and a `const` aggregate inside a function is built on the stack (the emitted C stores each element; Nim declares a proc's `const` as module data, `compiler/ccgexprs.nim:3497-3507,3555-3563`): with each table inside its handler (`--local-tables`) the Hibernal-shaped program is 52,440 bytes and 67,561 CU, the escrow 44,864 bytes and 27,539, 19,060, 15,611 CU. `chain` is smaller and cheaper than `std` on both programs (15.5% and 6.1% on the Hibernal-shaped one) and adds no fixed cost, but a decorator is dearer in it than today; the 3.2% and 0.4% to 0.8% it saves on the escrow are the per-field part only. Not measured: the JS backend (the modules are C-only), `--release` or an optimization flag, Hibernal's own program, a Token-2022 account, any platform-tools but v1.57.

### Private proof chain — current candidate

The figures above describe the historical prototype, whose raw-account-to-proof
casts are now correctly refused. Current `--form chain` exercises the real std
macro; comparison requires separate baseline/candidate compiler installations,
not two labels over the same std.

Matched `--danger` runs on 2026-10-07, LiteSVM 1.4.1/platform-tools v1.57,
deployed std/compiler `369dbc18a` versus the `msc-stable` std-solana candidate:

| Hibernal-shaped fixture: 26 instructions, 174 fields, 59 decorated | deployed std | candidate chain |
|---|---|---|
| `.so` bytes | 52,248 | 46,696 |
| total CU over idle | 21,412 | 21,396 |

Commands: `node tools/solana/accountTableCost.mjs --msc <baseline-or-candidate>
--form std|chain --suite hibernal --danger --work <separate-directory>`.
The 28 refusal scenarios retained every code. The escrow built at **30,160 B**;
Anchor's IDL client replay passed make/take/refund and the seven malformed
constraint scenarios. Heap replay also passed every check.

Rejected intermediate implementations: the initial real chain was **48,936 B /
21,752 CU** under `--danger` (bytes lower but CU higher); the one-field IIFE
increased the field-value consumer beyond its 465-CU cap. Raw constraint cores
and a direct expression for degenerate shapes restored the cap to **458 CU**.
Default/no-LTO is not interchangeable with this comparison: the initial real
chain there was **90,032 vs 72,336 B**, so these optimized numbers do not claim
all-mode improvement.

Integration is not complete: a hidden proof alias in an imported accounts shape
still fails `Unresolved type 'Auth'`; the owning bound-annotation fix moved from
`name-to-symbol` to `macro-typed-callee` (not verified there). The full transitive JS codec suite waits for `sized-arrays`.
No completed gate or installed-candidate claim follows from these SBF probes.

### Matched v2 baseline — checked reference approved, measurements in progress

The reference is anchor-next `ff0514b6042e3cf7345bf0cd58eb442542c93172`,
Anchor v2 **2.0.0-rc.1**. The upstream prop-amm fixture is a specialized ASM
entrypoint, not the ordinary checked dispatcher for its `update` instruction.
`bench/programs/prop-amm/anchor-v2/src/asm/entrypoint.s` checks account count,
exact48B data length, writable/signature flags and a constant authority, then
loads8 bytes at `ix_data+1` and writes the price. It does not validate the account
discriminator, declared program id or update argument length on that path.

Measured from an immutable `git archive HEAD` snapshot, command:
`cargo-build-sbf --manifest-path <snapshot>/bench/programs/prop-amm/anchor-v2/Cargo.toml
--tools-version v1.57 --sbf-out-dir <snapshot>/deploy -- --offline`.
Release uses the bench profile (opt3, fat LTO); platform rustc is1.95.0-dev
`ae660768a` (2026-08-17). ELF is **9,808B**, SHA256
`94cb4a4fa845524ea7e2f7308e8d64774daa1a632bc387ee2fe9d7ac26acb291`.
LiteSVM and `mainnetInactiveFeatures.json` are the same ones the SDK harness uses.
The probe `/tmp/std-solana-goal-audit/propReferenceRefusal.mjs` sends separate
transactions with signer seed7, writable48B oracle and price1234:

| input | upstream result | CU | resulting price |
|---|---|---:|---:|
| valid | accepted | 26 | 1234 |
| zeroed account discriminator | accepted | 26 | 1234 |
| deployed under another program id | accepted | 26 | 1234 |
| one-byte instruction, missing price | accepted | 26 | 2028873312816101692 |

A different stored authority also passes, but that is **not** a refusal gap:
the upstream fixture intentionally authorizes a fixed key, not that stored field.
These observations concern this specialized fixture, not all Anchor v2 programs.
No safe matched comparison or SDK win follows from the26-CU path. Do not remove
SDK checks to match it. The person approved a checked variant and explicitly
prioritized best measured performance over early API/wire compatibility. Eight-byte
hashes are a diagnostic control, not a mandatory final format.

The checked prop-amm variant uses the ordinary `#[program]` dispatcher and a real
update body, keeping the fixed-authority and exact48B policies. Only this benchmark
snapshot changes: remove `no-entrypoint` from default features and replace the ASM
include/allocator override and unreachable body. Rebuilt with the command/profile
above, it is **9,688B**, SHA256
`ec6277262ffd88691e70b5e07ad64773032187bbec226a91855c6aca592a7427`.
The same probe now gives valid update **87CU**, wrong discriminator refused
`InvalidAccountData`/175CU, alternate deployment refused `IllegalOwner`/62CU,
missing price refused `InvalidInstructionData`/81CU; every refusal leaves price0.
Stored-authority mismatch still succeeds, as the fixed-key policy requires.

All five reference ELFs build: hello7,368B, vault6,296B, nested13,712B,
checked prop-amm9,688B, multisig32,480B. `anchorBench.mjs` gives reference
hello init1,444CU, vault deposit1,597/withdraw408. Actual current SDK under
`./msc-integrated --os=solana --danger` at matching declared ids gives
hello6,960B/init1,765CU; vault6,184B/deposit1,922/withdraw579. These are preliminary
success measurements, **not** a completed matched matrix: vault's reference uses
one-byte tags while that actual SDK build uses eight-byte hashes; refusal/state
parity and the other ports remain to verify.

A scratch SDK (`/tmp/std-solana-tag-probe`) reuses the existing project-define,
macro table/selection, checked Borsh readers and IDL emission with
`-d:instructionFormat=byte`. No actual SDK source was changed for this experiment.
It restricts compact enums to at most256 ordinal members; account/event tags stay
unchanged, scalar loads remain memcpy-safe at unaligned argument offsets. Host
28files/391tests and seven real SBF success/refusal cases pass. A two-operation
probe gives hash1,864B/186+191CU, byte-table1,968B/184+189CU, bounded byte1,952B/
186+186CU: smaller wire alone does **not** prove smaller deployed code. The scratch
vault with bounded byte dispatch gives5,800B/deposit1,923/withdraw624 versus the
reference6,296B/1,597/408, so no CU target or final-format win is claimed. Repro
commands/hashes/limitations are in `/tmp/std-solana-goal-audit/benchCheckpoint.json`;
these temporary artifacts must become a durable runner before baseline completion.

#### Reproducible checked v3/hash control

The subsequent audit found an additional required refusal gap: upstream vault
accepts an alternate deployed program-id for both instructions. Its
`anchor_lang::check_program_id` helper is feature-gated and compiles away under
the fixture's disabled guardrails policy. The checked snapshot now adds an
explicit address comparison returning4100 to each vault handler; the SDK keeps
its existing early declared-id check. This is the approved checked-reference
policy, not a change to the upstream clone or a relaxed SDK check.

`tools/solana/anchorReference.mjs <clone> <fresh-work> hash` archives the pinned
revision, applies `checkedProp.rs` and that vault guard, builds all5 artifacts
with platform-toolsv1.57/`--arch v3`/opt3/fat-LTO/cgu1 and records hashes, commands,
profile and feature fingerprint. Earlier reference builds were defaultv0 while
SDK emittedv3: their numbers above are provisional, **not the final matched ISA
baseline**. The corrected comparison uses ELF flag3 on both sides, eight-byte
instruction tags on both sides and unchanged account discriminators/layouts.

SDK build: `./msc-integrated build examples/anchorBench/<suite>/program.ms
--os=solana --danger -d:programId=<same-id> --output=<so>`.
Replay: `BENCH_REFUSALS=1 BENCH_JSON=<matrix.json> node tools/solana/anchorBench.mjs
<suite>:v2:anchor:<reference.so> <suite>:std:anchor:<sdk.so> …`.
The runner uses identical keys, PDAs, funded accounts, wire payloads and
`mainnetInactiveFeatures.json`; it compares every watched successful account's
bytes/owner/lamports and requires refused transactions to leave business state
unchanged. It records raw refusal codes rather than silently normalizing the
frameworks' different error vocabularies. Inputs include3 stored multisig members,
threshold2, two signed approvals,48B Oracle and398B MultisigConfig.

Measured2026-10-07, hash control:

| fixture | reference ELF B | SDK ELF B | instruction CU reference → SDK |
|---|---:|---:|---|
| hello | 6400 | 6960 | init1441 →1765 |
| vault | 5632 | 6184 | deposit1602 →1922; withdraw418 →579 |
| nested | 12256 | 11112 | initialize2840 →3348; increment866 →1202; reset861 →1202 |
| checked prop-amm | 8448 | 8112 | update81 →198; initialize1398 →2815; rotate_authority93 →218 |
| multisig | 30496 | 22168 | create2762 →3165; deposit2292 →2626; set_label621 →1088; execute_transfer2991 →3461 |

All13 successful instruction pairs have exact watched account-state parity;
**206 refusal probes pass**, including truncated arguments, malformed UTF-8,
overlong labels, invalid threshold, missing accounts, owner/discriminator,
signer/mutability, unknown tag and alternate deployment. Full LTO versus default
SBF LTO produces identical vault6184B/1922/579, so an LTO flag alone is not a fix.
The quantitative target remains unmet: hello/vault ELF larger and all13 SDK CU
higher. This control closes benchmark reproduction, **not optimization or ship**.
Default-byte policy, final optimized builds, all-mode/gate and installed consumer
acceptance are not verified here. Installed binary/support advanced independently
to0d83c4867; no SDK delivery/land/sync from this worktree follows from that.

The multisig port required a fixed32-byte Borsh argument. `args<T>()` now admits
literal `uint8[32]` through the existing bounds-checked memcpy-safe Pubkey reader
and its byte-array member, preserving the author's array type. It neither treats
labels as public keys nor requires a manual decoder. Native SDK28files/473tests
pass; odd offsets, every truncation and invalid adjacent boolean are pinned in
`test.ms`, and real set-label SBF success/bad-UTF8/overlength probes pass above.
Other byte-array lengths, aliases and new IDL argument shapes have **not** been
verified by this narrow gate extension.

#### Existing System prefund instruction, measured optimization

The creation reference read is `lang-v2/src/cpi.rs:453–490`: it uses the existing
System `CreateAccountAllowPrefund` instruction13, not allocate+assign for a
prefunded target. The SDK now uses that same established instruction through its
existing checked CPI machinery; there is no new compiler pass, proof constructor
or invented CPI protocol. Its52B payload is opcode13/lamports/space/owner, target
first and optional funding payer second. Rent shortfall is computed without
unsigned subtraction wrap, signer seeds forwarded unchanged and init's existing
payer==target refusal/exclusive-claim ordering retained. Public
`createAccount` creates an empty address with System instruction 0 as before; an address that already holds lamports (anyone can send some first, which makes instruction 0 fail with Custom(0)) is topped up to the requested balance, then allocated and assigned, with no dependency on the prefund feature (`tools/solana/createAccountPrefund.mjs`, LiteSVM). The prefund path requires the System prefund feature
on the target cluster; an unsupported CPI fails, with no silent fallback.

TDD: the two wire/seed regression cases fail against the prior SDK
(471pass/2fail); candidate native28files/473tests pass, with exact payloads,
zero/partial/full prefunding, balances, owner, zeroed data and signer forwarding.
The native System model recognizes13 and checks allocation bounds, target owner,
existing data and funding before mutation. The full five-fixture v3/hash replay
still has13 exact-state instruction pairs and206 refusal probes/0failures.
All103 SDK refusal records are identical to the prior candidate except CU,
including raw error codes; no refusal-code normalization hides a change.

| SDK artifact | before ELF B → after | before CU → after |
|---|---:|---|
| hello | 6960 →5504 | init1765 →1769 |
| vault | 6184 →6184 | deposit1922 →1922; withdraw579 →579 |
| nested | 11112 →9656 | initialize3348 →3356; increment/reset1202 →1202 |
| checked prop-amm | 8112 →6656 | update198 →198; initialize2815 →1660; rotate218 →218 |
| multisig | 22168 →20712 | create3165 →3169; deposit2626 →2626; label1088 →1088; transfer3461 →3461 |

Prop init removes one real System CPI, saving1155CU; reachable legacy allocation
and assignment helpers disappear, saving1456B in each creation artifact.
Blank-target initialization retains one CPI and regresses4CU (nested's two
creations8CU); this is explicitly **not** an across-instruction quantitative win.
A vault optimizer-only probe, `--passC='-mllvm -inline-threshold=1000'`, gives
6168B/deposit1922/withdraw578 rather than6184/1922/579; it is not a promoted SDK
build policy and its refusal/full-field/all-mode lanes have not been run.
That checkpoint left vault552B above matchedv3 reference5632B, with every
SDK instruction CU higher. It is not a completed optimization or delivery.

### Parser marker reuse — measured 2026-10-08

`runtime/solana/solana.h:msSolParseAccounts` now reads each kept slot's duplicate
marker once, resolves its lookup and advances its cursor in the same branch.
The reference cursor's `next` uses the same resolve/advance ordering
(`lang-v2/src/cursor.rs:135–179` in the archived reference). No entry ABI,
account maximum, duplicate handling, claim marker or proof checks changed.
LLVM previously reloaded the marker after the lookup-table write; removing
that reload and duplicate branch saves48B in each of the five artifacts.

Rebuilt immutable v3 controls and all five candidates with platform-tools
v1.57 clang, `--danger`, identical IDs/features and existing hash encoding:

| Fixture | Reference B → SDK B | Reference CU → SDK CU |
|---|---:|---|
| hello | 6400 →5456 | init1441 →1757 |
| vault | 5632 →6136 | deposit1602 →1910; withdraw418 →571 |
| nested | 12256 →9608 | initialize2840 →3340; increment866 →1190; reset861 →1190 |
| checked prop-amm | 8448 →6608 | update81 →190; initialize1398 →1648; rotate93 →210 |
| multisig | 30496 →20664 | create2762 →3145; deposit2292 →2610; label621 →1080; transfer2991 →3433 |

Evidence is now in ignored, cache-preserving `out/solana/goalAudit/` rather
than `/tmp` (the older temporary artifacts are no longer present):
`parser-matched.{json,log}`, `reference-hashes.txt`, `parser-host-restored.log`,
`parser-entry-guard.log` and `parser-host-table-guard.log`. The full replay
has13 exact successful instruction-state pairs and206 refusal probes,
0 failures; host28files/473tests and entry/host-table guards pass. The host
CMS guard must run on C, not raiser. A guard-before-args AST prototype failed
to compile and was fully removed; it is not a promoted change or root fix.

Size passes4/5; CU passes0/13: the strict target is not met. Vault remains
504B above reference. User resumed the already-approved deeper optimization after the
premature checkpoint pause. `optimize-sdk` remains unfinished; final lanes,
legitimate commit, queued gate/land/sync and installed acceptance are pending.

### Argument bounds — measured 2026-10-08

The low-level argument readers now reject offsets before pointer arithmetic:
`offset <= available` and `width <= available - offset`. Previously,
`offset + width` wrapped for maximal `uint64` offsets, allowing reads of the
instruction prefix. `argBytesFit` validates its four-byte prefix before
subtracting the offset/prefix from available bytes; an absent boolean now
fails `argBoolValid` rather than validating the reader's zero sentinel.
This follows bounded-slice reads: the matched reference's wincode0.6.1
`src/io/slice.rs:29–36` checks the remaining slice before advancing it.
Existing valid wire bytes, errors and raw bool checks are preserved; invalid
wrapping offsets are now refused. This is a std reader fix, not compiler debt.

Five separate uint8/uint16/uint64/Bytes/missing-bool pins fail on the old
arithmetic (**473pass/5fail**) and pass on the candidate (**28files/478tests**).
Logs: `out/solana/goalAudit/args-overflow-variants-{old,new}.log`.
The nongeneric `argU64` reader is compiler-inline; generic proof/Result
workarounds are unchanged. Without this annotation the safe bounds variant
made vault5712B/deposit1909/withdraw617; annotation restores6136/1910/571.
Inlining only `argumentAddress` made no improvement and was removed.
This is measured optimizer behavior, not a reason to restore unsafe bounds.

`safe-inline-matched.{json,log}` retains13 exact-state pairs and206 refusals,
0failures; all103 SDK refusal error/state records match the parser checkpoint
exactly (only their recorded CU is excluded from that equality). Latest SDK:
hello5456B/init1757; vault6136B/deposit1910/withdraw571;
nested9608B/initialize3340/increment1190/reset1190;
checkedprop6632B/update190/initialize1648/rotate209;
multisig20656B/create3145/deposit2610/label1079/transfer3433.
Controls remain the same v3 artifacts. Size4/5,CU0/13 still miss the target.
Fresh independent checks on the same newest source tree: codecC27files/395tests,
codecJS15files/105tests; field replay16905cases, invalid3003, maxvalid460CU
(cap465 unchanged). Logs `codec-safe-{c,js}.log`, `field-safe.log` under
`out/solana/goalAudit/`. Five selected directive guards (proof forgery,
private failure helper, readonly data, pointer field refusal and writable
module binding) match all24 expected diagnostic substrings; logs
`*-safe-build.log` and `proof-build-summary.log`. These are build/refusal
guards, not runnable raiser programs; writable-binding refusal happens after
typecheck, so `check` alone is insufficient. No NEW failures in these focused
checks. Fresh `heap-safe.log` passes every fixed32KiB/named-exhaustion,
oversized request and wrap-boundary check. Fresh escrow SBF replay through
Anchor's client and newly generated IDL passes all make/take/refund and
constraint-refusal scenarios (`escrow-safe.log`, `escrow-safe-idl.json`).
The broader native escrow/IDL lane first exposed one obsolete token-test
assertion requiring System opcode0. `token.ms` now pins opcode13, exact52B,
token owner bytes, target-first/funder-second signer+writable metas and
original PDA seed forwarding; no check was dropped. Old lane421pass/1fail,
new30files/422tests pass (`escrow-idl-safe-tests{,-new}.log`).
SDK `--danger --lto=off` also rebuilds all five fixtures and matches the
LTO-on candidate's13 successful instruction states and206 refusal probes,
0failures (`safe-nolto-parity.{json,log}`). This is functional SDK parity,
not a quantitative comparison to the LTO-on reference. A nongeneric
`keysEqual` compiler-inline probe matches vault6136B/1910/571 exactly and
was removed; its four unaligned word comparisons already match the reference
key-equality routine. Logs `vault-key-inline{,-build}.log`.
Full queued gate, remaining all-mode/real consumers and installed acceptance
remain pending; no delivery follows from this checkpoint.

### R2 entry experiment — 2026-10-08, not gated or installed

The person approved reference-backed R2/private-cursor exploration. The archived
entry in `out/solana/v3Reference/source/lang-v2/derive/src/lib.rs:5824–5888`
uses SIMD-0321's instruction-data pointer; it is not an account-pointer array.
The cursor at `lang-v2/src/cursor.rs:135–179` informed two rejected prototypes:
a private loaded-count/cursor walker produced prop8096B/update228/init1735/rotate247;
always-inlining it produced8592B/234/1692/254, versus safe6632B/190/1648/209.
The noinline build contained three walker copies (objdump); the inline version
also increased size/CU. Both cursor prototypes and both extra context fields were
removed, including their heap-layout change. Artifacts remain in ignored
`out/solana/goalAudit/prop-lazy{,-inline}*`; no new lazy accessor is promoted.

The smaller R2-only experiment keeps eager frame-table parsing. `msSolStart` in
`runtime/solana/solana.h` uses the direct instruction pointer, with the emitted
two-argument entry in `src/codegen/c/index.ms`. A runtime that leaves r2 empty
takes the one-argument path instead: the entry walks past the accounts to the
instruction data with `msSolInstructionDataOf`, the walk the host parser
`msSolParse` takes on every host test. Which runtimes leave r2 empty: agave 4.0.x
sets it only under feature `5xXZc66h4UdB6Yq7FzdBxBiRAFMMScMLwHxk2QZDaNZL`
(`solana-program-runtime` 4.0.0 `src/vm.rs:264-267`; the VM starts every register
at zero, `solana-sbpf` `src/vm.rs:317`, and the x86 JIT loads r2 from that array),
and 4.1.0 and later set it unconditionally (`src/vm.rs:309`). A MagicBlock
ephemeral rollup runs a 4.0 fork with the same gate (`magicblock-svm` 0395009
`program-runtime/src/vm.rs:265`) and activates ten features on an empty set
(`magicblock-processor/src/lib.rs:45-66`), so r2 is zero there. The entry refused
that case from `f97ae2bc2`, and every instruction on the devnet ER failed with
`InvalidInstructionData` after 4 CU (Hibernal, 2026-10-12). Measured 2026-10-12
with a Rust harness on the `litesvm` 0.13.1 crate (program-runtime 4.0.0), a probe
logging the account count, data length, data sum, program id and last account,
for 0, 1 and 3 accounts (one repeated), data of 0, 1 and 100 bytes, built with
the default maximum and with `MS_SOL_MAX_ACCOUNTS=1`: with the feature off the old
entry fails all 18 at 3-4 CU and the new one returns the same logs as with r2 on,
for 15 to 24 CU more, 39 when it walks two records past the maximum; with r2 on
the two entries differ by one CU either way. The walk is not gated: the gate's
LiteSVM 1.4.1 and `solana-test-validator` 4.2.2 both run a runtime that always
sets r2 (the feature deactivated in genesis, the old entry still passed), and the
pin `src/test/guard/solanaEntryAccountTable.ms` checks the emitted entry. When no
supported runtime is older than 4.1 the walk is dead code on SBF.

Builds use `./msc-entry-proto build examples/anchorBench/<fixture>/program.ms
--os=solana --danger --cc=<v1.57-clang> -d:programId=<matched-id>
--output=out/solana/goalAudit/<fixture>-r2.so`, followed by the existing harness
with `BENCH_REFUSALS=1 BENCH_JSON=out/solana/goalAudit/r2-matched.json` and the
same archived v3 reference artifacts. `r2-matched.{json,log}` records13 exact
successful state pairs and206 refusal probes,0failures; all103 SDK refusal
error/state records match `safe-inline-matched.json` exactly, excluding CU.

| Fixture | SDK bytes | SDK CU, instruction order unchanged |
|---|---:|---|
| hello | 5368 | 1755 |
| vault | 6048 | 1908 / 568 |
| nested | 9520 | 3339 / 1188 / 1188 |
| checked prop | 6544 | 187 / 1646 / 206 |
| multisig | 20568 | 3146 / 2609 / 1076 / 3435 |

Every artifact is88B smaller than the safe checkpoint. Most instructions save
1–3CU, but multisig create regresses1CU and transfer regresses2CU; these are not
hidden by totals. Size4/5,CU0/13 still miss the unchanged reference target;
vault remains416B larger. The entry guard failed on the old builder and passed
on this prototype; compiler check372modules and builder349modules pass.
Renewed R2-only native host28files/478tests and both entry/host-table guards
pass (`r2-host.log`, `r2-{entry,host-table}-guard.log`). Heap, field,
full std/all-mode and real-consumer checks remain pending for this shape.
Identity:293 std/runtime source files, sorted within `std` then within `runtime`,
UTF8 relative path with uint64LE byte length plus raw32-byte content SHA256:
`b047304ad9b1daed41b164fd558525e6f10847cd6c97b3c643ef9364a65bea4b`;
prototype builder SHA256
`3ee69b19e4fe17d9515484c57f190b122b571131f9a7ac9e5928e427db0eda5f`.
The prior frozen d589 identity remains valid for its own snapshot, not this one.

### Fixed context-base materialization — measured 2026-10-08

The v1.57 SBF disassembly (`prop-r2.asm`, `entrypoint`) materializes a separate
64-bit heap address for each context field. `runtime/manual.h`
`msSolanaCurrentContext` now uses an empty, tied-register compiler hint: no
instruction or memory operation, no pointer change, no context-layout or heap
change. This makes one register base available for ordinary field offsets.
It is target C optimization, not a new entry protocol or a language change.

Same builder, clang, v3 references, ids and replay command as the preceding
experiment, outputs `<fixture>-opaque.so`, `opaque-matched.{json,log}`:

| Fixture | SDK bytes | SDK CU, instruction order unchanged |
|---|---:|---|
| hello | 5112 | 1739 |
| vault | 5696 | 1889 / 553 |
| nested | 9304 | 3323 / 1185 / 1185 |
| checked prop | 6160 | 170 / 1629 / 200 |
| multisig | 20024 | 3128 / 2589 / 1060 / 3422 |

Compared with R2-only, every artifact is216–544B smaller and every instruction
saves3–19CU. All13 success states and103 SDK refusal error/state records match
R2-only exactly, excluding CU; full matched replay206refusals/0failures.
Size4/5,CU0/13 still miss the target; vault is64B above the control.
Fresh field16905cases/max443CU (cap465 unchanged), heap exhaustion/wrap checks,
codecC395/JS105 pass; logs `field-opaque.log`, `heap-opaque.log`,
`codec-opaque-{c,js}.log`. Compiler JavaScript ESM duplicate-equality-helper debt
in actual consumers is not made green by the automatic CJS unit lane.
Source identity293files, same explicit per-root recipe:
`228e8836a589501c7ebed7a3e0c3a17a297e487bde6fc4554774d535765f8f77`;
prototype builder remains `3ee69b19...eda5f`.
Default O0, release O2 and danger O3/no-LTO rebuild all five fixtures and each
match the optimized candidate's13 success states/206 refusal probes,0failures:
`opaque-{debug,release,nolto}-parity.{json,log}`. These compare functional SDK
modes, not quantitative results against a differently optimized reference.
Renewed native lanes: std478, escrow421, hello392, vault394, escrowIDL422 tests
pass (`opaque-native-*.log`). Fresh SBF escrow and freshly generated IDL pass
every scenario through Anchor's real client (`escrow-opaque.log`,
`escrow-opaque-idl.json`). The equivalent head-of-record cursor advance was also
measured and rejected: vault5704/1890/554 and prop6168/171/1630/201 versus
opaque5696/1889/553 and6160/170/1629/200. It was fully reverted; no checker or
safety gate was weakened. Real consumer ESM/root-dependency acceptance,
full queued gate and installed acceptance remain pending;
this remains ungated and not installed.

### Literal instruction selection — measured 2026-10-08

`prop-opaque.asm` dispatch reconstructs56B of program-id/tag constants on its
stack, then reads them again. The existing `instruction<Op>()` macro now emits
literal conditional comparisons with the existing eight-byte discriminator;
`core.ms` supplies scalar id/tag predicates and `typed.ms` supplies the typed
Result boundary. No new compiler pass, context layout, wire policy or decoder.
Program id is checked before instruction length, then the first matching enum
member wins as before. Every tag read is length-guarded. The archived reference
keeps a separate entry/internal-dispatch frame (`lang-v2/derive/src/lib.rs:5824–5888`);
removing that frame is not claimed as the fix.

Same matched commands/builders/settings, `<fixture>-literal.so`,
`literal-matched.{json,log}`:

| Fixture | SDK bytes | SDK CU, preceding instruction order |
|---|---:|---|
| hello | 5024 | 1730 |
| vault | 5544 | 1878 / 535 |
| nested | 9192 | 3309 / 1172 / 1164 |
| checked prop | 6048 | 159 / 1611 / 181 |
| multisig | 19928 | 3116 / 2575 / 1046 / 3405 |

Size now5/5, CU still0/13 against matched v2: target remains unfinished.
Compared with opaque base every artifact saves88–152B and every instruction
saves9–21CU.13success states/206refusals/0failures; all103SDK refusal code/state
records and success states match opaque exactly, excluding CU. Native29files/
481tests pass (`literal-pins-restored-green.log`). Narrow selector negation
terminates by signal6 with the minimum-int32 pin; widening before negation
restores green. The other pins retain ordinal0 success and100/101/4100 errors.
Cleanup removes the unused byte-literal builder and reads error codes from
ProgramError instead of duplicating constants. These do not establish renewed all-mode,
codec, heap/field, consumer ESM or installed acceptance on this new shape.
Current293-file source `aff29c7d0651516c7b9dd8053a182c35c04db1a4e5547be40389cf890e279fbb`
includes widening/cleanup/pins. Fresh `<fixture>-literal-pinned.so` /
`literal-pinned-matched.{json,log}` reproduce every byte/CU entry above;
103SDK refusal code/state records and all successful states again match opaque.
Prototype builder remains3ee69. No commit/land/sync. Rejected `@inline dispatch` prop6184B/
171/1630/201 versus opaque6160/170/1629/200 was removed; private bounds and
selectedMember `@inline` gave no improvement and were removed as well.
Skipping the final cursor advance only on R2 prop gave6072B/157/1612/179
versus literal6048/159/1611/181: +24B/+1initializeCU, so it was fully removed
(`skip-last.{json,log}`). Host parse/account-table behavior was not promoted
from this probe.

### Non-zeroing C helpers — measured 2026-10-09

PDA derivation (`msSolDeriveAddress`, `msSolFindAddress`), the rent read (`sol_get_sysvar`, 16
bytes) and the CPI account infos (`msSolInvokeMetas`, a fixed 64-slot frame) moved into
`runtime/solana/solana.h` helpers that do not zero their scratch; `msSolanaEnter` no longer
stores `err` and `currException` into the zeroed heap. UTF-8 validation of a fixed byte field is
`isUtf8` in `std/solana/bytes.ms`. Same v3 reference, ids and replay as above; replay 0 failures,
the SDK refusal records unchanged:

| Fixture | reference B | SDK B | instruction CU reference → SDK |
|---|---:|---:|---|
| hello | 6400 | 4680 | 1441 → 1672 |
| vault | 5632 | 4120 | 1602 → 1783; 418 → 535 |
| nested | 12256 | 8160 | 2840 → 3195; 866 → 970; 861 → 962 |
| prop-amm | 8448 | 5712 | 81 → 157; 1398 → 1564; 93 → 180 |
| multisig | 30496 | 15328 | 2762 → 3004; 2292 → 2508; 621 → 802; 2991 → 3156 |

Size 5/5, CU 0/13. Measured causes of the rest: the early program-id check (about 18 CU per
instruction; removed, see below), the curve check on a stored-bump PDA (161 CU in nested increment/reset and multisig
set_label/execute), the eager account table (about 35–60 CU against a lazy cursor) and
by-value `Result`/`Pubkey` copies in create and transfer. `accountValues` 16,905 cases, max 446 CU.

### Entry parse, seed walks and CPI metas from `.ms` on SBF — measured 2026-10-20

The entry parse, the seed walks and the CPI metas run from `simulatorContext.ms`, `simulatorSeeds.ms` and
`simulatorMetas.ms` on SBF, on the C host and on JS; `solana.h` keeps the uninitialized frames of the helpers above
and calls the modules' `…At` routines with them, and its C copies of the walks are gone. Base `97805bf34`, the 20 SBF
builds of the solana lane, LiteSVM replays:

| step | bytes vs base (261 544) | CU sum vs base (2 712 189) |
|---|---:|---:|
| first port, every frame a zeroed `.ms` local | +7 160 | +44 677 |
| frames in C, rows read and written through `Ptr<SeedSlice>` | +272 | +895 |
| proven PDA create signs from a free slice of its seed list, associated check by the canonical walk, `put*` stores through the storage pointer | +600 | −1 021 |

The byte total of the last row is escrow debug (+632 over the row before; release escrow is 64 smaller). Release
rows: escrow make 20 231 → 20 188, take 7 005 → 6 942, refund 4 188 → 4 157, the associated refusal 2 300 → 2 250;
hello, nested and prop-amm unchanged; multisig execute 2 537 → 2 564, create +8, vault +3/+4, 500 seed rounds +5.
The same canonical walk in `expectAssociated` measured escrow make +24 and take +88 CU and was not kept. The parse
keeps `MS_SOL_MAX_ACCOUNTS`: an SBF build with a 2-slot table sees 2 of 5 accounts (`tools/solana/accountLimit.mjs`).
`slottedCanonicalBump` is a plain function, one core the `Delegated<T>` wrappers share: as `@inline` its body,
now a call where it held the C walk, went into every `Delegated<T>.verifiedPda` copy (16 → 368 bytes,
`solanaGenericSize.ms`); escrow debug pays 96 bytes and 5 CU for the call, release is unchanged.
Left for the compiler: `ExternalMutable<TokenAccount>.read()` builds the struct in a local and copies it out through
the builtins' `memcpy` shim, and zeroes each absent key's payload, about 25 CU per read
(`.inbox/compiler/2026-10-20-sbf-struct-result-copies-through-memcpy-shim.md`).

### Early program-id check removed — measured 2026-10-10

`instruction<Op>()` no longer compares the runtime's program id with the declared one (§2 "A program run at another id"). Same v3 reference, ids, builder (`--os=solana --danger`) and replay command as above, before and after under one compiler; `BENCH_REFUSALS=1 anchorBench.mjs` over the five fixtures, 0 failures both ways, every success state identical, `accountValues.mjs` 16,905 cases, max valid 446 CU (cap 465):

| Fixture | SDK B before to after | instruction CU before to after (reference) |
|---|---|---|
| hello | 4680 to 4552 | 1672 to 1657 (1441) |
| vault | 4120 to 3992 | 1783 to 1769; 535 to 521 (1602; 418) |
| nested | 8232 to 8088 | 3195 to 3181; 668 to 653; 660 to 645 (2840; 866; 861) |
| prop-amm | 5712 to 5568 | 157 to 143; 1564 to 1550; 180 to 166 (81; 1398; 93) |
| multisig | 15472 to 15336 | 3004 to 2987; 2508 to 2491; 651 to 634; 3011 to 2994 (2762; 2292; 621; 2991) |

The `wrong-program-id` refusal changed meaning: it sent the instruction to a program deployed at another id with that id's own fresh accounts, which the reference refuses and the SDK now serves as an independent program. It now sends the declared id's accounts to the program at the other id. The 12 records that expected 4100 (SDK: helloworld `init` and nested `initialize` now `PrivilegeEscalation`, vault and multisig `create` 2006, the other seven 3007) keep "refused, state unchanged"; prop-amm `initialize` is skipped there (a plain keypair account, nothing of the declared id's to protect; `foreignDeploy.mjs` records it). The other 90 SDK refusal records are unchanged, 102 in all.

### Duplicate writable accounts and COption tags — measured 2026-10-10

Same reference, ids, builder and replay command as above, `BENCH_REFUSALS=1 anchorBench.mjs` over the five fixtures, 0 failures before and after, every success state identical. The check is one byte compare of the record's marker in each writable proof; a `Mutable` or `ExternalMutable` pays nothing on success because it already read that byte. SDK B and instruction CU before to after:

| Fixture | SDK B | instruction CU |
|---|---|---|
| hello | 4552 to 4616 | 1657 to 1662 |
| vault | 3992 to 4112 | 1769 to 1773; 521 to 526 |
| nested | 8088 to 8184 | 3181 to 3188; 653 to 655; 645 to 647 |
| prop-amm | 5568 to 5664 | 143 to 145; 1550 to 1555; 166 to 168 |
| multisig | 15336 to 15728 | 2987 to 2992; 2491 to 2497; 634 to 666; 2994 to 3000 |

A bitvec in the runtime context, as the reference keeps, cost 4 CU on every instruction in `msSolParse` before any check ran (hello 1657 to 1661 with the checks stubbed out) and 6 to 47 CU more with them; the marker byte avoids both. Not measured: why multisig `set_label` rises 32 CU where the others rise 2 to 7 (its label copy loop is the only data-dependent code), a duplicate on the SBF target (the pins run on the host simulator).

A field declared `WritablePda` with a bare `@bump` keeps the canonical bump the declared seeds
check found (`foundBump()`), and `createPda` on it signs with that bump without searching again:
escrow `make` 20,620 / 19,621 CU and 26,544 B against 20,611 / 19,612 CU and 26,560 B with the
hand derivation it replaced.

### Dispatch-first account walk — measured 2026-10-10, rejected

A port of the reference's account walk (lang-v2 `dispatch.rs:85-135` `run_handler`, `cursor.rs:100-175`
`walk_n`): no walk at entry, `accounts<T>()` walks exactly its field count, and an index past it
walks on lazily. Same build and bench as the table above:

| variant | bytes | CU |
|---|---|---|
| inline walk + lazy continuation | +584 … +2192 | +2 … +83 |
| noinline walk | +456 … +1104 | +7 … +89 |

The entry walk was not the cost: the table stays on the stack in both shapes, so moving the walk
saves nothing, and each `accounts<T>()` site pays its own walk code. The reference's gain comes
from per-handler views with no table and no per-field index lookup, which would rewrite every
`*ProofFailure`, `account(i)` and `signer(i)`; not attempted.

### Lifecycle and surface checks — measured 2026-10-10

Reference: `lang-v2/src/cpi.rs:437-478` (`create_account_with_signers`: payer == target is InvalidArgument, `CreateAccountAllowPrefund` tops up only the shortfall), `lang-v2/src/accounts/slab.rs:916-960` (`close`: destination writable, `0xff` over the discriminator), the MagicBlock SDK `rust/sdk/src/utils.rs` `create_pda` and `cpi.rs` `delegate_account_inner` (the buffer is created with 0 lamports, or allocated and assigned when it already holds some). What changed, each with a test red before the change:

- `delegateAt` creates its buffer through `createAccountAllowPrefund` with a required balance of 0, so one lamport sent to the `["buffer", delegated]` address no longer makes the System program refuse the create (`magicblock.ms`). The buffer is created by instruction 13, whose accounts are the buffer alone, where it was instruction 0 with the payer.
- `delegateAt` refuses an `ownerProgram` that is not this program (IncorrectProgramId) and a delegated account owned by neither this program nor System (3007) before the first write; `undelegate` refuses an `ownerProgramId` that is not this program.
- `createProgramAccount`/`createProgramAccountSeeded` refuse payer == target; `createdAccount` refuses a space below 8; `closedProgramAccount` refuses a read-only target or destination and a foreign target before it moves a lamport, and scrubs the discriminator.
- **Forged handles and proofs.** `Account`, `InstructionAccount` and `CpiAccount` no longer have public fields: privacy is per declaring module, so `core.ms` is the one place that builds them, from a record that exists (`accountAt`) and never from a raw address; a literal, `as`, an unassigned local or an array of empty slots outside it is a compile error (`solanaAccountForgeRefused.ms`). Hiding a name only from the barrel is not a boundary (`import ... from "std/solana/core"` resolves), which is why the fields carry the restriction. `writablePda` left the barrel and `typed.ms` exports no index-free door: it produced a `WritablePda` with bump 0 that `createPdaProven` signed with (`solanaWritablePdaDoorRefused.ms`). `createProgramAccountSeeded` takes no bump: it derives the canonical bump of the seeds and signs with it, and returns it (`solanaSeededBumpRefused.ms`, the host test in `test.ms`). `verifiedPdaWithBump` stays public: it checks the address against the seeds plus the given bump on a program-owned `Mutable<T>`, because a canonical check would remove the CU it exists to save; the limit is that a program-owned account at a non-canonical bump can only be created by a raw `signed(create(...), seeds)` the author writes. `cpi.cms` is merged into `core.ms` because the private fields made `cpi.cms` and `core.ms` import each other.
- `external<T>`/`externalMutable<T>` call `T.acceptsOwner`; a verifier type now declares it (`acceptsOwner(this typeof V, owner: Pubkey): boolean`), as `Mint` and `TokenAccount` already did.
- `@associated(mint, authority)` with a `Pubkey` mint is a compile error: the token program is read from the mint account's owner field.

`BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs`, the five fixtures against the `lang-v2` build, 0 failures before and after; `before` is the std of `775d96716` loaded by the same compiler, `after` this tree; the instruction CU:

| Fixture | before | after |
|---|---|---|
| helloworld | init 1589 | init 1577 |
| vault | deposit 1702, withdraw 490 | unchanged |
| nested | initialize 2954, increment 226, reset 218 | initialize 2911, increment 226, reset 218 |
| prop-amm | update 145, initialize 1505, rotate_authority 168 | update 148, initialize 1528, rotate_authority 171 |

Not measured: the CU of `delegateAt`, `undelegate`, `close` and `realloc` (no fixture calls them), the JS backend, any compiler but the one named, `--release`.

## 9. Compiler debt

A workaround the toolkit carries for a compiler gap is a row here, with its card under `~/metascript/.inbox/compiler/`; paying it back removes the workaround.

Carried since 2026-10-12, card `2026-10-12-macro-reads-a-declaration-by-name-at-the-call-site.md`: a macro is handed a declaration whose bases are names and whose decorator arguments are unbound syntax, so both can only be resolved where the macro is called.

- **Workaround:** `inheritedFirst` (`std/solana/typed.ms`, `std/solana/idl.ms`) refuses a base it cannot identify from the declaring module, which costs the import of each base at the call site and the three-module refusal of §3.
- **Still open, no workaround:** a decorator's arguments resolve at the call site. `@address(admin())` on a struct of `lib.ms`, read by `accounts<T>()` in a module that declares its own `admin()` and does not import lib's, passes `msc check --os=solana` (measured 2026-10-12, `./msc` of this tree) and compares against the caller's key; a method name in `@constraint(…)` behaves the same. An author keeps a decorator's free names imported, unshadowed, wherever `accounts<T>()` is called for the struct.

Before that the toolkit carried no compiler workaround (2026-10-09). The last two rows
were repaid:

Repaid 2026-10-09 on `msc-int` (this tree plus the landed fix that copies an
`@inline` generic's placed body into every caller module): `@inline` is back on the six
generic proof kernels, `program`, `owned`, `mutable`, `delegated`, `external`,
`externalMutable` and `readArgs`. `./msc-int test std/solana/test.ms` gives 29 files /
499 tests, including a third direct-call consumer (`testDirectCalls.ms`);
`accountValues.mjs` gives 16,905 cases, max valid 448 CU (was 464, cap 465); Hibernal std
`--danger` gives 44,272B / 20,801CU (was 49,928B / 21,425CU). The three Solana refusal
guards fire and the canonical IDL runs as real ESM. Not verified: anchorBench, escrow,
`--release`.

`singleAccountFailure` returns a bare replacement call: a macro replacement now owns its
type arguments, and the SDK macros (`selectLiteralInstruction`, `createPdaAt`,
`createPdaOf`, `readArgs`) pass explicit bound operands (`typExprArgs: [getTypeArg()]`).
An operand is spelled by a name visible at the call site, its own or an alias of the same
type; a private type with no visible name there is refused as an unresolved type. Same
`test.ms` 29 files / 499 tests and 448 CU on the lane candidate.

The bound VariableDecl gap (owned by `macro-typed-callee`, which closed
`name-to-symbol` without it) still exists in the compiler, but account expansion no longer declares locals using a hidden written
proof alias: kernels fill the account holder's typed fields directly. This keeps
checked field identity, avoids the unnecessary copy, and does not require an extra
caller import. The imported `Auth` and singleton/guarded-expression pins now pass.
Singleton shapes use a named generic Result routine, not an indirect closure call;
larger undecorated shapes keep an IIFE that returns Result without propagating an
internal `try` into a void caller. Failure code 0 remains failure through the
separate rejection bit; no proof factory became public.

Measured 2026-10-07 on `msc-stable`, branch base `a8c13b710` plus the pending SDK
diff (`typed.ms` blob `56f5c7f2658a76b52cff504dd8e520dfc125ec9f`):
`./msc-stable test std/solana/test.ms` gives **28 files / 472 tests passed**, including
cross-module Program/Owned variants, hidden aliases, expression guards and zero-code
failures. `./msc-stable build tools/solana/accountValuesProbe.ms --os=solana --danger
--output=<program.so>` then `node tools/solana/accountValues.mjs <program.so>` gives
**16,905 cases passed, max valid464 CU**, within unchanged cap465. That is +6 CU
against the preceding458 candidate, not a free workaround. Removing generic inline
annotations across the family is necessary for the repeated direct-call variants;
a narrower scratch version reached444 CU but failed those variants and was rejected.
Private-factory/forged-proof/pointer and layout refusal guards also passed their
expected-diagnostic checks (`/tmp/borsh/verify-guards.mjs`).

The actual Hibernal-shaped replay was then remeasured with separate work dirs:
`node tools/solana/accountTableCost.mjs --msc <installed-or-candidate> --form
std|chain --suite hibernal --danger --work <directory>`. Installed8506 std gives
**52,248B / 21,412CU**; this SDK candidate **49,928B / 21,425CU** (idle93 in both).
Against the preceding46,696B/21,396 candidate this adds3,232B/29CU, so the
workaround restores correctness but gives back some size/CU progress; not a
universal win or a matched Anchor-v2 comparison.

Main's sized-array fixes (`08bc06a4f`, `97e90b7d8`) were integrated as their
source hunks without rebasing the staged SDK. `./msc-integrated` was built from
349 modules with `--gc=drc --danger --lto=off`; compiler check372 modules was clean.
`./msc-integrated test std/solana/accountCodecTest.ms` passes **27 files/395 tests**;
adding `--target=js` passes **15 files/105 tests**, including the ed25519 dependency
that previously aborted. No dependency was skipped. A standalone C/JS matrix
(`/tmp/std-solana-goal-audit/sizedRoots.ms`) for imported/local const dimensions,
empty/partial arrays, independent struct defaults, Span reads and uint64 arrays
prints the same `sized 4 7 7 4 2 0`, `structs 2 0 9 1 0`, `wide 3 true`.
This integration does not implement general dimension expressions or prove the
previously recorded module-level-let limitation fixed. The full sized-array language pins were not verified here: running main's
files with `--target=js` used another tree's compiler/helper imports and reported79
type errors. No passing language-lane claim follows; the final gate must run
those pins on the integrated branch.

Not remeasured for this change: escrow/hello/vault size and CU, no-LTO cost,
Android devices, or the full gate. Installed BUILD8506eaf03 is unchanged; no
installed-candidate claim follows from these local runs.
The signed-division target-cost policy remains at `arithmetic.ms` and §6 (card
`2026-09-27-solana-signed-division-is-a-170-cu-libcall.md`); it is separate from these
new annotation/inline blockers, not a newly verified root-compiler fix.

### Canonical IDL alias query — measured 2026-10-09

`meta.sameType` now peels bound transparent aliases in `src/compiler/meta/typeQuery.ms`
`hostSameType`; IDL classification compares canonical types, not user-written names.
Measured on committed tree `31ab71acd190b9af4979b4da724ad13b849308da` plus the pending
source inventory, with candidate SHA256
`51345d7ab25a17eee85a198fd8fa333d4899f8fbeb105e03f05652c1ab787ce2`:
`./msc-entry-proto build src/index.ms --gc=drc --danger --lto=off --output=msc-meta-alias`
built 349 modules. `./msc-meta-alias test src/test/lang/metaTransparentAliasEqualityParked.ms`
gives C **301 passed** and, with `--target=js`, **64 passed**, including three focused
alias/scalar/nominal-boundary assertions. The prior compiler gave C300/1fail and
JS63/1fail. `./msc-meta-alias test std/solana/test.ms` gives **29 files / 498 passed**;
its logs name this checkout's std, not installed support.

Building and running `src/test/guard/fixtures/solanaCanonicalArgumentIdl.ms` natively
produces exact `pubkey`, `pubkey[0]`, `pubkey[1]`, hidden `pubkey[2]` and hidden `bytes`
IDL fields. `./msc-meta-alias check --error-max=0 src/test/guard/solanaIdlTypeNamesRefused.ms`
refuses all four same-named fake Pubkey/Bytes scalar/array declarations at lines15–18.
Actual Node ESM of the canonical fixture still fails before execution:
`SyntaxError: Identifier 'msSized_2qo35eEq' has already been declared`.

This ESM failure is a source-baseline limit, not evidence of failed alias comparison:
the candidate lacks landed fix `9603399aa`, which owns equality helpers program-wide
in a bundle (`destructorLifting.ms` `claimEq`, `compile.ms` `cmdBuildJS`). A matched
portable three-module control, both providers comparing `uint8[32]`, emits two helpers
with this candidate and fails in Node; installed BUILD717769655, binary SHA256
`79e1b8003c862a8cc556e7a6a1860d59a1a2fe96790e73d07f1aa5532f4d5c28`, emits one and
prints `true true`. Both use `build --target=js --gendeps --output=<file.mjs>` followed
by `node <file.mjs>`. This control does not establish installed SDK acceptance.

Evidence: `out/solana/goalAudit/parallelInline/metaAlias/` `commands.json`,
`resume-final-provenance.json`, `parent-root-trace.json`, `sized-control-inputs.json`
and `parent-evidence-manifest.json`; parent verified all 4709 source inputs identical
before/after/current, candidate/bootstrap hashes and named logs. No combined-green,
known-red/gate, scalar-array SBF, annotation-restoration, installed canonical SDK,
size/CU or delivery claim follows. Pins remain parked pending registration coordination;
no output patch, consumer header, annotation removal or CJS fallback was used.

### CU pass on stored-bump folds, owned finds, one rent read and create copies — measured 2026-10-10

`--os=solana --danger`, LiteSVM 1.4.1, the five anchorBench programs at their ids, `BENCH_REFUSALS=1`: 0 failures, 102 refusals with unchanged error and unchanged accounts. Instruction CU before then after (Anchor v2 in parentheses): hello init 1615 to 1580 (1441); vault deposit 1701 to 1697 (1602), withdraw 476 (418); nested initialize 3133 to 2947 (2840), increment 593 to 224 (866), reset 585 to 216 (861); prop-amm update 143, initialize 1505 to 1482 (1398), rotate 166; multisig create 2926 to 2899 (2762), deposit 2399 to 2395 (2292), set_label 599 to 522 (621), execute 2866 to 2844 (2991).

- A stored bump on literal seeds compares the key with the folded address and the stored bump with the folded bump: nested increment and reset lose both `sol_sha256` calls. `solanaSeedsFoldedStored.ms` runs the canonical account, another stored bump, a key one bit off, the address of other seeds, a lower bump's off-curve address, a foreign owner and a program run at another id.
- A bare `@bump` or `pda` on an `Owned` or `Mutable` field finds with `msSolFindExpectedAddress`: the matching hash skips the curve check, every higher bump keeps it. A `Mutable` with a non-literal seed: 488 to 314 CU (one `Mutable` field with seeds `"safe"` and the signer, four owners). No bench program checks such a field: the vaults are `Writable`, which proves no owner, so `canonicalBump` on them keeps the curve check.
- `seedsGivenProvenFailure` omits the owner compare for `Owned` and `Mutable` fields: the field's proof (`mutableProofFailure`, `programDataFailure`) compares the owner earlier in the same expansion. multisig set_label 599 to 573, execute 2866 to 2848.
- The rent words live in the instruction's context (zeroed per instruction, `host.c` resets them per run), so the second create reads no sysvar: nested initialize 3021 against 3133. A single create pays 2 CU for the cache test.
- `initialized` compares keys by address and passes the program id by address, the folded PDA address is four immediates and the System id is the rodata constant: hello 1617 to 1580, prop-amm initialize 1507 to 1482, nested initialize 3021 to 2947, multisig create 2928 to 2899.
- multisig set_label copies the label with `putPrefix` (one `sol_memcpy_`) after the unchanged `isUtf8` check: 573 to 522.

Not measured: a non-bench program that checks `Owned` or `Mutable` fields with non-literal seeds on the full table, `Delegated` fields (unchanged), a program run at another id with a PDA of the declared id that the declared program assigned to it (the folded checks, bare and stored bump, accept it).

### CU pass on the entry parse, account kernels, arguments, create and PDA — measured 2026-10-11

`--os=solana --release` (not `--danger`), LiteSVM 1.4.1, the five anchorBench programs at their ids, `BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs`, one compiler (built from this tree, `--gc=drc --danger --lto=off`) loading the std and runtime of each commit beside it. Base is `f421de59b`. Instruction CU after each commit, in order (Anchor v2 in the last column); 0 failures at every step, 102 refusals refused with unchanged state at every step, and at the last one the error string of all 102 is identical to the base run's:

| Fixture | base | entry parse | accounts kernels | arguments | create | PDA | writable word | Anchor v2 |
|---|---|---|---|---|---|---|---|---|
| hello init | 1578 | 1568 | 1545 | 1544 | 1514 | 1514 | 1528 | 1441 |
| vault deposit; withdraw | 1702; 490 | 1692; 484 | 1688; 472 | 1684; 477 | 1684; 477 | 1652; 468 | 1649; 456 | 1602; 418 |
| nested initialize; increment; reset | 2913; 226; 218 | 2899; 216; 208 | 2892; 197; 189 | 2891; 196; 188 | 2836; 196; 188 | 2836; 196; 188 | 2834; 196; 188 | 2840; 866; 861 |
| prop-amm update; initialize; rotate | 144; 1520; 167 | 138; 1510; 161 | 127; 1505; 150 | 123; 1504; 148 | 123; 1472; 148 | 123; 1472; 148 | 123; 1465; 148 | 81; 1398; 93 |
| multisig create; deposit; set_label; execute | 2922; 2401; 569; 2919 | 2900; 2387; 563; 2893 | 2881; 2377; 542; 2876 | 2873; 2373; 525; 2874 | 2749; 2373; 525; 2874 | 2739; 2353; 525; 2849 | 2749; 2348; 508; 2849 | 2762; 2292; 621; 2991 |

Program bytes, base to the PDA commit to the last one: hello 4048, 3696, 3872; vault 3784, 3464, 3872; nested 6112, 5808, 5848; prop-amm 5504, 5288, 5352; multisig 15392, 13976, 14480.

- **Entry parse.** `msSolStart(input, table, instructionData)` takes the loader's `input` as a parameter and parses the accounts in one loop with account 0 taken as a full record (the loader never sends a duplicate first); `msSolanaEnter()` no longer stores the input pointer, and the host parser `msSolParse` walks to the instruction data with the same `msSolInstructionDataOf` the entry uses when r2 is empty.
- **Accounts kernels.** `accounts<T>()` reads the table address and count once, compares the count with the field count once, and reads each `Signer`, `WritableSigner`, `Writable`, `Program<P>`, `Owned<T>` and `Mutable<T>` slot with a value-returning kernel `xProof(index, out failure)` (`std/solana/typed.ms`); the index verifiers (`signer(i)` and the rest) wrap the same kernels in a `Result`. A kernel gets its `Account` from `accountAt(index, out failure)` in `core.ms`, the only constructor of an `Account` outside the module that declares it: it yields a real record or a zero placeholder with a failure code, so a proof is never built from an address the author supplied. The kernels `accounts<T>()` uses call the inline address forms (`ownedAtFailure` and the rest); the public `owned<T>(i)`, `delegated<T>(i)` and `mutable<T>(i)` call the shared cores `ownedFailure`, `delegatedFailure` and `mutableEnvelopeFailure`, which return the `Account` and write the failure code (a kernel through those cores cost `accounts<Everything>` 60 CU more, 657 against 597). `programDataFailure` tests `length < 8 + size` once and a `@noinline` function picks the same code as before (3001, 3002 or 3003). `solanaGenericSize.ms` measured with this form: `owned` and `delegated` 9 copies of 208 bytes, `mutable` 9 of 240, `.text` 94,328 (86,528 on the previous tree), so its bounds are 256 bytes a copy for `owned` and `delegated` and 95,000 for `.text`. `checkCost.mjs`: `owned<Pet>` and `delegated<Pet>` 5 CU above the base, `accounts<Everything>` 6 below.
- **Arguments.** `argU8`/`16`/`32`/`64`, `argBoolValid` and `argPubkey` test the bounds once instead of building an address and testing it against zero; the instruction data length is the word before the data (the context field is gone).
- **Create.** `createAccountAllowPrefund` writes the owner as four words, `createPda` appends a one-byte slot to the seed list and `slottedSeeds` wraps the table in `SlottedSeeds`, a struct with private fields that `createdPdaAccount` takes: the found bump is written into the caller's own table, with no zeroed 16-entry table and no copy. A caller cannot hand `createdPdaAccount` an unslotted table, because nothing but `slottedSeeds` makes a `SlottedSeeds` and `solanaProofFailurePrivate.ms` requires that `std/solana` does not export it; a host test with a one-byte seed of its own checks that the slot is a separate entry.
- **PDA.** `canonicalBump` and `seedsCanonicalFailure` derive and compare in one C loop (`msSolFindCanonicalAddress`, bumps counted down from 255): the curve check at the matching bump stays, as in Anchor, and the codes are the old ones (2006 for another address, the find's code for too many seeds or no off-curve bump). `transfer` is `@inline`.
- **Writable word.** A `WritableSigner` whose marker, signer and writable bytes read as `0xff 1 1` in one word load skips the three byte checks; any other value takes the old checks, so the code is unchanged. It is its own commit because its value is small here: the 13 figures sum 22 CU lower with it than without (hello +14, multisig create +10, vault withdraw -12, multisig set_label -17, the rest -7 to 0) and the five programs are 1,192 bytes larger. Revert that one commit to drop it.
- **Checks run.** `std/solana/index.ms` 390 tests, `test.ms` 538, `idlTest.ms` 396, `accountCodecTest.ms` 402 and 109 on `--target=js`, the escrow's program and IDL and hello host tests; the 56 `solana*` guards (`GUARD_CLAIMS` selects them in `src/test/guard/run.ms`); `accountValues.mjs` 16,905 cases, `escrow.mjs`, `heapExhausted.mjs`; `checkCost.mjs` with every refusal code unchanged and every total lower than the table it carried (the one failing line, `instruction<Dispatch>`, fails the same way on the base: 167 CU above idle against 138), which is reset to the totals of the last commit (`idle` 179; the old 264 was stale).
- **Order change.** A missing account now wins over an earlier field's other failure (see §3). `BENCH_REFUSALS` has no case that has both, so its 102 records cannot show it.
- **Already red on the base.** `foreignDeploy.mjs after=<dir>` fails two assertions (nested `increment` and `reset`, "4 X's own accounts, call X", refused 2006) on the base and on this tree alike.

Not measured: `--danger`, platform-tools versions other than the one `msc` selected (not recorded), `delegateSeeds.mjs` (needs the delegation program dumped from mainnet), the JS backend for the `.cms` modules, programs with `Delegated`, `External` or `WritablePda` fields beyond what the escrow and `accountValues` exercise.

### Curve check skipped at the matching bump of a PDA that signs — measured 2026-10-11

The rule and its condition are in §4, Signing ("The curve check at the matching bump"). `--os=solana --release`, LiteSVM 1.4.1, the five anchorBench programs at their ids, `BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs`, the compiler built from this tree loading the std and runtime of `46147eebb` (before) and of this tree (after). 0 failures both ways, every success state identical; the 102 refusals of the base all refused with unchanged accounts and the same error string (102 of 102 compared by instruction and fault), and 4 new records (`oncurve-pda` for multisig `create` and `execute_transfer`, `oncurve-pda-at-rent` and `oncurve-pda-above-rent` for `create`), each `ProgramFailedToComplete` with the log `Could not create program address with signer seeds`, no `invoke [2]`, accounts unchanged, at bump 254 against a canonical 253.

| Instruction CU | before | after |
|---|---|---|
| hello init; vault deposit, withdraw; nested initialize, increment, reset; prop-amm update, initialize, rotate | 1528; 1649, 456; 2834, 196, 188; 123, 1465, 148 | unchanged |
| multisig create | 2749 | 2595 |
| multisig deposit | 2348 | 2366 |
| multisig set_label | 508 | 508 |
| multisig execute_transfer | 2849 | 2700 |

- `createPda` finds with `msSolFindExpectedAddress`: `checkCost.mjs` `createPda<Pet>` 1,851 to 1,682 CU over an idle instruction (the curve check is 159 of the 169; the other 10 are not attributed). The escrow's `make` is unchanged at 22,658 CU (its seeds are literals folded against the declared id).
- `execute_transfer` moves the find of the vault to the signed CPI, so a wrong vault is now refused after the threshold check, not before it: the 102 base refusals include a missing-signer `execute_transfer` that used to pay the find first (1,595 CU) and now stops at 563 CU, with the same error.
- multisig `deposit` is +18 CU with no change in its source or in the std (the same std with the old `executeTransfer` gives 2,348): `canonicalBump` has one call site left in the program and clang lays the loop out differently. Not investigated further.
- `canonicalBumpOwned` compares the owner itself, as `givenBumpOwned` does; its callers inside the std use `canonicalBumpProven`, whose owner the `Mutable<T>` proof has already compared, so they pay nothing. The compare costs 31 CU in a probe that calls each through a deep import (765 against 734 CU on a refused key). `seedsCanonicalOwnedFailure` took a key and compared no owner, so it is renamed `seedsCanonicalProvenFailure` like `seedsGivenProvenFailure`.
- Host: five signed-CPI tests of `test.ms` used seeds whose address is on the curve, which the simulator now refuses as the runtime does; their seeds are changed to off-curve ones (the vault's bump `[7]` to `[5]`, `[[7]]` to `[[6]]`, `"a"` to `"b"`, the sixteen-seed list starts at `[16]`). Red on the old std and host, on this compiler: 3 of the 9 new tests (`createPda` and `signedPda` on an on-curve target, a signer that hashes onto the curve).
- Checks run: `std/solana/index.ms` 390 tests, `test.ms` 547, `idlTest.ms` 396, `accountCodecTest.ms` 402 and 109 on `--target=js`, the escrow program and IDL, hello, `vrf.ms`, `token.ms`, `magicblock.ms`, `delegation.ms` and `src/test/c/solanaVaultHost.ms`; 81 guard cells (the `solana*` guards and the other probes that name `std/solana`) and the new `solanaSignedPdaRefused.ms`; `checkCost.mjs` with every refusal code unchanged; `escrow.mjs` and `accountValues.mjs` (16,905 cases) on both stds with identical output.

Not measured: a signer that is an on-curve address in a CPI to a program other than the System program (the runtime derives signers before any callee runs, read in `solana-program-runtime` 3.0 to 3.1.14, not replayed per callee); `signedPda` with a callee other than `transfer`; `--danger`; `delegateSeeds.mjs`; a find that needs many bumps on the host simulator; the JS backend.

### CU pass on the entry loop, the context, PDA staging and cold-edge sinking — measured 2026-10-12

`--os=solana --release`, LiteSVM 1.4.1, platform-tools v1.57, the five anchorBench programs at their ids, `BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs`. Base is `95ddecc7b` built by the installed compiler of that commit; "runtime" is this tree's merged bitcode compiled without the new flag, "this tree" with it. 0 failures; the 106 refusals are all refused with unchanged accounts, and each error string equals the base's (106 of 106 compared by instruction and fault through `BENCH_JSON`).

| Instruction CU | base | runtime | this tree | Anchor v2 |
|---|---|---|---|---|
| hello init | 1443 | 1440 | 1434 | 1441 |
| vault deposit; withdraw | 1631; 451 | 1625; 444 | 1621; 441 | 1602; 418 |
| nested initialize; increment; reset | 2768; 188; 183 | 2765; 182; 177 | 2762; 174; 171 | 2840; 866; 861 |
| prop-amm update; initialize; rotate | 104; 1397; 127 | 98; 1393; 121 | 93; 1390; 117 | 81; 1398; 93 |
| multisig create; deposit; set_label; execute | 2492; 2315; 486; 2609 | 2491; 2299; 471; 2610 | 2487; 2295; 466; 2604 | 2762; 2292; 621; 2991 |

Program bytes, base to this tree (Anchor v2): hello 2960 to 3024 (6400), vault 3096 to 3104 (5632), nested 5240 to 5304 (12256), prop-amm 3984 to 4088 (8448), multisig 11240 to 11192 (30496). Eight of the thirteen instructions are below the reference; vault deposit and withdraw, multisig deposit and prop-amm update and rotate are above it by 19, 23, 3, 12 and 24.

- **Entry loop.** `msSolParseAccounts` takes account 0 before the loop and tests the end after each store, so it never computes the address past the last record: the instruction data comes from the loader's second argument. The host parser `msSolParse` walks from the last record instead.
- **Context.** The SBF context holds `arenaUsed`, an offset that starts at 0 on the heap the loader zeroes, in place of an absolute position that `msSolanaEnter` stored at every entry; `msSolanaEnter` is gone. The program id is no field: `msSolProgramId` reads it behind the instruction data (the length word is at `data - 8`), two loads and an add at a use against a load, an add and a store at every entry.
- **PDA staging.** `msSolSeedStage` reads the caller's table through a typed pointer and copies a slice field by field. The integer address it used (`table + index * 16 + 8`) kept LLVM from forwarding a seed the caller had just written, and the struct copy was a `memcpy` that reloaded the length it had just checked (multisig create 2491 to 2487, execute 2612 to 2604 for the field copy alone). The find functions inline the staging into their caller and call a walk that takes the staged slices.
- **Cold-edge sinking.** `SBF_SINK_TO_COLD_EDGES` in `src/compiler/cc.ms`: LLVM's machine sinking leaves a constant that only a failing branch reads above the branch unless the edge is likely enough to be worth a new block; on SBF that is one instruction on every success path for each check. The table's last two columns are its effect: 3 to 8 CU an instruction, 8 to 48 bytes a program.

`node tools/solana/checkCost.mjs` on the default build (no `--release`), totals base to this tree: idle 176 to 174, `accounts<Everything>` 840 to 846, `createPda<Pet>` 2189 unchanged, `pda` 937 to 938 and 735 to 734 for a `Delegated<T>`, `instruction<Dispatch>` 344 to 326, `accounts<3 fields>` with `@seeds @bump` 884 to 886, the rest within 3; with `--release` 121 to 118, 595 to 599, 1705 to 1697, 698 to 681 and 509 to 489, 128 to 124, 681 to 665. Its table is reset to the default-build totals of this tree. The two seven-field structs that pin a `Delegated<T>` by `@seeds @bump` are the ones that rise, by 4 to 6 CU; the cause is not attributed (the program id read at each use is the suspect).

Rejected, each measured on the same five programs:

- **`noinline` canonical walk.** With `msSolWalkCanonical` kept out of line, a caller that is inlined into its handler stages literal seeds with no copy: vault 1601; 421, below the reference on deposit. A program that calls `seedsCanonicalFailure` from three sites keeps that function out of line and pays the second call: `accounts<Everything>` 595 to 611 with `--release` and 840 to 866 on the default build, where `checkCost.mjs` fails eight ops. Passing the program id into the walk to shrink the wrapper changed neither. The walk is left to the inliner; `noinline` on `msSolWalkExpected` cost multisig execute 25 CU and 296 bytes.
- **Account table in the heap.** The table as the arena's first allocation at a constant address (no `accountTable` field, no 2 KiB of entry frame): hello 1437 against 1434, multisig create 2496 against 2491 and execute 2617 against 2612, the rest within 2 either way.
- **Entry loop without the peeled first account** (a break in each arm, `slot == table` tested in the loop): 1 to 14 CU worse on every instruction; LLVM recomputed the table base and spilled the heap base.
- **Other code generator options**, tried on the merged bitcode: `-phi-elim-split-all-critical-edges`, `-enable-tail-merge=false` and `-tail-dup-size` changed nothing or lost; `-inline-threshold=500` changed nothing and 2000 helped only nested, for 304 bytes.

Why prop-amm update and rotate stay above the reference: its ELFs are built without a writable check on `mut` and without the duplicate-marker compare, about 4 CU of update; rotate paid about 15 for the `Pubkey` argument while `args<T>()` returned it in a `Result` whose payload started at offset 9, where the 32-byte copy split into seven loads and stores; with a one-value field of an anonymous object stored nowhere on C (2026-10-16, corpus `resultDiscriminantOnce`) the payload starts at 8, the key moves in four `ldxdw`/`stxdw` pairs and rotate is 88 CU in a 4,440-byte ELF, against 101 and 4,544 before and 93 for Anchor v2 (same `anchorBench.mjs` call, platform-tools v1.57, `--release`).

Checks run on this tree's candidate compiler: `std/solana/test.ms` 588 tests, `index.ms` 390, `vrf.ms` 402, `idlTest.ms` 396, `accountCodecTest.ms` 402, the escrow program and IDL and hello host tests; `accountCodecTest.ms` on `--target=js` 109; the 87 guard cells of the 65 `solana*` guards; `accountValues.mjs` (16,905 cases), `escrow.mjs`, `heapExhausted.mjs`; `src/compiler/cc.ms` tests.

Not measured: `--danger` (refused on `--os=solana`), platform-tools other than v1.57, a find that needs many bumps, `foreignDeploy.mjs` in this pass, a program the size of Hibernal's, where the count of `@seeds @bump` sites decides whether the inliner fuses the walk.

### CU pass on the entry parse, the borrow byte and constant placement; the resize bound; a Pinocchio baseline — measured 2026-10-12

Same build, harness and reference ELFs as the section above; "before" is `80207ca9c`. The Pinocchio column is `tools/solana/pinocchio/`: hand-written Pinocchio 0.11.2 programs for prop-amm and vault that make this std's checks in its order with its codes (list, build and versions in that README), run in the same `anchorBench.mjs` call. 0 failures with refusals on; the four variants of a suite end in equal states and `std` and `pinocchio` answer the same code in all 37 fault cases of the two suites.

| Instruction CU | before | this tree | Anchor v2 | Pinocchio, equal checks |
|---|---|---|---|---|
| hello init | 1434 | 1406 | 1441 | |
| vault deposit; withdraw | 1621; 441 | 1592; 423 | 1602; 418 | 1593; 404 |
| nested initialize; increment; reset | 2762; 174; 171 | 2722; 147; 144 | 2840; 866; 861 | |
| prop-amm update; initialize; rotate | 93; 1390; 117 | 77; 1367; 101 | 81; 1398; 93 | 91; 1375; 95 |
| multisig create; deposit; set_label; execute | 2487; 2295; 466; 2604 | 2467; 2266; 448; 2581 | 2762; 2292; 621; 2991 | |

Program bytes, before to this tree (Anchor v2; Pinocchio): hello 3024 to 3200 (6400), vault 3104 to 3344 (5632; 5544), nested 5304 to 5384 (12256), prop-amm 4088 to 4264 (8448; 6672), multisig 11192 to 11368 (30496). Eleven of the thirteen instructions are below Anchor v2; vault withdraw (5 above, 19 above Pinocchio) and prop-amm rotate (8 above, 6 above Pinocchio) are not. Pinocchio's lazy entrypoint measured worse than its eager one on all five instructions (update 103, rotate 108, withdraw 415).

Stacked in this order, each row the whole tree at that step (hello; vault; nested; prop-amm; multisig):

| step | CU |
|---|---|
| entry parse and its bound | 1420; 1609, 431; 2748, 162, 159; 81, 1376, 105; 2480, 2281, 456, 2597 |
| borrow byte, key compare, CPI flags (and the resize bound) | 1408; 1598, 427; 2725, 153, 150; 79, 1368, 103; 2468, 2269, 451, 2584 |
| constants at their use | 1406; 1592, 423; 2722, 147, 144; 77, 1367, 101; 2467, 2266, 448, 2581 |

- **Entry parse.** `msSolParseAccounts` takes accounts 1 to 3 at constant table slots before the general loop and leaves it at the first duplicate; Pinocchio's entrypoint unrolls its parse by the account count (`pinocchio-0.11.2/src/entrypoint/mod.rs:315-359`, `process_n_accounts`). Host and SBF share the function.
- **Its bound.** With the default table of 255 the parse refuses a larger count (`__builtin_trap`) in place of clamping: one branch against four instructions on every instruction, and the bound on the table no longer rests on the loader, which refuses such an instruction before the program runs (agave 3.1.14 `program-runtime/src/serialization.rs:235-238`). A smaller `MS_SOL_MAX_ACCOUNTS` keeps the clamp, so accounts past the table are still ignored. Without any bound update is 80 against 81; not taken.
- **Borrow byte.** Duplicate and claim state moved from the runtime's marker byte 0 to padding byte 4 (0 free, 1 claimed, 2 repeated). `WritableSigner` is `load32(record + 1) == 0x0101`, `Writable` and `Mutable` take `load32(record + 2) == 1` first and fall to the byte-wise checks, which name the failure, when it does not hold (an executable account, a claimed or repeated one, or one already resized). `Mutable` claims with one store after its envelope has proved the byte free.
- **Key compare.** `keysFailure` compares four words in place instead of calling `keysEqual`; it reaches `@hasOne` and `@address` (nested increment and reset).
- **CPI flags.** `msSolInvokeMetas` copies record bytes 1 to 4 into `SolAccountInfo`'s three flags and one byte of its padding with one load and store, as Pinocchio does (`solana-instruction-view-2.1.0/src/cpi.rs:137-142`). Leaving the flags and `rent_epoch` unwritten measured 16 CU a CPI on the previous tree and agave 3.1.14 never reads them (`program-runtime/src/cpi.rs`); not taken, the struct would hold uninitialised `bool`s on a runtime that was not read.
- **Constants at their use.** `SBF_KEEP_CONSTANTS_AT_USE` in `src/compiler/cc.ms` (`-csuses-threshold=0`): machine CSE folded equal error-code constants into the first one, which sits above the checks; kept apart, the sinking flag moves each onto its failing edge. No instruction rose.

**Resize bound (a fix, not a saving).** `Account.resize` counted its own growth and refused past 10,240, but a callee changes the length without moving that count: after a `createAccount` CPI for 48 bytes, `resize(10288)` returned ok on `80207ca9c` and zeroed the key of the account that follows in the input; after one for 10,240 bytes, `resize(20480)` zeroed that account's key and lamports as the program saw them (the runtime then failed the instruction with InvalidRealloc, so nothing reached the chain unless the program shrank the account again before returning). `resize` now also refuses a growth past the end of the account's record in the input (`msSolDataRoom`: the next record's address from the account table, less the duplicate slots and the rent epoch between, or the instruction data for the last account). The host simulator's System program had been moving the caller's count, which the runtime does not do, so host tests could not see it; it now bounds by the same room. Pin: `tools/solana/resizeAfterCpi.mjs` on `tools/solana/resizeProbe.ms`, in the gate's solana lane: three layouts (a record follows, a duplicate then a record, the instruction data) by four sizes, 24 checks, 14 of them red on `80207ca9c`; host variant in `std/solana/test.ms`. The room includes the record's alignment padding, so a growth by a callee and this program together may pass 10,240 by at most 7 bytes here and is refused by the runtime at exit. Pinocchio stores each account's length in the record's padding at entry for this (`sdk/src/entrypoint/mod.rs:294-299` at `0dace48`, feature `account-resize`), a load and a store an account on every instruction; the room costs nothing outside a growth.

`node tools/solana/checkCost.mjs` on the default build, totals before to this tree: idle 174 to 166, `mutable<Pet>` 269 to 259, `accounts<Everything>` 846 to 810, `accounts<3 fields>` 306 to 271 and with `@hasOne` 331 to 289, `accounts<7 fields> + @address` 877 to 833, `createPda<Pet>` 2189 to 2168, `close<Pet>` 433 to 426, `realloc<Pet>` 504 to 549: a growth pays the room, about 53. The table in `checkCost.mjs` is reset to these.

Rejected or not taken, each measured:

- **The peel as a `slot == end` loop**: update 86 against 84 before the bound was changed; a constant slot per iteration is what LLVM unrolls. Passing the context into the parse changed nothing.
- **`resize` in one function**: with the room test inline in `resize`, `close<Pet>` rose 19 (its `resize(0)` stopped being inlined); growth is now the out-of-line `grown`. The room helper inlined into it: 2 worse.
- **`+alu32` on the merged bitcode**: 70 CU over the thirteen on the previous tree (set_label 466 to 419), but it emits JMP32 instructions, which LiteSVM 1.4.1 runs and which were not checked against a validator.
- **Removing `llvm.lifetime` markers from the merged bitcode**: 25 over the thirteen in the analysis lane, not re-run; it needs a new build step.
- **The rent sysvar's address as an immediate through inline assembly**: 1 on a create.
- **A seed table hashed in place** (an analysis lane's prototype on the previous tree, not re-run: vault 1604; 422, multisig create 2462): three canonical rows of `checkCost.mjs` rose 4 to 7 and `WritablePda` was not converted. Taken in another form in the section below.

Where the rest is, by a tracer over the disassembly of both ELFs on the previous tree (written for the baseline, reconciled with the measured CU on twelve success paths, its attribution not re-derived): the PDA check of vault withdraw is 68 instructions against Pinocchio's 45 (the seed table is staged by the caller, then copied by `seedsCanonicalFailure`); rotate copies its `Pubkey` argument in seven pieces (compiler inbox `2026-10-12-result-payload-of-byte-alignment-sits-at-offset-9.md`); the exit is 6 to 10 instructions against 3 to 5 (the result and the rejection byte are read back from the context).

Checks run on this tree's candidate compiler: the host tests of the section above with `std/solana/test.ms` at 589; `src/compiler/cc.ms` tests; the 87 guard cells of the 64 `solana*` guards; `accountValues.mjs` (16,905 cases), `escrow.mjs`, `heapExhausted.mjs`, `resizeAfterCpi.mjs`; `checkCost.mjs` green on this tree and red on the build that kept `resize` in one function.

Not verified: a real validator and other validator clients (the byte-4 state rests on the runtime not reading record bytes 0 to 7 back, read in agave 3.1.14 `serialization.rs:594-603`; the one-word flag copy on its not reading `SolAccountInfo`'s padding); Pinocchio programs for hello, nested and multisig; error codes the bench has no fault case for (2040, 3001, 3003, 3008, 3009 on the Pinocchio side); `foreignDeploy.mjs`.

### PDA seeds hashed in the caller's table; the empty-r2 check ahead of the parse — measured 2026-10-12

Same harness, reference ELFs and Pinocchio programs as the section above, whose "this tree" is the first row. The second row adds the seed table on the same base; the third is this tree, rebased onto `a5d5faf08`, which brought the entry's walk for a runtime that leaves r2 empty. With refusals on the std variant fails no case; run beside the reference, the command prints four failures of the Anchor v2 variant in multisig's on-curve cases, as before.

| Instruction CU | hello | vault | nested | prop-amm | multisig |
|---|---|---|---|---|---|
| section above | 1406 | 1592; 423 | 2722; 147; 144 | 77; 1367; 101 | 2467; 2266; 448; 2581 |
| seed table in place | 1406 | 1577; 404 | 2722; 147; 144 | 77; 1367; 101 | 2444; 2266; 444; 2540 |
| this tree | 1406 | 1577; 404 | 2722; 147; 144 | 77; 1369; 101 | 2444; 2266; 444; 2540 |
| Anchor v2 | 1441 | 1602; 418 | 2840; 866; 861 | 81; 1398; 93 | 2762; 2292; 621; 2991 |
| Pinocchio, equal checks | | 1593; 404 | | 91; 1375; 95 | |

Program bytes in the same three steps: hello 3200, 3200, 3344; vault 3344, 3496, 3640; nested 5384, 5384, 5528; prop-amm 4264, 4264, 4424; multisig 11368, 11328, 11472. Twelve of the thirteen instructions are below Anchor v2 and vault withdraw equals Pinocchio; prop-amm rotate is 8 above Anchor v2 and 6 above Pinocchio (the `Result` payload copy, compiler inbox `2026-10-12-result-payload-of-byte-alignment-sits-at-offset-9.md`).

- **Seed table in place.** `slottedTable([...])` (`std/solana/accountSeeds.ms`) builds the seed list with three free slices after it and one byte for the bump, and `slottedSeeds` wraps it in `SlottedSeeds`. `msSolSeedStageInPlace` checks the count and every length with the `msSolSeedStage` the copied path uses, then writes the bump's slice, the program and the tag into the free slices: the hash reads the caller's own table, where the canonical check had copied it into a second one. The walks count in the byte the bump's slice names, so on success it holds the found bump and the seeds with the next slice are the signer table. `pda`, `pdaWithBump`, `createPda`, `signedPda`, `WritablePda` and the `@seeds` fields of `accounts<T>` go through it; `verifiedPda` and `verifiedPdaWithBump` take `SlottedSeeds`, which only `slottedTable` builds, so a call that passed `seedTable(...)` to them is written `pda(...)`. The copied path stays for a table that is not a literal list: `canonicalBump(account, Span)`, `findAddress`, `findExpected`, `createAddressWithBump`.
- **Refusals unchanged.** Sixteen seeds and a seed over 32 bytes answer `maxSeedLengthExceeded`, another address 2006 (`std/solana/test.ms`, the slotted table against the copied one); `seedsGivenFailure` compares the hash to the key and then curve-checks the key, where it derived, curve-checked and compared.
- **`checkCost.mjs`.** Totals, section above to this tree: `accounts<Everything>` 810 to 763, `createPda<Pet>` 2168 to 2102, `pda` 926 to 911 (Mutable) and 724 to 709 (Delegated), `pdaWithBump` 670 to 610 and 773 to 715, `@seeds @bump(account.field)` 545 to 494, `@seeds @bump` 852 to 814, `accounts<7 fields>` 833 to 786 with `@address` and 804 to 757 without. No row rose; the table is reset to these.
- **Vault bytes.** 152 more: the canonical find is inlined at both of vault's sites, where one `seedsCanonicalFailure` was shared.
- **Empty-r2 check.** As rebased, `msSolStart` kept the parse's last record live for the walk that finds the instruction data when r2 is empty: hello 1409, rotate 104, bytes 3416; 3688; 5576; 4552; 11512. `msSolInstructionDataOf(input)` walks the input from its start, so the check runs ahead of the parse as it did when the entry refused an empty r2: the two return to 1406 and 101, prop-amm initialize is 2 higher, and every program is 40 to 128 bytes smaller. The same walk after the parse measured update 79, initialize 1369, rotate 103.

Forms of the seed table rejected in the lane that wrote it, not re-run here: four free slices with the bump byte in the fourth (vault 1579; 406, the canonical rows of `checkCost.mjs` 5 to 10 higher); the canonical find out of line (vault 3408 bytes, 1584; 414); staging called from `core.ms` instead of `seed.ms` (multisig 11528 bytes, execute 2566); `canonicalBumpProven` as `@inline` (`solanaGenericSize` red: 696 bytes a copy against a bound of 256).

Checks run on this tree's candidate compiler: the host tests of the sections above with `std/solana/test.ms` at 590; the 87 guard cells of the 64 `solana*` guards; `accountValues.mjs`, `escrow.mjs`, `heapExhausted.mjs`, `resizeAfterCpi.mjs`; `checkCost.mjs` with every row at its total.

Not verified: a real validator; `magicblock.ms`, `delegation.ms` and `mint.ms` beyond their type-check and the host tests; the empty-r2 branch on SBF, which no check here runs (LiteSVM 1.4.1 sets r2, and `solanaEntryAccountTable.ms` reads the emitted entry): its walk is the one the host parser takes on every host test.

### Proofs taken by value in `accounts<T>()`; the check lanes — measured 2026-10-12

Same build and harness as the section above (`--os=solana --release`, LiteSVM 1.4.1, the five anchorBench programs at their ids, `BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs`, 0 std failures), one compiler per column built from that column's tree. "Before the compiler lanes" is commit `9e0c969e8` (the account-shape, token and host-simulator lanes merged, the checker and transform fixes not yet); "this tree" is tree `d98cdaec6f8d03752dd344dda894df6e3d05a478`.

| Instruction CU | hello | vault | nested | prop-amm | multisig |
|---|---|---|---|---|---|
| section above, "this tree" | 1406 | 1577; 404 | 2722; 147; 144 | 77; 1369; 101 | 2444; 2266; 444; 2540 |
| before the compiler lanes | 1411 | 1577; 404 | 2724; 147; 144 | 77; 1366; 101 | 2445; 2267; 445; 2541 |
| this tree | 1411 | 1578; 405 | 2724; 147; 144 | 77; 1366; 101 | 2445; 2267; 445; 2541 |
| Anchor v2 | 1441 | 1602; 418 | 2840; 866; 861 | 81; 1398; 93 | 2762; 2292; 621; 2991 |

- The read-before-assignment rule (`docs/LANG.md`, "Locals read before they are assigned") forbids filling a zero-built account struct field by field, so `accounts<T>()` now takes each proof by value from an adapter (`signerProof`, `ownedProof`, … in `std/solana/typed.ms`: a local, the old kernel, the return) and builds the struct once every proof passed. It names no field type where it is called. Cost: 1 CU on vault deposit and withdraw.
- Rejected: turning the kernels themselves around so they return the proof. `owned` and `delegated` then stop inlining (nine out-of-line copies of 200 bytes each) and guard `solanaGenericSize` goes red at `.text` 90384 against its 90000 bound; with the adapters it reads 86640. The cause in the inliner was not found.
- `node tools/solana/checkCost.mjs` on the default build, before the compiler lanes to this tree: `accounts<Everything>` 763 to 752, `accounts<3 fields>` 271 to 250, `accounts<7 fields>` with `@address` 786 to 777 and without 757 to 746 (745 with the exit after every field; the other placement was kept because every other row is equal or lower). The numbers of this tree were measured twice, the earlier ones once.
- Not attributed: which commits of the earlier lanes account for the 5 CU on hello and the 1 to 2 elsewhere.


### Refusals that no longer wrap, abort or continue — 2026-10-14
- **`logText(Bytes)`**: the `sol_log_` syscall refuses a line that is not UTF-8 (agave `syscalls/src/lib.rs` `translate_string_and_do`, `from_utf8` then `InvalidString`), which ended the instruction with ProgramFailedToComplete. The bytes are now validated first and an invalid line goes to `sol_log_data` (a `Program data:` line), so a program passing arbitrary bytes cannot abort. A `string` is UTF-8 by construction and keeps the direct path. Measured on LiteSVM, `tools/solana/logText.mjs`: 2 bytes 130 to 147 CU, 19 bytes 130 to 283 CU (validation, about 8 CU a byte), the probe 3,520 to 4,120 bytes.
- **`minimumBalance(dataLength): Result<uint64, ProgramError>`**: a length above 10 MiB (`MAX_PERMITTED_DATA_LENGTH`, `solana-system-interface` `lib.rs:22`) is `Err(InvalidArgument)`, an unavailable rent sysvar `Err(UnsupportedSysvar)`, and a rent rate above `2^64 / (2 * (10 MiB + 128))` `Err(ArithmeticOverflow)`; nothing is recorded through `failWith` and no `u64::MAX` stands in for the failure, so a wrapped value (`2^64 - 128` read as 0) cannot reach a balance check. `createProgramAccount`, `create<T>` and `resize` use the same function with `try`.
- **`createAccount`** tops up an address that already holds lamports (see above).
- **`failWith`** keeps the first error of the instruction, so a later `failWith` does not replace an earlier one.
- **`clock(): Result<Clock, ProgramError>`**: the clock sysvar syscall can fail, and then the call is `Err(UnsupportedSysvar)` instead of a zero `Clock` the handler would read as time zero. The reference sysvar readers return the same shape (Pinocchio `sdk/src/sysvars/mod.rs:36` `fn get() -> Result<Self, ProgramError>` at `0dace48`; `solana-sysvar-2.2.2/src/lib.rs:188`). A failed read stops the handler where `try` sits; `std/solana/test.ms` pins that no line after the read runs, for `clock()` and `minimumBalance()`. The success path costs 1 CU more for `clock()` and 398 CU fewer for `minimumBalance()` than the `failWith` form (LiteSVM 1.4.1, 100 reads, `heapProbe` ops 15 and 14). Author migration: `clock().unixTimestamp` becomes `(try clock()).unixTimestamp`, `minimumBalance(n)` becomes `try minimumBalance(n)`; the rent and clock are the only sysvar readers.
- **`requestRandomness`** pins what the VRF program itself checks (`ephemeral-vrf` `program/src/request_randomness.rs:60-78` at `52b103c`): the queue is writable and owned by the VRF program, the slot hashes account is `SLOTHASHES_ID`, and the system program account is `SYSTEM_PROGRAM_ID`.
