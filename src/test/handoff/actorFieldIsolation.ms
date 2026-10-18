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
