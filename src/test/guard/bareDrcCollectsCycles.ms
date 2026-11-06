// GUARD-OS bare
// GUARD-ASAN
// Bare DRC collects an unreachable cycle: collectCycles destroys both links of a ring and their owned
// children. RED MEANS the cycle collector does not run on bare, so a ring's members leak.
import { collectCycles } from "std/runtime";

let destroyed: int32 = 0;

class Resource {
	value: int32 = 1;
}

function onDestroy(this resource: Resource): void {
	destroyed += resource.value;
}

class Link {
	next: Link | null = null;
	resource: Resource = new Resource();
}

function createRing(): void {
	const first = new Link();
	const second = new Link();
	first.next = second;
	second.next = first;
}

createRing();
collectCycles();
if (destroyed == 2) console.log("GUARD-OK");
