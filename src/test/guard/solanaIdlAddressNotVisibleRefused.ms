// GUARD-CHECK-FAIL @address(HiddenProgramId) names a constant that is not visible where anchorIdl is called
import { Account, address } from "std/solana";
import { anchorIdl } from "std/solana/idl";

enum Op { Read }

struct ReadAccounts {
	@address(HiddenProgramId) program: Account;
}

console.log(anchorIdl<Op>({ name: "hidden", Read: [ReadAccounts], accounts: [], events: [], errors: "" }));
