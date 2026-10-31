// Parser + Checker — a constructor parameter with a modifier declares a field; a misplaced one is refused

import { strictErrorCount, hasError } from "./helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";

function parseRefusal(src: string, needle: string): boolean {
	const pr = parseSource(src);
	return !pr.ok && pr.error.indexOf(needle) >= 0;
}

test "each modifier declares a readable field" {
	assert strictErrorCount("class K { constructor(public xs: number[]) {} len(): int32 { return this.xs.length; } }\nconsole.log(new K([1]).len());") == 0;
	assert strictErrorCount("class K { constructor(private n: int32) {} get(): int32 { return this.n; } }") == 0;
	assert strictErrorCount("class K { constructor(protected n: int32) {} }\nclass J extends K { get(): int32 { return this.n; } }") == 0;
	assert strictErrorCount("class K { constructor(readonly n: int32) {} }\nconsole.log(new K(1).n);") == 0;
	assert strictErrorCount("class K { constructor(private readonly n: int32, public readonly m: int32) {} get(): int32 { return this.n + this.m; } }") == 0;
	assert strictErrorCount("class K { constructor(public tag?: string) {} }\nconsole.log(new K().tag);") == 0;
}

test "a private parameter property is private" {
	assert hasError("class K { constructor(private n: int32) {} }\nconsole.log(new K(1).n);", "private");
}

test "a readonly parameter property refuses reassignment" {
	assert hasError("class K { constructor(readonly n: int32) {} set(): void { this.n = 2; } }", "read-only property");
	assert hasError("class K { constructor(private readonly n: int32) {} set(): void { this.n = 2; } }", "read-only property");
	assert strictErrorCount("class K { constructor(public n: int32) {} set(): void { this.n = 2; } }") == 0;
}

test "a parameter property with the name of a declared field is a duplicate member" {
	assert hasError("class K { n: int32 = 1; constructor(public n: int32) {} }", "Duplicate identifier 'n'");
}

test "a modifier outside a constructor is refused" {
	assert parseRefusal("function f(public x: int32): int32 { return x; }", "only allowed in a constructor");
	assert parseRefusal("class K { m(private x: int32): int32 { return x; } }", "only allowed in a constructor");
	assert !parseSource("const f = (public x: int32): int32 => x;").ok;
}

test "a parameter property cannot be a rest parameter or a binding pattern" {
	assert parseRefusal("class K { constructor(public ...xs: int32[]) {} }", "rest parameter");
	assert parseRefusal("class K { constructor(public { a }: { a: int32 }) {} }", "binding pattern");
}

test "an actor constructor refuses a parameter property" {
	assert hasError("actor A { constructor(public n: int32) {} }", "actor");
}
