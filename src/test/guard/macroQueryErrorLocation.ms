// GUARD-CHECK-FAIL refuseTypeArg: the type argument is refused here
// GUARD-CHECK-FAIL macroQueryErrorLocation.ms:24:
// GUARD-CHECK-FAIL macroQueryErrorLocation.ms:25:
// GUARD-CHECK-FAIL macroQueryErrorLocation.ms:26:
//
// A refusal raised on a node that a macro's getTypeArg, getTypeImpl or
// bindSym made points at the macro call in the caller's file.
//
// A source location carries no file, so a node the macro's own source would
// place is placed at the call, as every other node a macro makes already is.
// RED MEANS the refusal names the line and column of the query inside the
// macro's module, printed under this file's path.

import { refuseTypeArg, refuseNamedImpl, refuseBound } from "./fixtures/macroQueryRefusals";

struct Thing { size: int32; }

function main(): void {
	const thing: Thing = { size: 3 };
	const other: Thing = { size: 4 };
	const third: Thing = { size: 5 };
	console.log(thing.size + other.size + third.size);
	const total = thing.size;
	refuseTypeArg<Thing>(thing);
	refuseNamedImpl(other);
	refuseBound(third);
	console.log(total);
}
main();
