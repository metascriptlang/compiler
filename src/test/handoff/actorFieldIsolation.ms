import { checkProjectDiagnostics, MapEntry } from "../helpers";

const refusal = "cannot access actor field 'n' directly";

function occurrences(messages: string[], text: string): int32 {
	let n = 0;
	for (const m of messages) {
		if (m.contains(text)) n += 1;
	}
	return n;
}

function counterModule(): MapEntry {
	return { entryPath: "src/counter.ms", entrySource: `export actor Counter {
	n: int32 = 0;
	bump(): void { this.n = this.n + 1; }
}
export function make(): Counter { return new Counter(); }
` };
}

test "actorFieldIsolation: a field read is refused where the actor's name is imported" {
	const entries: MapEntry[] = [
		counterModule(),
		{ entryPath: "src/main.ms", entrySource: `import { make, Counter } from "./counter";
const c: Counter = make();
console.log(c.n);
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, refusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: a field read is refused where the actor's name is not imported" {
	const entries: MapEntry[] = [
		counterModule(),
		{ entryPath: "src/main.ms", entrySource: `import { make } from "./counter";
const c = make();
console.log(c.n);
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, refusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: a class named like the actor does not lift the refusal" {
	const entries: MapEntry[] = [
		counterModule(),
		{ entryPath: "src/main.ms", entrySource: `import { make } from "./counter";
class Counter { n: int32 = 5; }
const c = make();
console.log(c.n);
const d = new Counter();
console.log(d.n);
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, refusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: an actor reads its own field and is refused another actor's of the same name" {
	const entries: MapEntry[] = [
		counterModule(),
		{ entryPath: "src/main.ms", entrySource: `import { make } from "./counter";
actor Counter {
	n: int32 = 0;
	own(): int32 { return this.n; }
	peek(): int32 { const o = make(); return o.n; }
}
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, refusal) == 1, messages.join("\n");
}

const peerRefusal = "the state of another actor instance is reached only through its methods";

function diagnosticsOf(source: string): string[] {
	return checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms");
}

test "actorFieldIsolation: a method is refused a peer read of its own actor type" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	peek(peer: Counter): int32 { return peer.n; }
}
`);
	assert occurrences(messages, peerRefusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: a method is refused a peer write of its own actor type" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	poke(peer: Counter): void { peer.n = 1; }
}
`);
	assert occurrences(messages, peerRefusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: a local alias of the peer is refused" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	peek(peer: Counter): int32 { const p = peer; return p.n; }
}
`);
	assert occurrences(messages, peerRefusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: a peer reached through an array element or an own field is refused" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	peers: Counter[] = [];
	viaParam(ps: Counter[]): int32 { return ps[0].n; }
	viaField(): int32 { return this.peers[0].n; }
}
`);
	assert occurrences(messages, peerRefusal) == 2, messages.join("\n");
}

test "actorFieldIsolation: a mutable binding of this is refused because it can be rebound to a peer" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	peek(peer: Counter): int32 { let s = this; s = peer; return s.n; }
}
`);
	assert occurrences(messages, peerRefusal) == 1, messages.join("\n");
}

test "actorFieldIsolation: this and a const bound to this read and write the actor's own state" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	own(): int32 { return this.n; }
	alias(): int32 { const self = this; const again = self; again.n = self.n + 1; return self.n; }
	inClosure(): int32 { const self = this; const f = () => self.n; return f(); }
}
`);
	assert messages.length == 0, messages.join("\n");
}

test "actorFieldIsolation: a method call on a peer stays legal" {
	const messages = diagnosticsOf(`actor Counter {
	n: int32 = 7;
	get(): int32 { return this.n; }
	ask(peer: Counter): int32 { return await peer.get(); }
}
`);
	assert messages.length == 0, messages.join("\n");
}

test "actorFieldIsolation: an ordinary class peer field keeps normal visibility" {
	const messages = diagnosticsOf(`class Box {
	n: int32 = 7;
	peek(peer: Box): int32 { return peer.n; }
}
`);
	assert messages.length == 0, messages.join("\n");
}

const handleName = "cannot declare a member named 'pid'";

test "actorFieldIsolation: an actor field named pid is refused because pid reads the handle" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `actor Clash {
	pid: int32 = 7;
	get(): int32 { return this.pid; }
}
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, handleName) == 1, messages.join("\n");
}

test "actorFieldIsolation: an actor method named pid is refused, a static one is not" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `actor Clash {
	n: int32 = 0;
	pid(): int32 { return 1; }
}
actor Fine {
	static pid(): int32 { return 2; }
}
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, handleName) == 1, messages.join("\n");
}

test "actorFieldIsolation: an extension on an actor reads a field no more than any other function" {
	const entries: MapEntry[] = [
		counterModule(),
		{ entryPath: "src/main.ms", entrySource: `import { make, Counter } from "./counter";
function peek(this c: Counter): int32 { return c.n; }
console.log(make().peek());
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, refusal) == 1, messages.join("\n");
}

const actorHead = `actor Srv {
	name: string = "srv";
	n: int32 = 1;
	bump(): void { this.n = this.n + 1; }
	get(): int32 { return this.n; }
	mine(): int32 { const me = this; return me.n + this.n; }
}
actor Other { name: string = "o"; n: int32 = 2; other(): int32 { return this.n; } }
actor Empty { ping(): void {} }
class Plain { name: string = "p"; n: int32 = 2; }
type Shape = { name: string; n: int32 };
type Nothing = {};
interface Named { name: string; }
function show(o: Shape): void { console.log(o.name, o.n); }
function nameOf<T extends Named>(x: T): string { return x.name; }
`;

function actorRefDiagnostics(body: string): string[] {
	const all = checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: actorHead + body }], "src/main.ms");
	return all.filter((m: string): boolean => !m.contains("is declared but never used"));
}

test "actorFieldIsolation: an actor reference converts to no type but its own" {
	const refused: string[][] = [
		["const s = new Srv(); const o: Shape = s;", "Type 'Srv' is not assignable to type"],
		["const s = new Srv(); show(s);", "got Srv, expected"],
		["const s = new Srv(); show(s as Shape);", ""],
		["const s = new Srv(); const o: Named = s;", "Type 'Srv' is not assignable to type 'Named'"],
		["const s = new Srv(); const o: Shape | null = s;", "Type 'Srv' is not assignable to type"],
		["const s = new Srv(); const xs: Shape[] = [s];", "Type 'Srv' is not assignable to type"],
		["function mk(): Shape { return new Srv(); }", "Type 'Srv' is not assignable to type"],
		["const s = new Srv(); let o: Shape = { name: \"a\", n: 0 }; o = s;", "Type 'Srv' is not assignable to type"],
		["class Holder { o: Shape = new Srv(); }", "Type 'Srv' is not assignable to type"],
		["const e = new Empty(); const o: Nothing = e;", "Type 'Empty' is not assignable to type '{}'"],
		["const s = new Srv(); console.log(nameOf(s));", "does not satisfy constraint 'Named'"],
		["const o: Other = new Srv();", "Type 'Srv' is not assignable to type 'Other'"],
		["const s: Srv = new Plain();", "Type 'Plain' is not assignable to type 'Srv'"],
		["actor In { name: string = \"x\"; n: int32 = 1; mine(): int32 { const o: Shape = this; return o.n; } }", "Type 'In' is not assignable to type"],
		["actor In { name: string = \"x\"; n: int32 = 1; peer(p: In): int32 { const o: Shape = p; return o.n; } }", "Type 'In' is not assignable to type"],
	];
	for (const row of refused) {
		const messages = actorRefDiagnostics(row[0]);
		assert messages.length > 0 && occurrences(messages, row[1]) >= 1, row[0] + " -> " + messages.join(" | ");
	}
	const legal = actorRefDiagnostics(`const s = new Srv(); const t: Srv = s; const xs: Srv[] = [s, t]; const ys = [...xs];
function pass(a: Srv): Srv { return a; }
class Keep { a: Srv = new Srv(); b: Srv | null = null; }
const k = new Keep(); k.b = k.a;
const u = pass(ys[1]); u.bump();
console.log(await u.get(), await s.mine(), s == t, s.pid == t.pid);
`);
	assert legal.length == 0, legal.join("\n");
}

test "actorFieldIsolation: an actor reference is neither destructured nor spread" {
	const refused: string[][] = [
		["const s = new Srv(); const { name, n } = s;", "cannot destructure an actor"],
		["const s = new Srv(); const { name, ...rest } = s;", "cannot destructure an actor"],
		["const s = new Srv(); const o = { ...s };", "cannot spread an actor"],
		["const s = new Srv(); const o: Shape = { ...s };", "cannot spread an actor"],
		["actor In { n: int32 = 1; own(): int32 { const { n } = this; return n; } }", "cannot destructure an actor"],
		["actor In { n: int32 = 1; own(): int32 { const me = this; const o = { ...me }; return o.n; } }", "cannot spread an actor"],
		["actor In { n: int32 = 1; peer(p: In): int32 { const { n } = p; return n; } }", "cannot destructure an actor"],
	];
	for (const row of refused) {
		const messages = actorRefDiagnostics(row[0]);
		assert occurrences(messages, row[1]) == 1, row[0] + " -> " + messages.join(" | ");
	}
	const legal = actorRefDiagnostics(`const p = new Plain(); const { name, n } = p; const c = { ...p }; const o: Shape = p; console.log(name, n, c.n, o.n);`);
	assert legal.length == 0, legal.join("\n");
}
