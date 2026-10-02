// @stdout: signer=42 inModule=84 owned=42,42
// note: `@delegate` routines declared in a module that imports their base from another module, called from a third module, from inside their own module, and as a generic delegate instantiated for two type arguments. Same output on every backend.

import { Account } from "./lib/account";
import { Signer, Owned, twice } from "./lib/proof";

function main(): void {
	const raw: Account = { address: 21 };
	const s = raw as Signer;
	const a = raw as Owned<int32>;
	const b = raw as Owned<string>;
	console.log(`signer=${s.key()} inModule=${twice(s)} owned=${a.key()},${b.key()}`);
}

main();
