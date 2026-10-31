// Trans-Am Query — cache entry metadata and dependency tracking stack
//
// TaCacheEntry stores per-query verification state (red-green).
// TaDependencyStack provides frame-based automatic dependency recording:
//   when query A calls query B, B is auto-recorded as A's dependency.
//
// Arrays passed by pointer — bare T[] types.

import { TaQueryKey, TaQueryKind, TaQueryState, TaDurability, createQueryKey, queryKeysEqual } from "./revision";


// ===== Cache Entry — per-query metadata (NOT the result value) =====

export class TaCacheEntry {
	key: TaQueryKey;
	state: TaQueryState;
	accessedAt: int32;      // cache clock at last get or put, for LRU eviction
	computedAt: int32;      // revision when last computed
	verifiedAt: int32;      // revision when last verified green
	durability: TaDurability;
	changedAt: int32;
	dependencies: TaQueryKey[];
}

export function createCacheEntry(key: TaQueryKey): TaCacheEntry {
	return {
		key,
		state: TaQueryState.Red,
		accessedAt: 0,
		computedAt: 0,
		verifiedAt: 0,
		durability: TaDurability.Low,
		changedAt: 0,
		dependencies: [],
	};
}

// ===== Dependency Frame — pushed when a query starts executing =====

class TaDependencyFrame {
	queryKey: TaQueryKey;
	deps: TaQueryKey[];
	minDurability: TaDurability;
}

export class TaDependencyStack {
	frames: TaDependencyFrame[];
}

// ===== Stack Operations =====

export function createDependencyStack(): TaDependencyStack {
	return { frames: [] };
}

export function pushFrame(stack: TaDependencyStack, key: TaQueryKey): void {
	const frame: TaDependencyFrame = {
		queryKey: key,
		deps: [],
		minDurability: TaDurability.High,  // starts at highest, lowered by deps
	};
	stack.frames.push(frame);
}

export function popFrame(stack: TaDependencyStack): TaDependencyFrame {
	return stack.frames.pop();
}

export function hasActiveFrame(stack: TaDependencyStack): boolean {
	return stack.frames.length > 0;
}

function topFrame(stack: TaDependencyStack, what: string): TaDependencyFrame {
	if (stack.frames.length == 0) throw new Error(`internal: ${what} with no query frame active`);
	return stack.frames[stack.frames.length - 1];
}

export function recordDependency(stack: TaDependencyStack, depKey: TaQueryKey): void {
	topFrame(stack, "a dependency is recorded").deps.push(depKey);
}

export function recordDurability(stack: TaDependencyStack, dur: TaDurability): void {
	const frame = topFrame(stack, "a durability is recorded");
	// Durability enum: Low=0, Medium=1, High=2. Lower value = less stable.
	// Use equality checks since < on enums not supported by checker.
	if (dur == TaDurability.Low) {
		frame.minDurability = TaDurability.Low;
	} else if (dur == TaDurability.Medium) {
		if (frame.minDurability == TaDurability.High) {
			frame.minDurability = TaDurability.Medium;
		}
	}
}

// ===== Tests =====
test "create starts Red" {
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	assert entry.state == TaQueryState.Red;
	assert entry.computedAt == 0;
	assert entry.verifiedAt == 0;
	assert entry.changedAt == 0;
}

test "dependencies start empty" {
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	assert entry.dependencies.length == 0;
}

test "starts empty" {
	const stack = createDependencyStack();
	assert !hasActiveFrame(stack);
}

test "push makes active" {
	const stack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	pushFrame(stack, key);
	assert hasActiveFrame(stack);
}

test "pop returns frame" {
	const stack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.Parse, 5);
	pushFrame(stack, key);
	const frame = popFrame(stack);
	assert queryKeysEqual(frame.queryKey, key);
	assert !hasActiveFrame(stack);
}

test "LIFO order" {
	const stack = createDependencyStack();
	const k1 = createQueryKey(TaQueryKind.Parse, 1);
	const k2 = createQueryKey(TaQueryKind.TypeCheck, 2);
	pushFrame(stack, k1);
	pushFrame(stack, k2);
	const f2 = popFrame(stack);
	assert queryKeysEqual(f2.queryKey, k2);
	const f1 = popFrame(stack);
	assert queryKeysEqual(f1.queryKey, k1);
}

test "record dependency adds to topmost frame" {
	const stack = createDependencyStack();
	const k1 = createQueryKey(TaQueryKind.Parse, 1);
	const k2 = createQueryKey(TaQueryKind.TypeCheck, 2);
	const depKey = createQueryKey(TaQueryKind.FileText, 1);
	pushFrame(stack, k1);
	pushFrame(stack, k2);
	recordDependency(stack, depKey);
	const f2 = popFrame(stack);
	assert f2.deps.length == 1;
	assert queryKeysEqual(f2.deps[0], depKey);
	const f1 = popFrame(stack);
	assert f1.deps.length == 0;
}

test "minDurability tracks lowest" {
	const stack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	pushFrame(stack, key);
	assert stack.frames[0].minDurability == TaDurability.High;
	recordDurability(stack, TaDurability.Medium);
	assert stack.frames[0].minDurability == TaDurability.Medium;
	recordDurability(stack, TaDurability.Low);
	assert stack.frames[0].minDurability == TaDurability.Low;
	recordDurability(stack, TaDurability.High);  // doesn't raise
	assert stack.frames[0].minDurability == TaDurability.Low;
	popFrame(stack);
}

test "recording a dependency or a durability with no frame active fails loud" {
	const stack = createDependencyStack();
	const depKey = createQueryKey(TaQueryKind.FileText, 0);
	let dependency = "";
	try { recordDependency(stack, depKey); } catch (e) { dependency = (e as Error).message; }
	assert dependency == "internal: a dependency is recorded with no query frame active", dependency;
	let durability = "";
	try { recordDurability(stack, TaDurability.Low); } catch (e) { durability = (e as Error).message; }
	assert durability == "internal: a durability is recorded with no query frame active", durability;
}

test "recording after the last frame was popped fails loud" {
	const stack = createDependencyStack();
	pushFrame(stack, createQueryKey(TaQueryKind.Parse, 0));
	popFrame(stack);
	let message = "";
	try { recordDependency(stack, createQueryKey(TaQueryKind.FileText, 0)); } catch (e) { message = (e as Error).message; }
	assert message == "internal: a dependency is recorded with no query frame active", message;
}
