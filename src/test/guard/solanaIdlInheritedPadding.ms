// GUARD-CHECK-FAIL 'Pet' has 7 byte(s) of C padding before field 'xp'
// GUARD-CHECK-FAIL 'Deep' has 6 byte(s) of C padding before field 'xp'
// GUARD-CHECK-FAIL 'Stats' ends with 7 byte(s) of C padding
// A struct's inherited fields are laid out ahead of its own, and anchorIdl looks for C padding over all of them.
// RED MEANS: anchorIdl described a zero-copy account whose inherited fields put padding before a
// field, and a client that reads the fields back to back reads that field at the wrong offset.
import { Mutable, Signer } from "std/solana";
import { anchorIdl } from "std/solana/idl";

enum PetOp {
	Feed,
}

struct Tagged { level: uint8; }
struct Pet extends Tagged { xp: uint64; }

struct Ranked extends Tagged { rank: uint8; }
struct Deep extends Ranked { xp: uint64; }

struct Sized { might: uint64; }
struct Stats extends Sized { hearts: uint8; }
struct Hero { stats: Stats; level: uint8; }

struct FeedAccounts {
	owner: Signer;
	pet: Mutable<Pet>;
}

console.log(anchorIdl<PetOp>({ name: "pets", address: "", Feed: [FeedAccounts], accounts: [Pet], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<PetOp>({ name: "deep", address: "", Feed: [FeedAccounts], accounts: [Deep], events: [], errors: "" })); // GUARD-REFUSED
console.log(anchorIdl<PetOp>({ name: "heroes", address: "", Feed: [FeedAccounts], accounts: [Hero], events: [], errors: "" })); // GUARD-REFUSED
