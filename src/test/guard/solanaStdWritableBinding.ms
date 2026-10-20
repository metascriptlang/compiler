// GUARD-OS solana
// GUARD-CHECK-FAIL solana/writableBindingFixture.ms:1:7
// GUARD-CHECK-FAIL solana/writableBindingFixture.ms:2:5
// GUARD-CHECK-FAIL is not a compile-time constant, so the binding needs writable static storage
// GUARD-CHECK-FAIL a module-level 'let' needs writable static storage
// A std module's binding that needs writable storage is FREESTANDING E02 at the binding once
// SBF code reaches it, as in a user module: a string const and a let.
// RED MEANS: std is exempt from E02 again, and the debug link fails with
// "relocation refers to a symbol in a discarded section" instead.
import { logU64 } from "std/solana";
import { countCall, tagLength } from "std/solana/writableBindingFixture";

logU64(tagLength() + countCall());
