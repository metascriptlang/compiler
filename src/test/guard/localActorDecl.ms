// A LOCAL actor declaration must reach codegen with a DEFINED TypeInfo.
// actorLower rewrites the ActorDecl into a ClassDecl and only scans top-level
// statements, so the decl rides the same module-statement lift as a local
// class. The lift lands it at the FRONT: C claims TypeInfo ownership when the
// declaration is emitted (declaredThings in genClassDecl), and destructorLifting
// declines to emit TypeInfo for an actor symbol (isClassOrInterface covers
// Class/Interface only), so a decl emitted after its `new` site left
// `extern msTypeInfo <T>TypeInfo` with no definition — undefined symbol at link,
// invisible to compileToC-based tests.
//
// RED MEANS: the lift stopped covering actors, or it went back to appending.
// No GUARD-JS: actors are a C-backend construct (transform/index.ms gates
// lowerActor on !jsBackend).

import { stop, ExitReason } from "std/actor";

function spawnLocal(): number {
	actor Tiny {
		v: number = 7;
		get(): number { return this.v; }
	}
	const a = new Tiny();
	const alive = a.pid != 0 ? 5 : 0;
	stop(a.pid, ExitReason.Normal);
	return alive;
}

const total = spawnLocal();
console.log(total);
if (total == 5) {
	console.log("GUARD-OK");
}
