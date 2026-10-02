// @stdout: keys=14,21 bound=8,16 meta=7,2 generic=8 outer=10,15
// note: one hub star-exports four modules: two of them export an extension named `key` for different receivers, one exports a static and a free function both named `writable`, one a generic extension, and the hub itself imports `make` before star-exporting its module. A second hub star-exports the first. Every name reaches the importer through both hubs; same output on every backend.

import { Account, Signer, Meta, Mutable, make, twice, writable } from "./lib/hub";
import { Account as OuterAccount, Signer as OuterSigner } from "./lib/outer";

function main(): void {
	const raw: Account = { address: 7 };
	const s = raw as Signer;
	const m = raw as Mutable<Account>;
	const o: OuterAccount = { address: 5 };
	console.log(`keys=${raw.key()},${s.key()} bound=${make()},${twice()} meta=${Meta.writable(7).key},${writable(1)} generic=${m.data()} outer=${o.key()},${(o as OuterSigner).key()}`);
}

main();
