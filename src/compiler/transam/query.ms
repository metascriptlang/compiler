// Trans-Am Query — cache entry metadata and dependency tracking stack
//
// TaCacheEntry stores per-query verification state (red-green).
// TaDependencyStack provides frame-based automatic dependency recording:
//   when query A calls query B, B is auto-recorded as A's dependency.
//
// DRC-safe: all arrays wrapped in interfaces.

import { TaQueryKey, TaQueryKind, TaQueryState, TaDurability, createQueryKey, queryKeysEqual } from "./revision";
import { test, check, testGroup } from "std/testing";

// ===== Dependency Entry — "I depended on query X and saw output hash Y" =====

export interface TaDependencyEntry {
	depKey: TaQueryKey;
	expectedHash: number;
}

export interface TaDependencyList {
	items: TaDependencyEntry[];
}

// ===== Cache Entry — per-query metadata (NOT the result value) =====

export interface TaCacheEntry {
	key: TaQueryKey;
	state: TaQueryState;
	computedAt: number;       // revision when last computed
	verifiedAt: number;       // revision when last verified green
	durability: TaDurability;
	dependencies: TaDependencyList;
	outputHash: number;       // hash of the output (0 in Phase 1)
}

export function createCacheEntry(key: TaQueryKey): TaCacheEntry {
	return {
		key,
		state: TaQueryState.Red,
		computedAt: 0,
		verifiedAt: 0,
		durability: TaDurability.Low,
		dependencies: { items: [] },
		outputHash: 0,
	};
}

// ===== Dependency Frame — pushed when a query starts executing =====

export interface TaDependencyFrame {
	queryKey: TaQueryKey;
	deps: TaDependencyList;
	minDurability: TaDurability;
}

export interface TaFrameList {
	items: TaDependencyFrame[];
}

export interface TaDependencyStack {
	frames: TaFrameList;
}

// ===== Stack Operations =====

export function createDependencyStack(): TaDependencyStack {
	return { frames: { items: [] } };
}

export function pushFrame(stack: TaDependencyStack, key: TaQueryKey): void {
	const frame: TaDependencyFrame = {
		queryKey: key,
		deps: { items: [] },
		minDurability: TaDurability.High,  // starts at highest, lowered by deps
	};
	stack.frames.items.push(frame);
}

export function popFrame(stack: TaDependencyStack): TaDependencyFrame {
	return stack.frames.items.pop();
}

export function hasActiveFrame(stack: TaDependencyStack): boolean {
	return stack.frames.items.length > 0;
}

export function recordDependency(stack: TaDependencyStack, depKey: TaQueryKey, outputHash: number): void {
	if (stack.frames.items.length === 0) return;  // defensive
	const frame = stack.frames.items[stack.frames.items.length - 1];
	const entry: TaDependencyEntry = { depKey, expectedHash: outputHash };
	frame.deps.items.push(entry);
}

export function recordDurability(stack: TaDependencyStack, dur: TaDurability): void {
	if (stack.frames.items.length === 0) return;
	const frame = stack.frames.items[stack.frames.items.length - 1];
	// Durability enum: Low=0, Medium=1, High=2. Lower value = less stable.
	// Use equality checks since < on enums not supported by checker.
	if (dur === TaDurability.Low) {
		frame.minDurability = TaDurability.Low;
	} else if (dur === TaDurability.Medium && frame.minDurability === TaDurability.High) {
		frame.minDurability = TaDurability.Medium;
	}
}

// ===== Tests =====

testGroup("TaCacheEntry", () => {
	test("create starts Red", () => {
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(key);
		check(entry.state === TaQueryState.Red);
		check(entry.computedAt === 0);
		check(entry.verifiedAt === 0);
		check(entry.outputHash === 0);
	});
	test("dependencies start empty", () => {
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(key);
		check(entry.dependencies.items.length === 0);
	});
});

testGroup("TaDependencyStack", () => {
	test("starts empty", () => {
		const stack = createDependencyStack();
		check(!hasActiveFrame(stack));
	});
	test("push makes active", () => {
		const stack = createDependencyStack();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		pushFrame(stack, key);
		check(hasActiveFrame(stack));
	});
	test("pop returns frame", () => {
		const stack = createDependencyStack();
		const key = createQueryKey(TaQueryKind.Parse, 5);
		pushFrame(stack, key);
		const frame = popFrame(stack);
		check(queryKeysEqual(frame.queryKey, key));
		check(!hasActiveFrame(stack));
	});
	test("LIFO order", () => {
		const stack = createDependencyStack();
		const k1 = createQueryKey(TaQueryKind.Parse, 1);
		const k2 = createQueryKey(TaQueryKind.TypeCheck, 2);
		pushFrame(stack, k1);
		pushFrame(stack, k2);
		const f2 = popFrame(stack);
		check(queryKeysEqual(f2.queryKey, k2));
		const f1 = popFrame(stack);
		check(queryKeysEqual(f1.queryKey, k1));
	});
	test("record dependency adds to topmost frame", () => {
		const stack = createDependencyStack();
		const k1 = createQueryKey(TaQueryKind.Parse, 1);
		const k2 = createQueryKey(TaQueryKind.TypeCheck, 2);
		const depKey = createQueryKey(TaQueryKind.FileText, 1);
		pushFrame(stack, k1);
		pushFrame(stack, k2);
		recordDependency(stack, depKey, 999);
		const f2 = popFrame(stack);
		check(f2.deps.items.length === 1);
		check(queryKeysEqual(f2.deps.items[0].depKey, depKey));
		check(f2.deps.items[0].expectedHash === 999);
		const f1 = popFrame(stack);
		check(f1.deps.items.length === 0);
	});
	test("record on empty stack is no-op", () => {
		const stack = createDependencyStack();
		const depKey = createQueryKey(TaQueryKind.FileText, 0);
		recordDependency(stack, depKey, 0);
		check(!hasActiveFrame(stack));
	});
	test("minDurability tracks lowest", () => {
		const stack = createDependencyStack();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		pushFrame(stack, key);
		check(stack.frames.items[0].minDurability === TaDurability.High);
		recordDurability(stack, TaDurability.Medium);
		check(stack.frames.items[0].minDurability === TaDurability.Medium);
		recordDurability(stack, TaDurability.Low);
		check(stack.frames.items[0].minDurability === TaDurability.Low);
		recordDurability(stack, TaDurability.High);  // doesn't raise
		check(stack.frames.items[0].minDurability === TaDurability.Low);
		popFrame(stack);
	});
});
