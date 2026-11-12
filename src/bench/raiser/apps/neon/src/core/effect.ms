import { Computation, Cleanup, EFFECT_RENDER, EFFECT_USER, RUN_UNCHANGED, STATUS_ERROR } from "./types";
import { createEffectNode, startEffect, isDisposed, onServer, getOwner, createOwner, carriesId, getNextChildId } from "./runtime";
import { runWithOwner } from "./owner";
import { Cell } from "./signal";
when (debug) { import { swapStrictLabel } from "./runtime"; }

export interface EffectOptions {
	defer?: boolean;
	transparent?: boolean;
}

// parked: the reference returns Cleanup | void; ~/metascript/.inbox/compiler/2026-10-15-void-member-of-a-union-passes-the-checker-and-dies-at-clang.md
export interface EffectBundle<T> {
	effect: (value: T, prev: T | null) => Cleanup | null;
	error: (err: Error, cleanup: Cleanup) => void;
}

class EffectState<T> {
	latest: Cell<T> | null = null;
	applied: T | null = null;
}

function computePhase<T>(state: EffectState<T>, compute: (prev: T | null) => T): (self: Computation, create: boolean) => int32 {
	return (self: Computation, create: boolean): int32 => {
		const held = state.latest;
		if (held === null) {
			state.latest = new Cell<T>(compute(null));
		} else {
			held.value = compute(held.value);
		}
		return RUN_UNCHANGED;
	};
}

function effectPhase<T>(
	state: EffectState<T>,
	effect: (value: T, prev: T | null) => Cleanup | null,
	onError: ((err: Error, cleanup: Cleanup) => void) | null,
): (self: Computation) => void {
	return (self: Computation): void => {
		const held = state.latest;
		const failure = (self.status & STATUS_ERROR) !== 0 ? self.error : null;
		if (failure !== null) {
			if (held !== null) { state.applied = held.value; }
			if (onError === null) {
				console.error(failure);
				return;
			}
			onError(failure, (): void => {
				const last = self.cleanup;
				self.cleanup = null;
				if (last !== null) { last(); }
			});
			return;
		}
		if (held === null) { throw new Error("effect applied before its compute produced a value"); }
		const prev = state.applied;
		state.applied = held.value;
		const last = self.cleanup;
		self.cleanup = null;
		if (last !== null) { last(); }
		const next = effect(held.value, prev);
		if (isDisposed(self)) {
			if (next !== null) { next(); }
		} else {
			self.cleanup = next;
		}
	};
}

function serverEffect<T>(compute: (prev: T | null) => T, effect: ((value: T, prev: T | null) => Cleanup | null) | null, defer: boolean): void {
	const owner = createOwner();
	when (debug) { const prevLabel = swapStrictLabel(null); }
	try {
		const value = runWithOwner(owner, (): T => compute(null));
		if (effect !== null && !defer) { effect(value, null); }
	} finally {
		when (debug) { swapStrictLabel(prevLabel); }
	}
}

export function createEffect<T>(
	compute: (prev: T | null) => T,
	effect: ((value: T, prev: T | null) => Cleanup | null) | EffectBundle<T>,
	options?: EffectOptions,
): void {
	const transparent = options !== undefined && options.transparent === true;
	const defer = options !== undefined && options.defer === true;
	if (onServer()) {
		serverEffect<T>(compute, null, defer);
		return;
	}
	const state = new EffectState<T>();
	let node: Computation;
	if (typeof effect === "function") {
		node = createEffectNode(computePhase<T>(state, compute), effectPhase<T>(state, effect, null), EFFECT_USER, transparent);
	} else {
		node = createEffectNode(computePhase<T>(state, compute), effectPhase<T>(state, effect.effect, effect.error), EFFECT_USER, transparent);
	}
	startEffect(node, defer);
}

export function createRenderEffect<T>(
	compute: (prev: T | null) => T,
	effect: (value: T, prev: T | null) => Cleanup | null,
	options?: EffectOptions,
): void {
	const transparent = options !== undefined && options.transparent === true;
	const defer = options !== undefined && options.defer === true;
	if (onServer()) {
		serverEffect<T>(compute, effect, defer);
		return;
	}
	const state = new EffectState<T>();
	const node = createEffectNode(computePhase<T>(state, compute), effectPhase<T>(state, effect, null), EFFECT_RENDER, transparent);
	startEffect(node, defer);
}

export function onSettled(callback: () => Cleanup | null): void {
	const owner = getOwner();
	if (onServer()) {
		if (carriesId(owner)) { getNextChildId(owner as Computation); }
		return;
	}
	const owned = owner !== null;
	createEffect<boolean>(
		(prev: boolean | null): boolean => true,
		(value: boolean, prev: boolean | null): Cleanup | null => {
			const cleanup = callback();
			if (!owned && cleanup !== null) {
				throw new Error("[SETTLED_CLEANUP_UNOWNED] onSettled returned a cleanup in an unowned scope; a cleanup can only be honored under an owner. Call it from a component or root.");
			}
			return cleanup;
		},
	);
}
