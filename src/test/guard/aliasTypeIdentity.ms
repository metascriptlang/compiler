// `type TA = Thing` must denote the SAME type as `Thing`, so the C backend
// emits one struct for both spellings. Nim's maybeAliasType wraps the target in
// a tyAlias node that keeps the alias's own sym, and every structural site
// peels it with skipTypes(abstractInst); MetaScript instead copied the target's
// shape into the alias placeholder, so each module that spelled the alias
// mangled a struct of its own.
//
// RED MEANS: a value crossing between the two spellings dies at
//   error: passing 'Thing__…DeclOms' to parameter of incompatible type
//          'Thing__…AliasOms'
// and the alias spelling loses every extension declared on the target.

import { exit } from "std/process";
import { Thing, mk } from "./fixtures/aliasIdentityDecl";
import { TA, viaAlias } from "./fixtures/aliasIdentityAlias";

function main(): void {
	const direct: Thing = mk(7);
	const alias: TA = mk(7);
	const chain: TA[] = [mk(1), mk(2)];
	if (viaAlias(direct) != 7) exit(1);
	if (viaAlias(alias) != 7) exit(1);
	if (direct.n != alias.n) exit(1);
	if (chain[0].n + chain[1].n != 3) exit(1);
	console.log("GUARD-OK");
}

main();
