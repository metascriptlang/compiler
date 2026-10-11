# Pinocchio baseline for the Anchor bench

Hand-written Pinocchio programs that make the checks of
`examples/anchorBench/propAmm/program.ms` and `examples/anchorBench/vault/program.ms`: the
same checks in the same order, the same error codes, the same account state. They give
`tools/solana/anchorBench.mjs` a third column, an SDK without a framework at equal checks.

## Build

One build at a time; `target/` stays out of the worktree.

```sh
cd <worktree>
for p in vault propAmm; do
  CARGO_TARGET_DIR=/tmp/pinoBase/target/eager cargo-build-sbf \
    --manifest-path tools/solana/pinocchio/$p/Cargo.toml \
    --tools-version v1.57 --arch v3 --sbf-out-dir /tmp/pinoBase/deploy/eager
  CARGO_TARGET_DIR=/tmp/pinoBase/target/lazy cargo-build-sbf \
    --manifest-path tools/solana/pinocchio/$p/Cargo.toml \
    --tools-version v1.57 --arch v3 --sbf-out-dir /tmp/pinoBase/deploy/lazy --features lazy
done
```

Copy `deploy/eager/{vault,prop_amm}_pinocchio.so` to
`out/solana/pinocchioReference/{vault,propAmm}.so` and the lazy pair to `vaultLazy.so`,
`propAmmLazy.so`. The unstripped ELFs with symbols stay under
`$CARGO_TARGET_DIR/sbpfv3-solana-solana/release/`.

`cargo-build-sbf --tools-version v1.57` re-links the rustup toolchain named `solana` to
v1.57; a later build without the flag links it back to the default.

## Versions

| what | version |
|---|---|
| cargo-build-sbf | 4.1.0 |
| platform-tools | v1.57: rustc 1.95.0-dev (ae660768a 2026-08-17), clang 22.1.2-rust-dev |
| pinocchio | 0.11.2, `default-features = false`, feature `copy` |
| pinocchio-system | 0.6.1 |
| resolved by `Cargo.lock` | solana-account-view 2.1.0, solana-address 2.9.0, solana-define-syscall 5.2.0, solana-instruction-view 2.1.0, solana-program-error 3.0.1, five8 1.0.0 |
| profile | `opt-level = 3`, `lto = "fat"`, `codegen-units = 1`, `overflow-checks = false` |
| bench | litesvm 1.4.1, `tools/solana/mainnetInactiveFeatures.json` |

## Checks

Every instruction first passes `dispatch`: data shorter than 8 bytes answers 100, an unknown
tag 101. The rest, in the order made:

| instruction | check | error | made in |
|---|---|---|---|
| prop-amm `update` | arguments hold 8 bytes | 102 | `update` |
| | two accounts | 3005 | `update` |
| | oracle owned by the running program | 3007 | `mutable_oracle` |
| | oracle data holds 48 bytes | 3001, 3002 or 3003 | `mutable_oracle`, `short_oracle` |
| | oracle discriminator | 3002 | `mutable_oracle` |
| | oracle writable | 2000 | `mutable_oracle` |
| | oracle named by no other slot | 2040 | `mutable_oracle`, `Slots::named_by_another_slot` |
| | oracle not borrowed, then claimed | AccountBorrowFailed | `mutable_oracle` (`try_borrow_mut`) |
| | authority signed | 3010 | `update` |
| | authority is `UPDATE_AUTHORITY` | 105 | `update` |
| prop-amm `rotate_authority` | arguments hold 32 bytes | 102 | `rotate_authority` |
| | two accounts, then the oracle checks of `update` | as above | `rotate_authority`, `mutable_oracle` |
| | authority signed | 3010 | `rotate_authority` |
| | stored authority is the signer | 6000 | `rotate_authority` |
| prop-amm `initialize` | three accounts | 3005 | `initialize` |
| | payer, then oracle: signed, named by no other slot, writable | 3010, 2040, 2000 | `writable_signer` |
| | system program key, then executable | 3008, 3009 | `initialize` |
| | payer is not the oracle | 4101 | `initialize` |
| | oracle not borrowed after the create | AccountBorrowFailed | `initialize` (`try_borrow_mut`) |
| vault `deposit` | arguments hold 8 bytes | 102 | `amount_of` |
| | three accounts | 3005 | `deposit` |
| | user: signed, named by no other slot, writable | 3010, 2040, 2000 | `writable_signer`, `writable` |
| | vault: named by no other slot, writable | 2040, 2000 | `writable` |
| | system program key, then executable | 3008, 3009 | `system_program` |
| | vault is the canonical address of `["vault", user]` under the running program | 2006, InvalidSeeds when no bump is off the curve | `canonical_vault` |
| vault `withdraw` | arguments, two accounts, user, vault and address as in `deposit`, without the system program | as above | `withdraw` |

## Why this shape

- **Duplicates are checked by hand.** The standard entrypoint gives a repeated account a copy
  of the first slot's view and marks nothing (`pinocchio-0.11.2/src/entrypoint/mod.rs`,
  `clone_account_view` and the duplicate branch of `deserialize`), so "named by no other slot"
  is a pointer comparison against every other slot (`eager::Parsed`). The lazy entrypoint
  reports `MaybeAccount::Duplicated(index)`, which `lazy::Walked` folds into a bit set.
- **The lazy build walks every account.** The check covers slots past the declared ones, and
  the lazy cursor reaches the instruction data only after the last account, so nothing is
  skipped; it is smaller, not cheaper.
- **The address is derived by a loop over `sol_sha256` and `sol_curve_validate_point`**, bump
  255 downward, first hash off the curve compared with the key. The SDK's
  `Address::find_program_address` is the `sol_try_find_program_address` syscall, priced by the
  runtime at 1500 CU for each bump tried (`create_program_address_units`,
  `solana-program-runtime-3.1.14/src/execution_budget.rs`); the loop costs 306 CU in syscalls when bump 255
  is canonical, as it is for the bench's user.
- **The oracle is borrowed with the checked `try_borrow_mut`**, the SDK's form of a claim; the
  vault accounts are not borrowed, as in the MetaScript program.
- **Checks the SDK adds that the MetaScript programs do not make:** `Transfer::invoke` and
  `CreateAccountAllowPrefund::invoke` refuse a borrowed account with AccountBorrowFailed
  (`pinocchio-system-0.6.1/src/instructions/transfer.rs`,
  `create_account_allow_prefund.rs`), four instructions in `deposit`; dropping the oracle
  borrow writes the marker back, one instruction.
- **Unsafe shortcuts:** slots are read unchecked after the count check; `Oracle` and the
  arguments are read through pointer casts; the bump byte is written through a raw pointer a
  shared slice also names; the lazy build uses `next_account_unchecked`,
  `instruction_data_unchecked` and `program_id_unchecked`.

## Measured

2026-10-12, one run, refusals on, LiteSVM, against the MetaScript ELFs of tree `a58824e60468`
(`propAmm.so` sha256 `fd26868fe853ee70`, `vault.so` `3c37b93b94f4d0a0`) and the Anchor v2
reference ELFs under `out/solana/v3Reference/deploy/`:

```sh
P=out/solana/pinocchioReference
BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs \
  prop-amm:anchor2:anchor:out/solana/v3Reference/deploy/prop_amm_v2.so \
  prop-amm:std:anchor:<propAmm.so> prop-amm:pinocchio:anchor:$P/propAmm.so \
  prop-amm:pinocchioLazy:anchor:$P/propAmmLazy.so \
  vault:anchor2:anchor:out/solana/v3Reference/deploy/vault_v2.so \
  vault:std:anchor:<vault.so> vault:pinocchio:anchor:$P/vault.so \
  vault:pinocchioLazy:anchor:$P/vaultLazy.so
```

| suite | variant | bytes | CU |
|---|---|---|---|
| prop-amm | anchor2 | 8448 | update 81, initialize 1398, rotate_authority 93 |
| prop-amm | std | 4088 | update 93, initialize 1390, rotate_authority 117 |
| prop-amm | pinocchio | 6672 | update 91, initialize 1375, rotate_authority 95 |
| prop-amm | pinocchioLazy | 5184 | update 103, initialize 1385, rotate_authority 108 |
| vault | anchor2 | 5632 | deposit 1602, withdraw 418 |
| vault | std | 3104 | deposit 1621, withdraw 441 |
| vault | pinocchio | 5544 | deposit 1593, withdraw 404 |
| vault | pinocchioLazy | 3576 | deposit 1599, withdraw 415 |

All four variants leave equal account states and refuse all 37 fault cases; `std`,
`pinocchio` and `pinocchioLazy` answer the same code in each. The bench has no case for 105,
6000, 2040, 3001, 3003, 3008, 3009, 4101, AccountBorrowFailed or InvalidSeeds.

Rejected: the first build compared a mutable account against the whole parsed slice in one
iterator chain and measured 98, 104, 419 and 1618 for update, rotate_authority, withdraw and
deposit. Comparing against the declared slots first and scanning the trailing ones in a
second loop gave the numbers above; that build also wrote `dispatch` as an `if` chain, which
left the order of the tag comparisons in the ELF unchanged.
