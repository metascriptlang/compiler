import { compileToC } from "../helpers";

const SENT = `
type Probe = Sendable<(n: int32) => int32>;
function take(p: Probe): int32 { return p(1); }
function takeSink(sink p: Probe): int32 { return p(1); }
`;

function envStructBodies(c: string, fn: string): string[] {
	const bodies: string[] = [];
	const head = "struct dollarEnv_" + fn + "_";
	let from = 0;
	while (true) {
		const at = c.indexOf(head, from);
		if (at < 0) break;
		const end = c.indexOf("};", at);
		const rest = c.slice(at + head.length, end);
		if (!rest.startsWith("shared")) bodies.push(rest);
		from = end;
	}
	return bodies;
}

function holdsCopy(bodies: string[], field: string): boolean {
	for (const b of bodies) {
		if (b.contains("void* dollarup_;") && b.contains(field)) return true;
	}
	return false;
}

test "E2E C: a Sendable closure beside a sibling closure gets an env of its own with copies and no typed parent" {
	const src = SENT + `
function viaPlain(id: int32): int32 {
	const base: int32 = id + 2;
	const other = (): int32 => base + id;
	return take((n: int32): int32 => n + base) + other();
}
console.log(viaPlain(1));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
	const bodies = envStructBodies(c.value, "viaPlain");
	assert holdsCopy(bodies, "base"), bodies.join(" | ");
	for (const b of bodies) assert !b.contains("dollarEnv_viaPlain_shared"), b;
}

test "E2E C: a Sendable closure passed to a sink parameter gets the same detached env" {
	const src = SENT + `
function viaSink(id: int32): int32 {
	const base: int32 = id + 1;
	const other = (): int32 => base + id;
	return takeSink((n: int32): int32 => n + base) + other();
}
console.log(viaSink(1));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
	assert holdsCopy(envStructBodies(c.value, "viaSink"), "base");
}

test "E2E C: a closure bound to a const and sent later, and a local function declaration, get detached envs" {
	const bound = SENT + `
function viaBinding(id: int32): int32 {
	const base: int32 = id + 3;
	const other = (): int32 => base + id;
	const f: Probe = (n: int32): int32 => n + base;
	return take(f) + other();
}
console.log(viaBinding(1));`;
	const b = compileToC(bound);
	assert b.ok, b.ok ? "" : b.error;
	assert holdsCopy(envStructBodies(b.value, "viaBinding"), "base");
	const declared = SENT + `
function viaDeclaration(id: int32): int32 {
	const base: int32 = id + 4;
	const other = (): int32 => base + id;
	function add(n: int32): int32 { return n + base; }
	return take(add) + other();
}
console.log(viaDeclaration(1));`;
	const d = compileToC(declared);
	assert d.ok, d.ok ? "" : d.error;
	assert holdsCopy(envStructBodies(d.value, "viaDeclaration"), "base");
}

test "E2E C: a closure that is not Sendable keeps the shared env" {
	const src = `
function plain(id: int32): int32 {
	const base: int32 = id + 5;
	const other = (): int32 => base + id;
	const third = (): int32 => base * 2;
	return other() + third();
}
console.log(plain(1));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
	assert envStructBodies(c.value, "plain").length == 0;
}

test "E2E C: a Sendable closure reaching a local helper closure gives the helper an env of its own too" {
	const src = SENT + `
function viaHelper(id: int32): int32 {
	const base: int32 = id + 6;
	const helper = (n: int32): int32 => n + base;
	return take((n: int32): int32 => helper(n));
}
console.log(viaHelper(1));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
	const bodies = envStructBodies(c.value, "viaHelper");
	assert holdsCopy(bodies, "base"), bodies.join(" | ");
	assert holdsCopy(bodies, "helper"), bodies.join(" | ");
}
