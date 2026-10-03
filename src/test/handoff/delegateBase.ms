import { checkProjectDiagnostics, compileToCWithStd, MapEntry } from "../helpers";

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

test "delegateBase: a delegate whose base is imported resolves at a use in another module" {
	const d = diagnostics683(SIGNER683, `import { Account } from "./account";
import { Signer, twice } from "./signer";
const s = ({ address: 21 } as Account) as Signer;
const n: uint64 = s.key() + twice(s);
`, "src/main.ms");
	assert d == "", d;
}

test "delegateBase: the delegate's own module calls it" {
	const d = diagnostics683(SIGNER683, `const unused: int32 = 0;\n`, "src/signer.ms");
	assert d == "", d;
}

test "delegateBase: a generic delegate whose base is imported resolves across modules" {
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

test "delegateBase: the delegate needs its base in scope" {
	const d = diagnostics683(`import { Account } from "./account";
export type Signer = distinct Account;
@delegate export function key(this s: Signer): uint64;
`, `const unused: int32 = 0;\n`, "src/signer.ms");
	assert d.contains("@delegate 'key': no key(Account) to delegate to"), d;
}

test "delegateBase: a missing base names delegation, not borrowing" {
	const result = compileToCWithStd(`
struct Account { address: uint64; }
type Signer = distinct Account;
@delegate function tag(this s: Signer): uint64;
`);
	assert !result.ok;
	if (!result.ok) {
		assert result.error.indexOf("no tag(Account) to delegate to", 0) >= 0, result.error;
		assert result.error.indexOf("borrow", 0) < 0, result.error;
	}
}
