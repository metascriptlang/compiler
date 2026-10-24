// GUARD-CHECK-FAIL anchorIdl: 'EarlyChild' extends 'PinnedEarly', whose fields anchorIdl cannot read: 'PinnedEarly' names the struct 'PinnedEarly' of
// GUARD-CHECK-FAIL anchorIdl: 'LateChild' extends 'PinnedLate', whose fields anchorIdl cannot read: 'PinnedLate' names the struct 'PinnedLate' of
// GUARD-CHECK-FAIL anchorIdl: 'PinnedMiddle' extends 'PinnedRoot', whose fields anchorIdl cannot read: 'PinnedRoot' names the struct 'PinnedRoot' of
// GUARD-CHECK-FAIL anchorIdl: 'NamedChild' extends 'PinnedNamed', whose fields anchorIdl cannot read: 'PinnedNamed' names the struct 'Decoy' of
// GUARD-CHECK-FAIL anchorIdl: 'Borrowed' extends 'FarBase', whose fields anchorIdl cannot read: 'FarBase' names the struct 'FarBase' of
// GUARD-CHECK-FAIL anchorIdl: 'KeptChild' extends 'KeptBase', whose fields anchorIdl cannot read: 'KeptBase' names the struct 'KeptBase' of
// GUARD-CHECK-FAIL which may not be the base
// anchorIdl lists the accounts and the data fields a struct inherits from the base's declaration,
// which it finds by the base's name where it is called. It reads that declaration only when the
// name can mean one struct: anchorIdl is called in the module that declares the extending struct,
// or the struct the name finds is declared in that module under that name. Each call below finds
// another struct: one this module declares (ahead of the import, after the call, two structs up,
// under a data struct), another struct of the declaring module imported under the base's name,
// and the base itself when the declaring module imports it.
// RED MEANS: anchorIdl described a struct with the accounts or the fields of a struct it does not
// extend, and a client built from the IDL sends the wrong accounts or reads the data at the wrong
// offsets.
struct PinnedEarly { intruder: Writable; }

import { Pubkey, Signer, Writable } from "std/solana";
import { anchorIdl } from "std/solana/idl";
import { FarBase } from "./fixtures/solanaFarBase";
import {
	Borrowed, Decoy as PinnedNamed, EarlyChild, KeptChild, LateChild, NamedChild, PinnedLeaf, PinnedMiddle,
} from "./fixtures/solanaShadowedBase";

enum Op { Read }

struct PinnedRoot { intruder: Writable; }
struct KeptBase { owner: uint64; }
struct Plain { owner: Signer; }

console.log(anchorIdl<Op>({ name: "early", address: "", Read: [EarlyChild], accounts: [], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<Op>({ name: "late", address: "", Read: [LateChild], accounts: [], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<Op>({ name: "leaf", address: "", Read: [PinnedLeaf], accounts: [], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<Op>({ name: "named", address: "", Read: [NamedChild], accounts: [], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<Op>({ name: "borrowed", address: "", Read: [Borrowed], accounts: [], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<Op>({ name: "kept", address: "", Read: [Plain], accounts: [KeptChild], events: [], errors: "" })); // GUARD-REFUSED

struct PinnedLate { intruder: Writable; }
