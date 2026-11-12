import {
	Computation, NotReadyError, EFFECT_PURE, RUN_UNCHANGED, RUN_PUBLISHED, RUN_STAGED, STATUS_PENDING, READ_STAGED, READ_SNAPSHOT,
} from "./types";
import { Cell, Accessor, accessor, isEqual, untrack, servedSnapshot } from "./signal";
import { ServerContext, serverContext } from "./serverContext";
import {
	createComputed, readSource, isStaged, writeSource, beginFlight, landFlight, failFlight, markRefresh, wantsSnapshot, keepSnapshot,
} from "./runtime";

export interface MemoOptions<T> {
	equals?: ((a: T, b: T) => boolean) | false;
	lazy?: boolean;
	unobserved?: () => void;
}

class RefreshProbeStop extends Error {
	constructor() {
		super("[REFRESH_PROBE] a refresh target was read");
	}
}

let refreshProbing: boolean = false;
let refreshTarget: Computation | null = null;

async function watch<T>(promise: Promise<T>, done: (value: Cell<T> | null, failure: Error | null) => void): Promise<void> {
	let value: Cell<T> | null = null;
	let failure: Error | null = null;
	try {
		value = new Cell<T>(await promise);
	} catch (e) {
		failure = e;
	}
	done(value, failure);
}

when (server) {
	import { ServerSlot, sanitized } from "./serverContext";

	// A node made again at a slot still in flight lands the settled answer on itself, as the node that started the flight does (Solid server/signals.ts joins the flight and adopts it on settle).
	async function joinFlight<T>(slot: ServerSlot, self: Computation, flight: int32, landValue: (self: Computation, value: T) => void): Promise<void> {
		await slot.wait;
		if (slot.failure !== null) {
			failFlight(self, flight, slot.failure as Error);
		} else {
			landFlight(self, flight, (): void => landValue(self, (slot.cell as Cell<T>).value));
		}
	}

	function serverResult<T>(ctx: ServerContext, self: Computation, compute: (prev: T | null) => Promise<T>, prev: T | null, landValue: (self: Computation, value: T) => void): T {
		const id = self.id;
		if (id === null) { throw new Error("[SERVER_ASYNC_WITHOUT_ID] an async memo on the server needs an owner id; render it under a root that carries one"); }
		const known = ctx.slots.get(id);
		if (known !== null) {
			// A node made again runs its compute, then adopts the settled answer and drops the new flight: the answer, not the call, is what the render keeps (Solid server/signals.ts, `slot.s` branch before adoptSlot).
			watch<T>(compute(prev), (value: Cell<T> | null, failure: Error | null): void => {});
			if (known.failure !== null) { throw known.failure; }
			if (known.settled) { return (known.cell as Cell<T>).value; }
			joinFlight<T>(known, self, beginFlight(self), landValue);
			throw new NotReadyError(self);
		}
		const slot = new ServerSlot();
		ctx.slots.set(id, slot);
		ctx.started.push(id);
		const result = compute(prev);
		const flight = beginFlight(self);
		const land = (value: Cell<T> | null, failure: Error | null): void => {
			if (failure !== null) {
				failFlight(self, flight, failure);
			} else if (value !== null) {
				landFlight(self, flight, (): void => landValue(self, value.value));
			}
		};
		slot.wait = watch<T>(result, (value: Cell<T> | null, failure: Error | null): void => {
			settleSlot<T>(slot, value, failure);
			land(value, slot.failure);
		});
		throw new NotReadyError(self);
	}

	function settleSlot<T>(slot: ServerSlot, value: Cell<T> | null, failure: Error | null): void {
		if (failure !== null) {
			slot.failure = sanitized(failure);
		} else if (value !== null) {
			slot.json = JSON.stringify<T>(value.value);
			slot.cell = value as unknown;
		}
		slot.settled = true;
	}

	async function answerOf<T>(slot: ServerSlot): Promise<T> {
		await slot.wait;
		if (slot.failure !== null) { throw slot.failure; }
		return (slot.cell as Cell<T>).value;
	}

	export function serverQuery<T>(ctx: ServerContext, key: string, run: () => Promise<T>): Promise<T> {
		const known = ctx.slots.get(key);
		if (known !== null) { return answerOf<T>(known); }
		const slot = new ServerSlot();
		ctx.slots.set(key, slot);
		ctx.started.push(key);
		slot.wait = watch<T>(run(), (value: Cell<T> | null, failure: Error | null): void => settleSlot<T>(slot, value, failure));
		ctx.loops.push(slot.wait);
		return answerOf<T>(slot);
	}
}

export interface Adopter<T> {
	has: (id: string) => boolean;
	read: (id: string, trace: () => void) => T;
}

function awaitResult<T>(self: Computation, compute: (prev: T | null) => Promise<T>, prev: T | null, land: (self: Computation, value: T) => void, ctx: ServerContext | null, adopter: Adopter<T> | null): T {
	when (server) {
		if (ctx !== null) { return serverResult<T>(ctx, self, compute, prev, land); }
	}
	const adoptedId = self.id;
	if (adopter !== null && adoptedId !== null && adopter.has(adoptedId)) {
		return adopter.read(adoptedId, (): void => {
			watch<T>(compute(prev), (value: Cell<T> | null, failure: Error | null): void => {});
		});
	}
	const result = compute(prev);
	const id = beginFlight(self);
	watch<T>(result, (value: Cell<T> | null, failure: Error | null): void => {
		if (failure !== null) {
			failFlight(self, id, failure);
		} else if (value !== null) {
			landFlight(self, id, (): void => land(self, value.value));
		}
	});
	throw new NotReadyError(self);
}

function buildMemo<T>(produce: (self: Computation, prev: T | null, land: (self: Computation, value: T) => void) => T, options?: MemoOptions<T>): Accessor<T> {
	let cell: Cell<T> | null = null;
	let equals: ((a: T, b: T) => boolean) | null = null;
	let lazy = false;
	let hook: (() => void) | null = null;
	if (options !== undefined) {
		const given = options.equals;
		if (typeof given === "function") {
			equals = given;
		} else if (given === false) {
			equals = (a: T, b: T): boolean => false;
		}
		lazy = options.lazy === true;
		hook = options.unobserved === undefined ? null : options.unobserved;
	}

	const publishFirst = (self: Computation, value: T): Cell<T> => {
		const fresh = new Cell<T>(value);
		cell = fresh;
		self.commit = (): void => { fresh.value = fresh.pending; };
		return fresh;
	};

	const land = (self: Computation, value: T): void => {
		const held = cell;
		if (held === null) {
			publishFirst(self, value);
			writeSource(self, false);
			return;
		}
		const wasStaged = isStaged(self);
		if (isEqual(equals, wasStaged ? held.pending : held.value, value)) { return; }
		held.pending = value;
		writeSource(self, wasStaged);
	};

	const run = (self: Computation, create: boolean): int32 => {
		const held = cell;
		if (held === null) {
			publishFirst(self, produce(self, null, land));
			return RUN_PUBLISHED;
		}
		const prev = isStaged(self) ? held.pending : held.value;
		const next = produce(self, prev, land);
		if (isEqual(equals, prev, next)) { return RUN_UNCHANGED; }
		if (create) {
			held.value = next;
			held.pending = next;
			return RUN_PUBLISHED;
		}
		held.pending = next;
		return RUN_STAGED;
	};
	const node = createComputed(run, EFFECT_PURE, lazy, false, hook);
	const first: Cell<T> | null = cell;
	if (first !== null && wantsSnapshot(node) && (node.status & STATUS_PENDING) === 0) {
		keepSnapshot(node, new Cell<T>(first.value) as unknown);
	}

	return accessor((): T => {
		if (refreshProbing) {
			refreshTarget = node;
			throw new RefreshProbeStop();
		}
		const read = readSource(node);
		const held = cell;
		if (held === null) {
			throw new Error("Memo accessed before initialization");
		}
		if (read === READ_SNAPSHOT) { return servedSnapshot<T>(node, isStaged(node) ? held.pending : held.value); }
		return read === READ_STAGED ? held.pending : held.value;
	});
}

export function createMemo<T>(compute: (prev: T | null) => T, options?: MemoOptions<T>): Accessor<T> {
	return buildMemo<T>((self: Computation, prev: T | null, land: (self: Computation, value: T) => void): T => compute(prev), options);
}

// Parked on ~/metascript/.inbox/compiler/2026-10-16-t-is-not-inferred-from-a-value-through-a-generic-instance-or-t-union.md and 2026-10-16-instanceof-a-generic-class-refuses-a-union-operand-instead-of-narrowing-it.md: Solid 2.0 has one `createMemo` whose compute returns `Promise<T> | T`; this engine entry is not exported and merges into it.
export function createAsyncMemo<T>(compute: (prev: T | null) => Promise<T>, options?: MemoOptions<T>, adopter?: Adopter<T>): Accessor<T> {
	const ctx = serverContext();
	const adopting = adopter === undefined ? null : adopter;
	return buildMemo<T>((self: Computation, prev: T | null, land: (self: Computation, value: T) => void): T => awaitResult<T>(self, compute, prev, land, ctx, adopting), options);
}

export function refresh<T>(target: Accessor<T>): void {
	refreshProbing = true;
	refreshTarget = null;
	try {
		untrack((): T => target());
	} catch (e) {
		if (!(e instanceof RefreshProbeStop)) { throw e; }
	} finally {
		refreshProbing = false;
	}
	const node = refreshTarget;
	refreshTarget = null;
	if (node !== null) { markRefresh(node); }
}
