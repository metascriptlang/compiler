import { anchorIdl } from "std/solana/idl";
import { Pubkey } from "std/solana/pubkey";
import { Bytes } from "std/solana/bytes";

type HiddenKeys = Pubkey[2];
type HiddenBytes = Bytes;
struct Input {
	key: Pubkey;
	empty: Pubkey[0];
	one: Pubkey[1];
	two: HiddenKeys;
	bytes: HiddenBytes;
}
struct Accounts {}
enum Op { Read }
console.log(anchorIdl<Op>({ name: "canonical", Read: [Accounts, Input], accounts: [], events: [], errors: "" }));
