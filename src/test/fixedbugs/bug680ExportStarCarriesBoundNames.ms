// Symptom: a hub that imported a name and also wrote `export * from` that module re-exported nothing under that name ("Module './hub' has no export 'A'"), and a second star-exported module lost every routine whose name the first one already exported (`s.key()` on `Signer` not found).
// Root cause: the star re-export skipped every name already bound in the hub, and the export list kept one entry per name, so a symbol could reach the hub's interface only if its name was new.
// Fix: a star re-export hands on every symbol of the source interface by identity — a bound name only skips the scope define — and the export list dedups by symbol; two different non-routine symbols of one name are refused at the hub.
import { checkProjectDiagnostics, MapEntry } from "../helpers";

const ACCOUNT680 = `export struct Account { address: uint64; }
export function key(this a: Account): uint64 { return a.address * 2; }
`;

const SIGNER680 = `import { Account } from "./account";
export type Signer = distinct Account;
export function key(this s: Signer): uint64 { return (s as Account).address * 3; }
`;

function diagnostics680(files: MapEntry[], mainSource: string): string {
	const entries: MapEntry[] = [...files, { entryPath: "src/main.ms", entrySource: mainSource }];
	return checkProjectDiagnostics(entries, "src/main.ms").join("\n");
}

test "bug680: a name the hub imported still goes out through export *" {
	const files: MapEntry[] = [
		{ entryPath: "src/a.ms", entrySource: "export struct A { v: int32; }\nexport function make(): int32 { return 8; }\n" },
		{ entryPath: "src/hub.ms", entrySource: `import { A, make } from "./a";\nexport * from "./a";\nexport function twice(): int32 { return make() * 2; }\nexport function fresh(): A { return { v: 3 }; }\n` },
	];
	const d = diagnostics680(files, `import { A, make, twice, fresh } from "./hub";\nconst a: A = fresh();\nconst n: int32 = make() + twice() + a.v;\n`);
	assert d == "", d;
}

test "bug680: an import does not shadow a star export of the same name" {
	const files: MapEntry[] = [
		{ entryPath: "src/x.ms", entrySource: "export struct A { v: int32; }\n" },
		{ entryPath: "src/y.ms", entrySource: "export struct A { w: int32; }\nexport function mk(): A { return { w: 5 }; }\n" },
		{ entryPath: "src/hub.ms", entrySource: `import { A } from "./x";\nexport * from "./y";\nexport function local(): A { return { v: 2 }; }\n` },
	];
	const d = diagnostics680(files, `import { A, mk } from "./hub";\nconst a: A = mk();\nconst w: int32 = a.w;\n`);
	assert d == "", d;
}

test "bug680: same-named extensions of two star-exported modules both reach the importer" {
	const files: MapEntry[] = [
		{ entryPath: "src/account.ms", entrySource: ACCOUNT680 },
		{ entryPath: "src/signer.ms", entrySource: SIGNER680 },
		{ entryPath: "src/hub.ms", entrySource: `export * from "./account";\nexport * from "./signer";\n` },
	];
	const use = `import { Account, Signer } from "./hub";\nconst raw: Account = { address: 7 };\nconst s = raw as Signer;\nconst n: uint64 = raw.key() + s.key();\n`;
	const d = diagnostics680(files, use);
	assert d == "", d;
	const swapped: MapEntry[] = [files[0], files[1], { entryPath: "src/hub.ms", entrySource: `export * from "./signer";\nexport * from "./account";\n` }];
	const ds = diagnostics680(swapped, use);
	assert ds == "", ds;
	const named: MapEntry[] = [files[0], files[1], { entryPath: "src/hub.ms", entrySource: `export * from "./account";\nexport { Signer } from "./signer";\n` }];
	const dn = diagnostics680(named, use);
	assert dn == "", dn;
}

test "bug680: a generic receiver in the second module reaches the importer" {
	const files: MapEntry[] = [
		{ entryPath: "src/a.ms", entrySource: "export struct Account { address: uint64; }\nexport function data(this a: Account): uint64 { return a.address + 1; }\n" },
		{ entryPath: "src/c.ms", entrySource: "export type Mutable<T> = distinct T;\nexport function data<T>(this p: Mutable<T>): uint64 { return sizeof(T) as uint64; }\n" },
		{ entryPath: "src/hub.ms", entrySource: `export * from "./a";\nexport * from "./c";\n` },
	];
	const d = diagnostics680(files, `import { Account, Mutable } from "./hub";\nconst raw: Account = { address: 9 };\nconst m = raw as Mutable<Account>;\nconst n: uint64 = raw.data() + m.data();\n`);
	assert d == "", d;
}

test "bug680: a static and a free function of one name both go out through export *" {
	const lib = "export struct Meta { key: uint64; }\nexport function writable(index: int32): int32 { return index + 1; }\nexport function writable(this typeof Meta, key: uint64): Meta { return { key }; }\n";
	const files: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: lib },
		{ entryPath: "src/hub.ms", entrySource: `export * from "./lib";\n` },
	];
	const d = diagnostics680(files, `import { Meta, writable } from "./hub";\nconst one: uint64 = Meta.writable(7).key;\nconst two: int32 = writable(1);\n`);
	assert d == "", d;
}

test "bug680: a hub over a hub keeps both modules' extensions" {
	const files: MapEntry[] = [
		{ entryPath: "src/account.ms", entrySource: ACCOUNT680 },
		{ entryPath: "src/signer.ms", entrySource: SIGNER680 },
		{ entryPath: "src/hub.ms", entrySource: `export * from "./account";\nexport * from "./signer";\n` },
		{ entryPath: "src/outer.ms", entrySource: `export * from "./hub";\n` },
	];
	const d = diagnostics680(files, `import { Account, Signer } from "./outer";\nconst raw: Account = { address: 7 };\nconst n: uint64 = raw.key() + (raw as Signer).key();\n`);
	assert d == "", d;
}

test "bug680: two star exports of different types under one name are refused at the hub" {
	const files: MapEntry[] = [
		{ entryPath: "src/x.ms", entrySource: "export struct A { v: int32; }\n" },
		{ entryPath: "src/y.ms", entrySource: "export struct A { w: int32; }\n" },
		{ entryPath: "src/hub.ms", entrySource: `export * from "./x";\nexport * from "./y";\n` },
	];
	const d = checkProjectDiagnostics(files, "src/hub.ms").join("\n");
	assert d.contains("export * from './y': 'A' is already exported from another module"), d;
}
