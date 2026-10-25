// GUARD-OS solana
// GUARD-CHECK-FAIL in instantiation of 'scratchAddress<Named>'
// GUARD-CHECK-FAIL in instantiation of 'scratchAddress<Listed>'
// GUARD-CHECK-FAIL in instantiation of 'scratchAddress<Held>'
// GUARD-CHECK-FAIL scratch<T>(count): T owns managed memory
// scratch<T> places T on the program heap, which nothing frees and no destructor reaches, so a T that owns
// a string, an array or a class instance would leak or alias it.
// RED MEANS: scratch accepts a type that owns managed memory.
import { ProgramError, failWith, scratch } from "std/solana";

struct Named { name: string; hp: uint32; }
struct Listed { rolls: uint8[]; }
class Pet { hp: uint32 = 0; }
struct Held { pet: Pet; }

function place(): Result<uint64, ProgramError> {
	const named = scratch<Named>(2); // GUARD-REFUSED
	const listed = scratch<Listed>(2); // GUARD-REFUSED
	const held = scratch<Held>(2); // GUARD-REFUSED
	return Result.ok((named.length + listed.length + held.length) as uint64);
}

function main(): void {
	const result = place();
	if (!result.ok) { failWith(result.error); }
}
main();
