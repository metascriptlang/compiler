// GUARD-CHECK-FAIL anchorIdl: field 'inner' of 'EarlyHolder' has type 'EarlyInner', and where anchorIdl is called 'EarlyInner' means another type, 'EarlyInner' of
// GUARD-CHECK-FAIL anchorIdl: field 'inner' of 'LateHolder' has type 'LateInner[2]', and where anchorIdl is called 'LateInner' means another type, 'LateInner' of
// GUARD-CHECK-FAIL anchorIdl: field 'inner' of 'TwinHolder' has type 'TwinInner', and where anchorIdl is called 'TwinInner' means another type, 'TwinInner' of
// GUARD-CHECK-FAIL anchorIdl: field 'inner' of 'DeepMiddle' has type 'DeepInner', and where anchorIdl is called 'DeepInner' means another type, 'DeepInner' of
// GUARD-CHECK-FAIL anchorIdl: field 'mode' of 'ModeHolder' has type 'Mode', and where anchorIdl is called 'Mode' means another type, 'Mode' of
// GUARD-CHECK-FAIL anchorIdl: field 'flags' of 'FlagHolder' has type 'BitSet<Flag>', and where anchorIdl is called 'Flag' means another type, 'Flag' of
// GUARD-CHECK-FAIL anchorIdl: field 'inner' of 'Moved' has type 'MovedInner', and where anchorIdl is called 'MovedInner' means another type, 'MovedInner' of
// GUARD-CHECK-FAIL anchorIdl: account 'vault' holds 'Owned<KeyVault>', and where anchorIdl is called 'KeyVault' means another type, 'KeyVault' of
// GUARD-CHECK-FAIL anchorIdl: account 'vault' holds 'Mutable<RoundVault>', and where anchorIdl is called 'RoundVault' means another type, 'RoundVault' of
// GUARD-CHECK-FAIL import the 'EarlyInner' the field was declared with under that name, or call anchorIdl in the module that declares the field
// anchorIdl describes a field whose type is a struct or an enum from that type's declaration, and
// a seed that names a field of an account's data from the data struct's declaration; it finds
// both by the name the field was written with, where anchorIdl is called. It reads a declaration
// only when the name means there the type the field holds. Each call below describes a struct of
// another module while this module declares the name of one of its field types: a struct ahead
// of the import, a struct after the call under an array, a struct with the same fields beside
// the real one imported under another name, a struct two levels down, an enum with other values,
// an enum with more members under a BitSet, a struct under an event, and the data struct of an
// account that a key seed and an integer seed read.
// RED MEANS: anchorIdl described a field with the layout of a type it does not hold, or a
// program address with seeds the program does not derive it from, and a client built from the
// IDL reads the data at the wrong offsets or sends the wrong account.
struct EarlyInner { a: uint32; b: uint32; }

import { Pubkey, Signer } from "std/solana";
import { anchorIdl } from "std/solana/idl";
import {
	DeepHolder, DeepMiddle, EarlyHolder, FlagHolder, KeyTake, LateHolder, ModeHolder, Moved, RoundTake, TwinHolder,
	TwinInner as RealTwin,
} from "./fixtures/solanaShadowedIdlTypes";

enum Op { Read }

struct TwinInner { a: uint64; }
struct DeepInner { a: uint8; b: uint8; }
enum Mode { Idle = 0, Busy = 70000 }
enum Flag { First, Second, Third, Fourth, Fifth, Sixth, Seventh, Eighth, Ninth }
struct MovedInner { a: uint8; }
struct KeyVault { owner: uint64; round: uint64; }
struct RoundVault { owner: Pubkey; round: uint8; }
struct Plain { owner: Signer; }

function twinSize(): int32 { return sizeof(RealTwin) as int32; }

console.log(anchorIdl<Op>({ name: "early", address: "", Read: [Plain], accounts: [EarlyHolder], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "late", address: "", Read: [Plain], accounts: [LateHolder], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "twin", address: "", Read: [Plain], accounts: [TwinHolder], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "deep", address: "", Read: [Plain], accounts: [DeepHolder], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "mode", address: "", Read: [Plain], accounts: [ModeHolder], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "flag", address: "", Read: [Plain], accounts: [FlagHolder], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "moved", address: "", Read: [Plain], accounts: [], events: [Moved], errors: "" }));
console.log(anchorIdl<Op>({ name: "key", address: "", Read: [KeyTake], accounts: [], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "round", address: "", Read: [RoundTake], accounts: [], events: [], errors: "" }));
console.log(twinSize());

struct LateInner { a: uint32; b: uint32; c: uint64; }
