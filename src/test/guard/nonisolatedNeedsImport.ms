// GUARD-CHECK-FAIL Cannot find name 'nonisolated'
// The actor-isolation intrinsic is a symbol exported by std/actor, not a word
// the checker knows by spelling. Without the import the name resolves to
// nothing and the decorator is rejected. A guard that compiles clean means the
// intrinsic went back to being recognised by its spelling.

actor Srv {
	@nonisolated
	readonly name: string = "srv";
	inside(): string { return this.name; }
}

const s = new Srv();
console.log(s.name);
