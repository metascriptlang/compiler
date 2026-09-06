// `a === b` on a struct asks destructorLifting to generate `<Name>Eq` on demand,
// but ensureEq resolves <Name> through the CONSUMING module's symbol table. A
// struct whose name was never imported there is invisible to it, so the call was
// emitted with nothing defining it. The carrier channel (pendingCarrierEqs)
// already generates from the Type for synthesized Maybe<T> carriers, which have
// no symbol-table entry either — a never-imported struct is the same situation.
//
// RED MEANS: the link step dies at
//   undefined symbol: _PEq

import { exit } from "std/process";
import { mkP } from "./fixtures/structEqDecl";

function main(): void {
	const a = mkP(3);
	if (!(a == mkP(3))) exit(1);
	if (a == mkP(4)) exit(1);
	console.log("GUARD-OK");
}

main();
