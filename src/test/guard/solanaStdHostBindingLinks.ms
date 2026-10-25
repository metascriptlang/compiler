// GUARD-OS solana
// A std module whose writable bindings no SBF code reaches builds for SBF: E02 reports only
// the bindings the program keeps.
// RED MEANS: E02 reports a std binding that dead-code elimination drops.
import { logU64 } from "std/solana";
import { four } from "std/solana/writableBindingFixture";

logU64(four());
