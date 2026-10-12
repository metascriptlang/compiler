// GUARD-CHECK-FAIL anchorIdl: 'Guarded' extends 'Gate<Signer>', whose fields anchorIdl cannot read
// GUARD-CHECK-FAIL anchorIdl: 'Boxed' extends 'Box<Pubkey>', whose fields anchorIdl cannot read
// GUARD-CHECK-FAIL anchorIdl: 'FarDerived' extends 'FarBase', whose fields anchorIdl cannot read
// GUARD-CHECK-FAIL anchorIdl: 'FarKeptChild' extends 'FarKept', whose fields anchorIdl cannot read
// anchorIdl lists the accounts and the data fields a struct inherits ahead of its own, from each
// base's declaration. A base whose declaration it cannot read is refused: one with type
// arguments, and one declared in another module that is not imported where anchorIdl is called.
// RED MEANS: anchorIdl described a struct without the accounts or the fields it inherits, and a
// client built from the IDL sends the wrong accounts or reads the data at the wrong offsets.
import { Pubkey, Signer, Writable } from "std/solana";
import { anchorIdl } from "std/solana/idl";
import { FarDerived, FarKeptChild } from "./fixtures/solanaFarBase";

enum Op { Read }

struct Gate<T> { authority: T; }
struct Guarded extends Gate<Signer> { target: Writable; }

struct Box<T> { owner: T; }
struct Boxed extends Box<Pubkey> { limit: uint64; }

struct Plain { owner: Signer; }

console.log(anchorIdl<Op>({ name: "guarded", address: "", Read: [Guarded], accounts: [], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "boxed", address: "", Read: [Plain], accounts: [Boxed], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "far", address: "", Read: [FarDerived], accounts: [], events: [], errors: "" }));
console.log(anchorIdl<Op>({ name: "kept", address: "", Read: [Plain], accounts: [FarKeptChild], events: [], errors: "" }));
