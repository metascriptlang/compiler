// nim-guard: Isolated<T> — a value holding a class reference is forwarded through
//   function parameters into an actor method.
//
// INVARIANT (PARALOCK E148, the reference's Isolated[T]): isolate(...) proves the value
//   unshared where it is made; the wrapper has no copy, so a `sink` parameter of that type
//   is the sole owner and `move` carries it through any number of layers. The actor reads
//   the value from the message it received.
//
// WHAT IT CATCHES: the sole-owner rule (E148) refusing `move iso` of a parameter whose type
//   cannot be copied, the actor-argument check refusing the wrapper, or isolate's result
//   losing its payload between layers. Proven red on the base binary (2026-10-28): std/isolation
//   does not exist there, so the program does not build.
//
// RED MEANS: a layer of the forward is refused or the actor sees a different value; read
//   sole-owner handling in checker/sendable.ms and the copy rule in analyzer/inject.ms.
//
// GUARD-JS

import { Isolated, isolate, extract } from "std/isolation";

class Node { n: int32 = 0; }
struct Req { name: string; node: Node; }
struct Msg { tag: int32; req: Isolated<Req>; }

actor Exec {
	seen: int32 = 0;
	run(req: Isolated<Req>): int32 {
		this.seen += req.value.node.n;
		return this.seen;
	}
	open(m: Msg): int32 {
		this.seen += m.req.value.node.n * m.tag;
		return this.seen;
	}
}

actor Hub {
	seen: int32 = 0;
	attach(step: Isolated<Step>): int32 { return step.value(this.seen + 1); }
}

type Step = Sendable<(n: int32) => int32>;

function makeNode(n: int32): Node {
	const node = new Node();
	node.n = n;
	return node;
}

async function layerTwo(exec: Exec, sink req: Isolated<Req>): Promise<int32> {
	return await exec.run(move req);
}

async function layerOne(exec: Exec, sink req: Isolated<Req>): Promise<int32> {
	return await layerTwo(exec, move req);
}

async function layerMsg(exec: Exec, sink req: Isolated<Req>): Promise<int32> {
	const m: Msg = { tag: 10, req: move req };
	return await exec.open(move m);
}

async function layerStep(hub: Hub, sink step: Isolated<Step>): Promise<int32> {
	return await hub.attach(move step);
}

function unwrap(sink req: Isolated<Req>): int32 {
	const r = extract(move req);
	return r.node.n;
}

async function main(): Promise<void> {
	const exec = new Exec();
	const first = isolate({ name: "a", node: makeNode(5) } as Req);
	const a = await layerOne(exec, move first);
	const second = isolate({ name: "b", node: makeNode(2) } as Req);
	const b = await layerMsg(exec, move second);
	const double: Step = (n: int32): int32 => n * 2;
	const c = await layerStep(new Hub(), move isolate(double));
	const d = unwrap(isolate({ name: "d", node: makeNode(7) } as Req));
	if (a != 5) { throw "GUARD-FAIL two-layer forward: " + String(a); }
	if (b != 25) { throw "GUARD-FAIL wrapper inside a message: " + String(b); }
	if (c != 2) { throw "GUARD-FAIL Sendable closure forward: " + String(c); }
	if (d != 7) { throw "GUARD-FAIL extract: " + String(d); }
	console.log("GUARD-OK");
}

main();
