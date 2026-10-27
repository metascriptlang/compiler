// nim-guard: isolate(x) refuses what it cannot prove unshared, and a plain reference
//   parameter still cannot be sent.
//
// INVARIANT (PARALOCK E148, the reference's checkIsolate): isolate(...) is checked like a
//   `move` into an actor call — a fresh value, or a `move` of a binding that is its sole
//   owner. A parameter, an aliased local, a bare name and a literal that holds a live local
//   are refused, and a parameter that holds a class reference is still refused at an actor
//   call, plain or moved: Isolated<T> is the spelling that forwards it.
//
// WHAT IT CATCHES: isolate(...) accepting an argument another name still reaches, which
//   would make an Isolated<T> a wrapper around a shared graph, and the sole-owner early
//   return for Isolated types leaking to ordinary reference parameters.
//
// RED MEANS: one of the diagnostics stopped firing; read checkIsolateArg and checkMoveSoleOwner
//   in checker/sendable.ms.
//
// GUARD-CHECK-FAIL it is a parameter
// GUARD-CHECK-FAIL it is bound to 'a'
// GUARD-CHECK-FAIL a binding is not proven unshared
// GUARD-CHECK-FAIL is not a fresh value
// GUARD-CHECK-FAIL actor methods only accept value types

import { isolate } from "std/isolation";

class Node { n: int32 = 0; }
struct Req { name: string; node: Node; }

actor Exec {
	seen: int32 = 0;
	take(req: Req): int32 { this.seen += req.node.n; return this.seen; }
}

// 1 — a parameter: the caller still owns it.
function isolateParam(r: Node): void {
	const iso = isolate(move r); // GUARD-REFUSED
}

// 2 — aliased into another binding before the isolate.
function isolateAliased(): int32 {
	const n = new Node();
	const a = n;
	const iso = isolate(move n); // GUARD-REFUSED
	return a.n;
}

// 3 — a bare name is not a proof.
function isolateBareName(): void {
	const n = new Node();
	const iso = isolate(n); // GUARD-REFUSED
}

// 4 — a literal that holds a live local is not a fresh value.
function isolateLiteralOfLocal(): void {
	const n = new Node();
	const iso = isolate({ name: "x", node: n } as Req); // GUARD-REFUSED
}

// 5 — a plain parameter holding a class reference still cannot be sent.
async function sendPlainParam(exec: Exec, req: Req): Promise<int32> {
	return await exec.take(req); // GUARD-REFUSED
}

// 6 — and still cannot be moved: the caller owns it.
async function movePlainParam(exec: Exec, req: Req): Promise<int32> {
	return await exec.take(move req); // GUARD-REFUSED
}
