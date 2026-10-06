// Route 15j: Checker — a method with its own type parameters, or a method of a generic class, is never part of an override pair

import { strictErrorCount, hasError } from "./helpers";

const OVERRIDE_ERR = "a method with its own type parameters cannot override or be overridden";

test "a generic method overriding a generic method is rejected" {
	const src = "class Base { firstOf<T>(a: T, b: T): T { return a; } }\nclass Sub extends Base { firstOf<T>(a: T, b: T): T { return b; } }";
	assert hasError(src, "Method 'Sub.firstOf' overrides 'Base.firstOf'; " + OVERRIDE_ERR);
}

test "a plain method overriding a generic method is rejected" {
	const src = "class Base { pick<T>(a: T): T { return a; } }\nclass Sub extends Base { pick(a: int32): int32 { return a; } }";
	assert hasError(src, "Method 'Sub.pick' overrides 'Base.pick'; " + OVERRIDE_ERR);
}

test "a generic method overriding a plain method is rejected" {
	const src = "class Base { pick(a: int32): int32 { return a; } }\nclass Sub extends Base { pick<T>(a: T): T { return a; } }";
	assert hasError(src, "Method 'Sub.pick' overrides 'Base.pick'; " + OVERRIDE_ERR);
}

test "an override two levels below the generic method is rejected" {
	const src = "class Base { pick<T>(a: T): T { return a; } }\nclass Mid extends Base { n: int32 = 0; }\nclass Leaf extends Mid { pick<T>(a: T): T { return a; } }";
	assert hasError(src, "Method 'Leaf.pick' overrides 'Base.pick'; " + OVERRIDE_ERR);
}

test "plain overrides and generic methods nobody overrides stay legal" {
	assert strictErrorCount("class Base { pick(a: int32): int32 { return a; } }\nclass Sub extends Base { pick(a: int32): int32 { return a + 1; } }") == 0;
	assert strictErrorCount("class Base { pick<T>(a: T): T { return a; } }\nclass Sub extends Base { other<T>(a: T): T { return a; } }") == 0;
}

const CLASS_OVERRIDE_ERR = "a method of a generic class cannot override or be overridden";
const GENERIC_BASE = "class Base<U> { u: U; constructor(u: U) { this.u = u; } get(): U { return this.u; } }\n";

test "a method of a generic class overridden through an instance is rejected" {
	assert hasError(GENERIC_BASE + "class Sub extends Base<int32> { get(): int32 { return 2; } }", "Method 'Sub.get' overrides 'Base.get'; " + CLASS_OVERRIDE_ERR);
	assert hasError(GENERIC_BASE + "class Mid extends Base<int32> { n: int32 = 0; }\nclass Leaf extends Mid { get(): int32 { return 2; } }", "Method 'Leaf.get' overrides 'Base.get'; " + CLASS_OVERRIDE_ERR);
}

test "a method of a generic class overridden by a generic subclass is rejected" {
	assert hasError(GENERIC_BASE + "class Sub<T> extends Base<T> { get(): T { return this.u; } }", "Method 'Sub.get' overrides 'Base.get'; " + CLASS_OVERRIDE_ERR);
	assert hasError("class Base { get(): int32 { return 1; } }\nclass Sub<T> extends Base { get(): int32 { return 2; } }", "Method 'Sub.get' overrides 'Base.get'; " + CLASS_OVERRIDE_ERR);
}

test "a class extending an instance keeps plain overrides among its own subclasses" {
	assert strictErrorCount(GENERIC_BASE + "class Sub extends Base<int32> { twice(): int32 { return this.u * 2; } }\nclass Leaf extends Sub { twice(): int32 { return 0; } }") == 0;
	assert strictErrorCount(GENERIC_BASE + "class Sub extends Base<int32> { other(): int32 { return 2; } }") == 0;
}
