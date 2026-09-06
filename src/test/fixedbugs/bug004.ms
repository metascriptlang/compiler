// bug004 — class method default params not applied at call site
//
// Symptom:    Calling a non-static class method with fewer args than its
//             signature, where the missing tail args have defaults, failed
//             with C-level "too few arguments to function call, expected 2,
//             have 1". A standalone function with the same default-arg
//             pattern worked. Bug surfaced while building ion (desktop
//             runtime) — every method call had to pass all args explicitly,
//             defeating the point of `= default`.
//
// Root cause: `collectClassMethod` (src/checker/collectPass.ms) prepends a
//             synthetic "this" param to the method's params/types/locations,
//             but did NOT shift `md.methodDefaults` to match. Worse, it
//             never copied `md.methodDefaults` onto the method's Symbol —
//             only the FunctionDecl branch in resolvePass writes
//             `sym.defaultParams`. So the method symbol's `defaultParams`
//             stayed empty, the FunctionDecl-only fallback in
//             `fillDefaultArgsForNode` skipped MethodDecl, and the call
//             site never filled in the missing args.
//
// Fix:        In `collectClassMethod` for non-static methods: prepend a
//             null entry to `md.methodDefaults` so position 0 lines up with
//             the synthetic "this" receiver (matches the convention used by
//             standalone extension methods + their `defaultOffset=1` at the
//             call site). Then write `methodSym.defaultParams =
//             md.methodDefaults` so `fillDefaultArgsForNode` finds them.

class Greeter {
	name: string;
	constructor(n: string) { this.name = n; }
	greet(greeting: string = "Hello"): string {
		return `${greeting}, ${this.name}`;
	}
}

test "bug004: non-static method with single default arg fires when omitted" {
	const g = new Greeter("world");
	const a = g.greet();
	assert a == "Hello, world";
}

test "bug004: non-static method default is overridable" {
	const g = new Greeter("world");
	const b = g.greet("Hi");
	assert b == "Hi, world";
}

class Counter {
	value: int32;
	constructor() { this.value = 0; }
	add(amount: int32 = 1, scale: int32 = 1): int32 {
		this.value = this.value + amount * scale;
		return this.value;
	}
}

test "bug004: method with two trailing defaults — both fire when omitted" {
	const c = new Counter();
	const after = c.add();
	assert after == 1;
}

test "bug004: method with two trailing defaults — only the second fires" {
	const c = new Counter();
	const after = c.add(5);
	assert after == 5;
}

test "bug004: method with two trailing defaults — neither fires when both supplied" {
	const c = new Counter();
	const after = c.add(3, 2);
	assert after == 6;
}

class Mix {
	prefix: string;
	constructor(p: string) { this.prefix = p; }
	// Required arg followed by a default — the default still has to fire when omitted.
	wrap(value: string, suffix: string = "!"): string {
		return this.prefix + value + suffix;
	}
}

test "bug004: required + default mix — default fires when omitted" {
	const m = new Mix(">>");
	const out = m.wrap("hi");
	assert out == ">>hi!";
}

test "bug004: required + default mix — default overridable" {
	const m = new Mix(">>");
	const out = m.wrap("hi", "?");
	assert out == ">>hi?";
}
