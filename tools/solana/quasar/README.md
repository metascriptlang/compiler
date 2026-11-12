# Quasar column for the Anchor bench

Quasar (`blueshift-gg/quasar`, a zero-copy, `no_std` Solana framework with Anchor's surface)
ports of the five programs `tools/solana/anchorBench.mjs` runs: `helloworld`, `vault`,
`nested`, `propAmm`, `multisig`. Each is written from the Anchor v2 bench program of the
same name (anchor-next `ff0514b6`, `bench/programs/<suite>/anchor-v2`; prop-amm from
`tools/solana/checkedProp.rs`) in Quasar's own idiom, with Quasar's default checks, so the
column measures the framework as an author meets it. The numbers are in
`docs/STD-SOLANA.md`, section "Quasar as a comparison pillar".

## Build

One build at a time; `target/` stays out of the worktree.

```sh
cd <worktree>
for p in helloworld vault nested propAmm multisig; do
  CARGO_TARGET_DIR=/tmp/quasarBench/target cargo-build-sbf \
    --manifest-path tools/solana/quasar/$p/Cargo.toml \
    --tools-version v1.57 --arch v3 --sbf-out-dir /tmp/quasarBench/deploy
done
```

The first build fetches Quasar at the pinned revision and takes about 2.5 minutes on the
Mac; each later one takes seconds. Run the column beside the others with the `anchor`
encoding:

```sh
Q=/tmp/quasarBench/deploy
BENCH_REFUSALS=1 node tools/solana/anchorBench.mjs \
  helloworld:quasar:anchor:$Q/hello_world_quasar.so vault:quasar:anchor:$Q/vault_quasar.so \
  nested:quasar:anchor:$Q/nested_quasar.so prop-amm:quasar:anchor:$Q/prop_amm_quasar.so \
  multisig:quasar:anchor:$Q/multisig_quasar.so
```

## Versions

| what | version |
|---|---|
| quasar-lang | `b0de7db4cd271654a2dcf78807dd865e98e0b339` (master, 2026-07-13) |
| cargo-build-sbf | 4.1.0 |
| platform-tools | v1.57, `--arch v3` |
| resolved by `Cargo.lock` | solana-account-view 2.0.0, solana-address 2.5.0, solana-instruction-view 2.0.0, solana-program-error 3.0.1, solana-define-syscall 5.4.0, zeropod 0.3.6 |
| profile | `opt-level = 3`, `lto = "fat"`, `codegen-units = 1`, `overflow-checks = false` (the Anchor v2 bench profile) |
| bench | litesvm 1.4.1, `tools/solana/mainnetInactiveFeatures.json` |

Built from these manifests, the five ELFs are byte-identical to the ones measured: sha256
prefixes `8e85ff6e5964d3cb` (helloworld), `14d61462f7b6032b` (vault), `5ef2a08f0b45c00b`
(nested), `ad750700fec98bd1` (prop-amm), `e892a7a88fe4361e` (multisig).

## Why this shape

- **The wire is Anchor's.** Instruction discriminators are the eight-byte
  `sha256("global:<name>")` prefixes and account discriminators `sha256("account:<Name>")`,
  written as `discriminator = [..]`, because the harness sends Anchor tags and seeds
  accounts with Anchor's layout. Quasar's own default is a one-byte tag.
- **`MultisigConfig` is `fixed_capacity`.** Quasar's default `String`/`Vec` fields are
  dynamic; `fixed_capacity` turns `Vec<u8, 32>` and `Vec<Address, 10>` into zeropod
  `PodVec` with a two-byte length (`zeropod-0.3.6/src/pod/vec.rs`, `PodVec<T, N, PFX = 2>`),
  which is Anchor v2's `PodVec` layout: 398 bytes, the label length at 42, the signer count
  at 76. `[Address; 10]` is refused (`Address` arrays are not `ZcElem`).
- **No compile-time PDA.** Quasar master hashes every seeded address at run time with
  `sol_sha256` (`derive/src/seeds.rs` `verify`, `verify_existing`,
  `verify_existing_from_account`, calling `lang/src/pda.rs`), literal seeds included.
  anchor-next's `bench/programs/helloworld/quasar/program/Cargo.toml` pins the fork branch
  `chen-robert/quasar` `notdeghost/const-pda-seeded-accounts` (`ea4a8821`) for a
  compile-time fold; that commit is an ancestor of `b0de7db4`, yet `b0de7db4` hashes, so
  the fold did not survive on master. This column uses master; the fork was not built. It
  weighs on helloworld and nested, whose seeds are all literals.
- **A prefunded account is created with two System calls.** The harness airdrops the
  prop-amm oracle keypair before `initialize`; Quasar's `init` then makes two System CPIs
  where the MetaScript program makes one (LiteSVM log, `invoke [2]` twice).
- **Duplicates.** Quasar's account parse compares the first four record bytes with one
  expected word (`lang/src/lib.rs` `parse_account`), so any repeated account is refused
  unless the field says `dup`; the MetaScript std allows a repeat between read-only fields.
- **Errors are Quasar's.** Custom codes where the Anchor v2 program has an error enum
  (multisig 6000, 6002, 6003; prop-amm 102, 105 as in `checkedProp.rs`); everything else is
  whatever Quasar answers, so codes differ from the other columns.
