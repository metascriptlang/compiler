// @stdout: spawn accounts:2 id
// @stdout: actor accounts:2 id
// @serial
import { accounts } from "./tables";

function describe(): string {
	return accounts.name + ":" + String(accounts.keyOf(1)) + " " + accounts.columns[0];
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
