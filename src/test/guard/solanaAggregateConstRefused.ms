// GUARD-OS solana
// GUARD-CHECK-FAIL solanaAggregateConstRefused.ms:12:7
// GUARD-CHECK-FAIL is not a compile-time constant, so the binding needs writable static storage
// Loosening the aggregate gate must not swallow the refusal: a `const` aggregate
// with a run-time initializer still needs writable static storage and stays
// FREESTANDING E02 (NIM-REF CK-120: a non-folding `const` is a Nim `let`).
// RED MEANS: moduleBindingNeedsWritableStorage accepted a non-constant aggregate.
import { logU64 } from "std/solana";

function seed(): uint8 { return 3; }

const COMPUTED: uint8[2] = [seed(), 1];

function main(): void { logU64(COMPUTED[0] as uint64); }
main();
