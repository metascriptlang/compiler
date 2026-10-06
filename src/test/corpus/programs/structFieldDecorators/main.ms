// @stdout: layout 1,2,3 7 11 | maker:@signer()@writable();config:@seeds(S"config",I mint)@bump(M config.bump);vault:@address(C Pubkey.systemProgram());tail:; | note:@label(S"x");plain:; | maker:signer,writable,;config:seeds,bump,;vault:address,;tail:;
// @exit: 0
// note: a decorator on a struct or interface field is metadata. The values keep the layout and behaviour of the plain declaration, and a macro in another module reads each field's decorator names and unevaluated argument syntax through the declaration (`getImpl`) and through the type view (`typExprFieldDecorators`).

import { Accounts, Plain, Note, Pair } from "./shapes";
import { viaDeclaration, viaShape } from "./reader";

const a: Accounts = { maker: 1, config: 2, vault: 3, tail: 4 };
const p: Plain = { maker: 1, config: 2, vault: 3, tail: 4 };
const pair: Pair<int32> = { first: 5, second: 6 };
console.log(
	`layout ${a.maker},${a.config},${a.vault} ${a.tail + p.tail - 1} ${pair.first + pair.second}`
	+ ` | ${viaDeclaration<Accounts>()} | ${viaDeclaration<Note>()} | ${viaShape<Accounts>()}`,
);
