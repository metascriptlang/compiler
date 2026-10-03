// Symptom: an exported `@delegate` whose base was imported from another module reported "Overloaded function 'key' has no implementation" at a use in a third module and "Overload signature for 'key' … not assignable" inside its own module; a generic delegate printed 0 on C and crashed on JS.
// Root cause: a local routine named like an imported one becomes the primary of the module's set with the imported routine as its overload, but decorators and `export` were applied to the set's last overload, so `@delegate` and the export landed on the imported base and the delegate stayed a bodiless signature.
// Fix: decorators and `export` apply to the symbol the declaration itself declares.
import { checkProjectDiagnostics, MapEntry } from "../helpers";

const ACCOUNT683 = `export struct Account { address: uint64; }
export function key(this a: Account): uint64 { return a.address * 2; }
`;

function diagnostics683(signer: string, mainSource: string, entryPath: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/account.ms", entrySource: ACCOUNT683 },
		{ entryPath: "src/signer.ms", entrySource: signer },
		{ entryPath: "src/main.ms", entrySource: mainSource },
	];
	return checkProjectDiagnostics(entries, entryPath).join("\n");
}

const SIGNER683 = `import { Account, key } from "./account";
export type Signer = distinct Account;
@delegate export function key(this s: Signer): uint64;
export function twice(s: Signer): uint64 { return s.key() * 2; }
`;

test "bug683: a delegate whose base is imported resolves at a use in another module" {
	const d = diagnostics683(SIGNER683, `import { Account } from "./account";
import { Signer, twice } from "./signer";
const s = ({ address: 21 } as Account) as Signer;
const n: uint64 = s.key() + twice(s);
`, "src/main.ms");
	assert d == "", d;
}

test "bug683: the delegate's own module calls it" {
	const d = diagnostics683(SIGNER683, `const unused: int32 = 0;\n`, "src/signer.ms");
	assert d == "", d;
}

test "bug683: a generic delegate whose base is imported resolves across modules" {
	const owned = `import { Account, key } from "./account";
export type Owned<T> = distinct Account;
@delegate export function key<T>(this o: Owned<T>): uint64;
`;
	const d = diagnostics683(owned, `import { Account } from "./account";
import { Owned } from "./signer";
const o = ({ address: 21 } as Account) as Owned<int32>;
const n: uint64 = o.key();
`, "src/main.ms");
	assert d == "", d;
}

test "bug683: the delegate needs its base in scope" {
	const d = diagnostics683(`import { Account } from "./account";
export type Signer = distinct Account;
@delegate export function key(this s: Signer): uint64;
`, `const unused: int32 = 0;\n`, "src/signer.ms");
	assert d.contains("@delegate 'key': no key(Account) to delegate to"), d;
}
