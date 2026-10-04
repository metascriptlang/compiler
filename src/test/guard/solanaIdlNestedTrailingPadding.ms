// GUARD-CHECK-FAIL 'Stats' ends with 1 byte(s) of C padding
import { Mutable, Signer } from "std/solana";
import { anchorIdl } from "std/solana/idl";

enum PetOp {
	Feed,
}

struct Stats {
	might: uint16;
	hearts: uint8;
}

struct Pet {
	xp: uint64;
	stats: Stats;
	level: uint8;
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
