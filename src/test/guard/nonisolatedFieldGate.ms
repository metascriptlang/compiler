// GUARD-CHECK-FAIL cannot access actor field 'name' directly
// Reading an actor field from outside the actor is only allowed through the
// isolation intrinsic; a plain field stays behind the mailbox. A guard that
// compiles clean means the gate in the checker was dropped.

actor Srv {
	readonly name: string = "srv";
	inside(): string { return this.name; }
}

const s = new Srv();
console.log(s.name);
