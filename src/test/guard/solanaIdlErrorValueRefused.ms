// GUARD-CHECK-FAIL anchorIdl: error 'Below' of 'SignedFailure' has the value -1
// GUARD-CHECK-FAIL anchorIdl: errors 'Open' and 'Shut' of 'TwinFailure' have the same value 1
// anchorIdl lists each member of the error enum under the code 6000 plus its value, the code
// ProgramError.userError returns for it. A negative value gives a code below 6000, where the
// framework's own codes are, and two members of one value give one code.
// RED MEANS: anchorIdl listed a code under a name the program does not return it for, and a
// client reports the wrong error.
import { Signer } from "std/solana";
import { anchorIdl } from "std/solana/idl";

enum Op { Read }
struct ReadAccounts { owner: Signer; }

enum SignedFailure { Below = -1, Zero = 0 }
enum TwinFailure { Open = 1, Shut = 1 }

console.log(anchorIdl<Op>({ name: "signed", address: "", Read: [ReadAccounts], accounts: [], events: [], errors: SignedFailure }));
console.log(anchorIdl<Op>({ name: "twin", address: "", Read: [ReadAccounts], accounts: [], events: [], errors: TwinFailure }));
