// GUARD-CHECK-FAIL byte(s) of C padding before field 'xp'
import { Mutable, Signer } from "std/solana";
import { anchorIdl } from "std/solana/idl";

enum PetOp {
	Feed,
}

struct Pet {
	level: uint8;
	xp: uint64;
}

struct FeedAccounts {
	owner: Signer;
	pet: Mutable<Pet>;
}

console.log(anchorIdl<PetOp>({
	name: "pets",
	address: "",
	Feed: [FeedAccounts],
	accounts: [Pet],
	events: [],
	errors: "",
}));
