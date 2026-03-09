// Test: class member access in else-if chains
//
// Reproduces self-compile blocker: accessing class fields like .kind on Type
// works in the first `if` but fails in `else if` with "does not exist on type 'object'".
// Also tests: unimported type alias in `as` cast → 'object', wrong field names on NodeData.

import { checkSource } from "./helpers";
import { Severity } from "../../checker/context";

function hasError(ctx: any, needle: string): boolean {
	let i = 0;
	while (i < ctx.errors.length) {
		const msg: string = ctx.errors[i].message;
		if (msg.length >= needle.length) {
			let found = false;
			let j = 0;
			while (j <= msg.length - needle.length) {
				let match = true;
				let k = 0;
				while (k < needle.length) {
					if (msg[j + k] !== needle[k]) { match = false; }
					k = k + 1;
				}
				if (match) { found = true; }
				j = j + 1;
			}
			if (found) return true;
		}
		i = i + 1;
	}
	return false;
}

function errorCount(ctx: any): number {
	let count = 0;
	let i = 0;
	while (i < ctx.errors.length) {
		if (ctx.errors[i].severity === Severity.Error) {
			count = count + 1;
		}
		i = i + 1;
	}
	return count;
}

// Test 1: Class member access in simple if — should work
test "class field access in if condition" {
	const ctx = checkSource(`
		class Foo {
			kind: number;
			value: string;
		}
		function test(f: Foo): number {
			if (f !== null && f.kind === 1) {
				return f.kind;
			}
			return 0;
		}
	`);
	assert ctx !== null;
	assert errorCount(ctx) === 0;
}

// Test 2: Pure null check — else branch SHOULD narrow to null (opposite narrowing valid)
test "pure null check narrows else to null" {
	const ctx = checkSource(`
		class Foo {
			kind: number;
		}
		function test(f: Foo): number {
			if (f !== null) {
				return f.kind;
			} else {
				return 0;
			}
		}
	`);
	assert ctx !== null;
	assert errorCount(ctx) === 0;
}

// Test 3: Compound null check — else branch should NOT narrow to null
// NOT(f !== null && f.kind === 1) = (f === null || f.kind !== 1)
test "compound condition else branch keeps original type" {
	const ctx = checkSource(`
		class Foo {
			kind: number;
		}
		function test(f: Foo): number {
			if (f !== null && f.kind === 1) {
				return 1;
			} else {
				return f.kind;
			}
		}
	`);
	assert ctx !== null;
	assert errorCount(ctx) === 0;
}

// Test 4: Class member access in else-if — was the main bug
test "class field access in else-if condition" {
	const ctx = checkSource(`
		class Foo {
			kind: number;
			value: string;
		}
		function test(f: Foo): number {
			if (f !== null && f.kind === 1) {
				return 1;
			} else if (f !== null && f.kind === 2) {
				return 2;
			} else if (f !== null && f.kind === 3) {
				return 3;
			}
			return 0;
		}
	`);
	assert ctx !== null;
	assert errorCount(ctx) === 0;
}

// Test 5: Type alias as-cast should resolve fields
test "as cast with type alias resolves fields" {
	const ctx = checkSource(`
		type FooData = { name: string };
		interface Bar {
			data: object;
		}
		function test(b: Bar): string {
			const d = b.data as FooData;
			return d.name;
		}
	`);
	assert ctx !== null;
	assert errorCount(ctx) === 0;
}

// Test 6: Chained as-cast with union type
test "as cast on union member access" {
	const ctx = checkSource(`
		type MyData =
			| { value: number }
			| { name: string }
			;
		class MyNode {
			kind: number;
			data: MyData;
		}
		function test(n: MyNode): string {
			const d = n.data as { name: string };
			return d.name;
		}
	`);
	assert ctx !== null;
	assert errorCount(ctx) === 0;
}
