// One wait path per await, chosen from the context: a sync function waits on each operand
// once, an async function and an actor method yield instead of blocking, and the actor
// method's reply suspends the actor. Runtime behaviour: corpus `awaitableKindsShareOnePromiseType`.

import { compileToC } from "../helpers";

function bodiesOf(c: string, fn: string): string {
	let out = "";
	let from = 0;
	for (const line of c.split("\n")) {
		if (line.contains(fn) && line.endsWith(") {") && !line.startsWith(" ") && !line.startsWith("\t")) {
			const open = c.indexOf(line, from);
			const close = c.indexOf("\n}", open);
			out = out + c.slice(open, close) + "\n";
			from = close;
		}
	}
	return out;
}

function count(body: string, op: string): int32 {
	return (body.split(`${op}(`).length - 1) as int32;
}

const WORK = `
function work(n: int32): int32 { return n + 1; }
async function asy(n: int32): Promise<int32> { return n * 2; }
`;

test "E2E C: a sync function waits once per await, on a spawn and on an async call" {
	const r = compileToC(WORK + `
function syncSite(): int32 {
	const a = await spawn(() => work(1));
	const b = await asy(3);
	return a + b;
}
console.log(\`\${syncSite()}\`);
`);
	assert r.ok;
	const body = bodiesOf(r.ok ? r.value : "", " syncSite__");
	assert body != "";
	assert count(body, "msAwaitSlotWait") == 1;
	assert count(body, "msWaitForReady") == 1;
}

test "E2E C: an async function yields at each await and never blocks" {
	const r = compileToC(WORK + `
async function asyncSite(): Promise<int32> {
	const a = await spawn(() => work(1));
	const b = await asy(3);
	return a + b;
}
console.log(\`\${await asyncSite()}\`);
`);
	assert r.ok;
	const body = bodiesOf(r.ok ? r.value : "", "asyncSite");
	assert body != "";
	assert count(body, "msAwaitSlotWait") == 0;
	assert count(body, "msWaitForReady") == 0;
}

test "E2E C: an actor method suspends the actor at its awaits and never blocks" {
	const r = compileToC(`
function work(n: int32): int32 { return n + 1; }
actor Other { get(n: int32): int32 { return n * 2; } }
actor Counter {
	total: int32 = 0;
	actorSite(o: Other): int32 {
		const a = await spawn(() => work(1));
		const b = await o.get(3);
		this.total = a + b;
		return this.total;
	}
}
const o = new Other();
const c = new Counter();
console.log(\`\${await c.actorSite(o)}\`);
`);
	assert r.ok;
	const c = r.ok ? r.value : "";
	const site = bodiesOf(c, "Counter_actorSite");
	assert site != "";
	assert count(site, "msAwaitSlotWait") == 0;
	assert count(site, "msWaitForReady") == 0;
	assert bodiesOf(c, " Counter_dispatch__").contains("msActorSuspendReply");
}
