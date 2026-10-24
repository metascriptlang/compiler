// GUARD-CHECK-FAIL args<T>(): field 'kind' is not a sized integer
// GUARD-CHECK-FAIL emit<E>(value): field 'kind' is not fixed-size plain data
// GUARD-CHECK-FAIL has no IDL type
// An instruction argument and an event field cross to a client as Borsh, where an enum is the
// position of a variant in a list the IDL would have to carry; the program holds the member's
// value. args<T>(), emit<E>() and the IDL's arguments refuse an enum field, so neither side
// reads one number as the other.
// RED MEANS: an enum crossed to a client as a number the IDL does not describe, and an enum with
// explicit values decodes to another member there.
import { ProgramError, Signer, failWith } from "std/solana";
import { args, emit } from "std/solana/macro";
import { anchorIdl } from "std/solana/idl";

enum Op { Read }
enum Stage { Open = 1, Shut = 4 }
struct ReadAccounts { owner: Signer; }
struct Input { kind: Stage; }
struct Moved { kind: Stage; amount: uint64; }

function read(): Result<uint64, ProgramError> {
	const given = try args<Input>(); // GUARD-REFUSED
	return Result.ok(given.kind as uint64);
}

function log(): void {
	const moved: Moved = { kind: Stage.Shut, amount: 3 };
	emit<Moved>(moved); // GUARD-REFUSED
}

const result = read();
if (!result.ok) { failWith(result.error); }
log();
console.log(anchorIdl<Op>({ name: "staged", address: "", Read: [ReadAccounts, Input], accounts: [], events: [], errors: "" })); // GUARD-REFUSED
