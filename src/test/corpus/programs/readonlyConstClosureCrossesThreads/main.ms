// @stdout: spawn accounts:2 id
// @stdout: actor accounts:2 id
// @stdout: spawn ledger:a1
// @stdout: actor ledger:a1
// @serial
import { accounts, ledger } from "./tables";

function describe(): string {
	return accounts.name + ":" + String(accounts.keyOf(1)) + " " + accounts.columns[0];
}

function describeLedger(): string {
	return ledger.name + ":" + ledger.keyOf({ id: "a1", balance: 5 });
}

actor Runner {
	source: Sendable<() => string>;
	constructor(source: Sendable<() => string>) {
		this.source = source;
	}
	run(): string {
		return this.source();
	}
}

console.log("spawn " + await spawn((): string => describe()));
const runner = new Runner((): string => describe());
console.log("actor " + await runner.run());
console.log("spawn " + await spawn((): string => describeLedger()));
const ledgerRunner = new Runner((): string => describeLedger());
console.log("actor " + await ledgerRunner.run());
