// GUARD-OS solana --release
// GUARD-CHECK-FAIL solana/writableBindingFixture.ms:1:7
// GUARD-CHECK-FAIL is not a compile-time constant, so the binding needs writable static storage
// A --release SBF build refuses a std string const that SBF code reaches, as the debug build does.
// RED MEANS: std is exempt from E02 again; the build links only because LTO folds the string.
import { logU64 } from "std/solana";
import { tagLength } from "std/solana/writableBindingFixture";

logU64(tagLength());
