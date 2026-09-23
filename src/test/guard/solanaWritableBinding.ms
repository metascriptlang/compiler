// GUARD-OS solana
// GUARD-CHECK-FAIL solanaWritableBinding.ms:10:5
// GUARD-CHECK-FAIL fixtures/solanaComputedKnob.ms:2:14
// GUARD-CHECK-FAIL a module-level 'let' needs writable static storage
// GUARD-CHECK-FAIL is not a compile-time constant, so the binding needs writable static storage
// Under --os=solana a module binding that still needs writable storage after
// folding and DCE is FREESTANDING E02 at the binding, in the entry module and
// in an imported one; the SBF link would otherwise discard its .data.
import { SEED } from "./fixtures/solanaComputedKnob";
let counter: uint64 = 0;
import { logU64 } from "std/solana";
function bump(): void { counter = counter + SEED; logU64(counter); }
bump();
