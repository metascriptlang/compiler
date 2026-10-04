import { checkProjectDiagnostics, MapEntry } from "../helpers";

function hasMessage(messages: string[], text: string): boolean {
	for (const m of messages) {
		if (m.contains(text)) return true;
	}
	return false;
}

const accountModule = `export struct Account { address: uint64; }
export function key(this a: Account): uint64 { return a.address * 2; }
export function pick(n: number): string { return "number"; }
`;

const signerModule = `import { Account, key, pick } from "./account";
export type Signer = distinct Account;
export function key(this s: Signer): uint64 { return 99; }
export function pick(s: string): string { return "string"; }
export function inside(a: Account): string { return \`\${key(a)} \${pick(1)}\`; }
`;

test "routineInterface: an importer of a module's routine does not reach the routine that module imported" {
	const entries: MapEntry[] = [
		{ entryPath: "src/account.ms", entrySource: accountModule },
		{ entryPath: "src/signer.ms", entrySource: signerModule },
		{ entryPath: "src/main.ms", entrySource: `import { Account } from "./account";
import { key } from "./signer";
const raw: Account = { address: 21 };
console.log(String(key(raw)));
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert hasMessage(messages, "Argument type mismatch in 'key'"), messages.join("\n");
}

test "routineInterface: the same holds for a plain overloaded routine, and the declaring module still calls both" {
	const entries: MapEntry[] = [
		{ entryPath: "src/account.ms", entrySource: accountModule },
		{ entryPath: "src/signer.ms", entrySource: signerModule },
		{ entryPath: "src/main.ms", entrySource: `import { pick, inside } from "./signer";
import { Account } from "./account";
const raw: Account = { address: 21 };
console.log(pick("s"), pick(1), inside(raw));
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert hasMessage(messages, "pick"), messages.join("\n");
	assert messages.length == 1, messages.join("\n");
}
