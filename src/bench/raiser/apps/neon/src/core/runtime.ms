import {
	Computation, Source, Link, NotReadyError,
	REACTIVE_CHECK, REACTIVE_DIRTY, REACTIVE_RECOMPUTING_DEPS, REACTIVE_IN_HEAP, REACTIVE_IN_HEAP_HEIGHT,
	REACTIVE_DISPOSED, REACTIVE_LAZY, REACTIVE_MISSED_WAKE, REACTIVE_REASK, REACTIVE_PROBED, REACTIVE_SNAPSHOT_STALE,
	STATUS_PENDING, STATUS_ERROR, STATUS_UNINITIALIZED,
	CONFIG_OWNED_WRITE, CONFIG_TRANSPARENT, CONFIG_AUTO_DISPOSE, CONFIG_STAGED, CONFIG_PROMOTED, CONFIG_ROOT, CONFIG_MODIFIED,
	CONFIG_DORMANT_QUEUED, CONFIG_VERDICT, CONFIG_REDERIVE, EFFECT_PURE, EFFECT_RENDER, EFFECT_USER, RUN_UNCHANGED, RUN_STAGED,
	CONFIG_IN_SNAPSHOT_SCOPE, CONFIG_HAS_SNAPSHOT, CONFIG_NO_SNAPSHOT, CONFIG_SNAPSHOT_SCOPE, READ_VALUE, READ_STAGED, READ_SNAPSHOT,
} from "./types";

const LOOP_LIMIT: int32 = 100000;
when (debug) {
	const OWNED_WRITE_MESSAGE: string = "[REACTIVE_WRITE_IN_OWNED_SCOPE] Writing to reactive state inside an owned scope (component, computation) is not allowed. Move the write outside or set the `ownedWrite` option if this is intentional.";
	const REFRESH_OWNED_MESSAGE: string = "[REACTIVE_WRITE_IN_OWNED_SCOPE] Calling refresh() inside an owned scope (component, computation) is not allowed. Move the invalidation outside pure computation.";
	let strictLabel: string | null = null;

	export function swapStrictLabel(label: string | null): string | null {
		const prev = strictLabel;
		strictLabel = label;
		return prev;
	}

	function assertTrackedRead(el: Source): void {
		const label = strictLabel;
		if (label === null) { return; }
		if (el.computed) {
			const status = (el as Computation).status;
			if ((status & STATUS_PENDING) !== 0) {
				throw new Error("[PENDING_ASYNC_UNTRACKED_READ] Reading a pending async value directly in " + label + ". Async values must be read within a tracking scope (JSX, a memo, or an effect's compute function).");
			}
			if ((status & STATUS_ERROR) !== 0) { return; }
		}
		throw new Error("[STRICT_READ_UNTRACKED] Reactive value read directly in " + label + " will not update. Move it into a tracking scope (JSX, a memo, or an effect's compute function).");
	}
}

let currentOwner: Computation | null = null;
let tracking: boolean = false;
let scheduled: boolean = false;
let running: boolean = false;
let syncDepth: int32 = 0;
let unflushedStaged: boolean = false;
let dormantPending: boolean = false;
let serverDepth: int32 = 0;
let halted: boolean = false;
let haltNotified: boolean = false;
let flightCounter: int32 = 0;
let walkEpoch: int32 = 0;
let clock: int32 = 0;
let walkScheduled: boolean = false;
let verdictOpen: boolean = false;
let latestActive: boolean = false;
let probing: boolean = false;
let probeFound: boolean = false;

export interface SnapshotStore {
	keep: (el: Source, cell: unknown) => void;
	kept: (el: Source) => unknown;
}

let snapshots: SnapshotStore | null = null;

let heapHead: (Computation | null)[] = [null];
let heapTail: (Computation | null)[] = [null];
let heapMin: int32 = 0;
let heapMax: int32 = 0;
let heapMarked: boolean = false;

let pendingNodes: Source[] = [];
let promotedWrites: Source[] = [];
let dormantNodes: Computation[] = [];
let renderQueue: Computation[] = [];
let userQueue: Computation[] = [];

export function getOwner(): Computation | null { return currentOwner; }
export function setOwner(o: Computation | null): void { currentOwner = o; }
export function isTracking(): boolean { return tracking; }
export function setTracking(t: boolean): void { tracking = t; }
export function onServer(): boolean { return serverDepth > 0; }
export function getServerDepth(): number { return serverDepth; }
export function setServerDepth(d: number): void { serverDepth = d as int32; }
export function isServer(): boolean { return onServer(); }

export function asServer<T>(run: () => T): T {
	const depth = getServerDepth();
	setServerDepth(depth + 1);
	try {
		return run();
	} finally {
		setServerDepth(depth);
	}
}

export function isStaged(el: Source): boolean { return (el.config & CONFIG_STAGED) !== 0; }
export function isDisposed(node: Computation): boolean { return (node.flags & REACTIVE_DISPOSED) !== 0; }

export function newSource(config: int32): Source {
	return new Source(config, false);
}

function growHeap(height: int32): void {
	while (heapHead.length <= height) {
		heapHead.push(null);
		heapTail.push(null);
	}
}

function actualInsertIntoHeap(n: Computation): void {
	const parent = n.parent;
	let parentHeight: int32 = -1;
	if (parent !== null) {
		const via = (parent.config & CONFIG_ROOT) !== 0 ? parent.parentComputed : parent;
		if (via !== null) { parentHeight = via.height; }
	}
	if (parentHeight >= n.height) { n.height = parentHeight + 1; }
	const height = n.height;
	growHeap(height);
	const tail = heapTail[height];
	n.nextHeap = null;
	n.prevHeap = tail;
	if (tail === null) { heapHead[height] = n; } else { tail.nextHeap = n; }
	heapTail[height] = n;
	if (height > heapMax) { heapMax = height; }
}

function insertIntoHeap(n: Computation): void {
	const flags = n.flags;
	if ((flags & (REACTIVE_IN_HEAP | REACTIVE_RECOMPUTING_DEPS)) !== 0) { return; }
	if ((flags & REACTIVE_CHECK) !== 0) {
		n.flags = (flags & ~(REACTIVE_CHECK | REACTIVE_DIRTY)) | REACTIVE_DIRTY | REACTIVE_IN_HEAP;
	} else {
		n.flags = flags | REACTIVE_IN_HEAP;
		if (heapMarked) { markNode(n, REACTIVE_DIRTY); }
	}
	if ((flags & REACTIVE_IN_HEAP_HEIGHT) === 0) { actualInsertIntoHeap(n); }
}

function insertIntoHeapHeight(n: Computation): void {
	const flags = n.flags;
	if ((flags & (REACTIVE_IN_HEAP | REACTIVE_RECOMPUTING_DEPS | REACTIVE_IN_HEAP_HEIGHT)) !== 0) { return; }
	n.flags = flags | REACTIVE_IN_HEAP_HEIGHT;
	actualInsertIntoHeap(n);
}

function deleteFromHeap(n: Computation): void {
	const flags = n.flags;
	if ((flags & (REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT)) === 0) { return; }
	n.flags = flags & ~(REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT);
	const height = n.height;
	const prev = n.prevHeap;
	const next = n.nextHeap;
	if (prev !== null) { prev.nextHeap = next; } else { heapHead[height] = next; }
	if (next !== null) { next.prevHeap = prev; } else { heapTail[height] = prev; }
	n.prevHeap = null;
	n.nextHeap = null;
}

function markNode(el: Computation, newState: int32): void {
	const flags = el.flags;
	if ((flags & (REACTIVE_CHECK | REACTIVE_DIRTY)) >= newState) { return; }
	el.flags = (flags & ~(REACTIVE_CHECK | REACTIVE_DIRTY)) | newState;
	for (let l = el.subs; l !== null; l = l.nextSub) {
		markNode(l.sub, REACTIVE_CHECK);
	}
}

function markHeap(): void {
	if (heapMarked) { return; }
	heapMarked = true;
	for (let i = 0; i <= heapMax; i += 1) {
		for (let el = heapHead[i]; el !== null; el = el.nextHeap) {
			if ((el.flags & REACTIVE_IN_HEAP) !== 0) { markNode(el, REACTIVE_DIRTY); }
		}
	}
}

function adjustHeight(el: Computation): void {
	deleteFromHeap(el);
	let newHeight = el.height;
	for (let d = el.deps; d !== null; d = d.nextDep) {
		const dep = d.dep;
		if (dep.computed) {
			const depHeight = (dep as Computation).height;
			if (depHeight >= newHeight) { newHeight = depHeight + 1; }
		}
	}
	if (el.height !== newHeight) {
		el.height = newHeight;
		for (let s = el.subs; s !== null; s = s.nextSub) { insertIntoHeapHeight(s.sub); }
	}
}

function runHeap(): void {
	heapMarked = false;
	for (heapMin = 0; heapMin <= heapMax; heapMin += 1) {
		let el = heapHead[heapMin];
		while (el !== null) {
			if ((el.flags & REACTIVE_IN_HEAP) !== 0) { recompute(el, false); } else { adjustHeight(el); }
			el = heapHead[heapMin];
		}
	}
	heapMax = 0;
}

function enqueueSub(node: Computation): void {
	if (heapMin > node.height) { heapMin = node.height; }
	insertIntoHeap(node);
}

function insertSubs(node: Source): void {
	const held = (node.config & CONFIG_HAS_SNAPSHOT) !== 0;
	for (let s = node.subs; s !== null; s = s.nextSub) {
		const sub = s.sub;
		if ((sub.flags & REACTIVE_RECOMPUTING_DEPS) !== 0 && s.gen === sub.depGen && s !== sub.depsTail) {
			sub.flags = sub.flags | REACTIVE_MISSED_WAKE;
		}
		if (held && (sub.config & CONFIG_IN_SNAPSHOT_SCOPE) !== 0) {
			sub.flags = sub.flags | REACTIVE_SNAPSHOT_STALE;
			continue;
		}
		enqueueSub(sub);
	}
}

function unlinkSubs(l: Link): Link | null {
	const dep = l.dep;
	const nextDep = l.nextDep;
	const nextSub = l.nextSub;
	const prevSub = l.prevSub;
	if (nextSub !== null) { nextSub.prevSub = prevSub; } else { dep.subsTail = prevSub; }
	if (prevSub !== null) {
		prevSub.nextSub = nextSub;
	} else {
		dep.subs = nextSub;
		if (nextSub === null && dep.computed) {
			const c = dep as Computation;
			const hook = c.unobserved;
			if (hook !== null) { hook(); }
			if ((c.config & CONFIG_AUTO_DISPOSE) !== 0) { unobserved(c); }
		}
	}
	return nextDep;
}

function trimStaleDeps(el: Computation): void {
	const depsTail = el.depsTail;
	let toRemove = depsTail !== null ? depsTail.nextDep : el.deps;
	if (toRemove !== null) {
		while (toRemove !== null) { toRemove = unlinkSubs(toRemove); }
		if (depsTail !== null) { depsTail.nextDep = null; } else { el.deps = null; }
	}
}

function clearDeps(el: Computation): void {
	let dep = el.deps;
	if (dep === null) { return; }
	while (dep !== null) { dep = unlinkSubs(dep); }
	el.deps = null;
	el.depsTail = null;
}

function unobserved(el: Computation): void {
	deleteFromHeap(el);
	clearDeps(el);
	disposeChildren(el, true);
}

function sweepDormant(): void {
	dormantPending = false;
	if (dormantNodes.length === 0) { return; }
	const nodes = dormantNodes;
	dormantNodes = [];
	for (const el of nodes) {
		el.config = el.config & ~CONFIG_DORMANT_QUEUED;
		if (el.subs === null && (el.config & CONFIG_AUTO_DISPOSE) !== 0 && (el.flags & REACTIVE_DISPOSED) === 0) {
			unobserved(el);
		}
	}
}

function link(dep: Source, sub: Computation): void {
	const prevDep = sub.depsTail;
	if (prevDep !== null && prevDep.dep === dep) { return; }
	let nextDep: Link | null = null;
	const isRecomputing = (sub.flags & REACTIVE_RECOMPUTING_DEPS) !== 0;
	if (isRecomputing) {
		nextDep = prevDep !== null ? prevDep.nextDep : sub.deps;
		if (nextDep !== null && nextDep.dep === dep) {
			nextDep.gen = sub.depGen;
			sub.depsTail = nextDep;
			return;
		}
	}
	const prevSub = dep.subsTail;
	if (prevSub !== null && prevSub.sub === sub && (!isRecomputing || prevSub.gen === sub.depGen)) { return; }
	const newLink: Link = { dep, sub, nextDep, prevSub, nextSub: null, gen: sub.depGen };
	sub.depsTail = newLink;
	dep.subsTail = newLink;
	if (prevDep !== null) { prevDep.nextDep = newLink; } else { sub.deps = newLink; }
	if (prevSub !== null) { prevSub.nextSub = newLink; } else { dep.subs = newLink; }
}

function formatId(prefix: string, index: number): string {
	const digits = index.toString(36);
	const extra = digits.length - 1;
	return prefix + (extra > 0 ? String.fromCharCode(64 + extra) : "") + digits;
}

function idCounter(owner: Computation): Computation {
	let counter = owner;
	while ((counter.config & CONFIG_TRANSPARENT) !== 0 && counter.parent !== null) { counter = counter.parent as Computation; }
	return counter;
}

export function carriesId(owner: Computation | null): boolean {
	return owner !== null && idCounter(owner).id !== null;
}

export function getNextChildId(owner: Computation): string {
	const counter = idCounter(owner);
	const id = counter.id;
	if (id === null) { throw new Error("getNextChildId: the owner carries no id"); }
	const index = counter.childCount;
	counter.childCount = index + 1;
	return formatId(id as string, index);
}

export function inheritId(parent: Computation | null, transparent: boolean): string | null {
	if (parent === null) { return null; }
	if (transparent) { return parent.id; }
	return carriesId(parent) ? getNextChildId(parent) : null;
}

function linkChild(parent: Computation, node: Computation): void {
	const head = parent.firstChild;
	node.prevSibling = null;
	node.nextSibling = head;
	if (head !== null) { head.prevSibling = node; }
	parent.firstChild = node;
}

function runDisposal(node: Computation): void {
	const list = node.disposal;
	if (list === null) { return; }
	node.disposal = null;
	for (let i = list.length - 1; i >= 0; i -= 1) { list[i](); }
}

export function disposeChildren(node: Computation, self: boolean): void {
	const flags = node.flags;
	if ((flags & REACTIVE_DISPOSED) !== 0) { return; }
	if (self) {
		node.flags = flags | REACTIVE_DISPOSED;
		node.flight = 0;
	}
	let child = node.firstChild;
	node.firstChild = null;
	while (child !== null) {
		child.config = child.config & ~CONFIG_AUTO_DISPOSE;
		deleteFromHeap(child);
		clearDeps(child);
		child.parent = null;
		disposeChildren(child, true);
		const next = child.nextSibling;
		child.nextSibling = null;
		child.prevSibling = null;
		child = next;
	}
	node.childCount = 0;
	const parent = node.parent;
	if (self && parent !== null && (parent.flags & REACTIVE_DISPOSED) === 0) {
		const prev = node.prevSibling;
		const next = node.nextSibling;
		if (prev !== null) { prev.nextSibling = next; } else { parent.firstChild = next; }
		if (next !== null) { next.prevSibling = prev; }
		node.prevSibling = null;
		node.nextSibling = null;
	}
	runDisposal(node);
	if (self) {
		const last = node.cleanup;
		if (last !== null) {
			node.cleanup = null;
			last();
		}
	}
}

export function disposeNode(node: Computation): void {
	node.config = node.config & ~CONFIG_AUTO_DISPOSE;
	unobserved(node);
	node.parent = null;
	node.run = null;
	node.apply = null;
}

export type StatusRoute = (node: Computation, flags: int32, error: Error | null) => boolean;

let statusRoute: StatusRoute | null = null;
let boundarySweep: (() => void) | null = null;
let heldRun: ((node: Computation) => boolean) | null = null;

export function installBoundaryHooks(route: StatusRoute, sweep: () => void, held: (node: Computation) => boolean): void {
	statusRoute = route;
	boundarySweep = sweep;
	heldRun = held;
}

export function requeueEffect(node: Computation): void {
	if (node.type === EFFECT_RENDER) { renderQueue.push(node); } else { userQueue.push(node); }
}

function routeStatus(node: Computation, flags: int32, error: Error | null): boolean {
	const route = statusRoute;
	return route !== null && route(node, flags, error);
}

function sweepBoundaries(): void {
	const sweep = boundarySweep;
	if (sweep !== null) { sweep(); }
}

export function linkDependency(dep: Source, sub: Computation): void { link(dep, sub); }

export function recomputeNode(node: Computation): void { recompute(node, false); }

export function wakeNode(node: Computation): void {
	enqueueSub(node);
	schedule();
}

export function requestFlush(): void { schedule(); }

function hasPendingSource(el: Computation, source: Computation): boolean {
	const list = el.pendingSources;
	if (list === null) { return false; }
	for (const s of list) {
		if (s === source) { return true; }
	}
	return false;
}

function addPendingSource(el: Computation, source: Computation): void {
	const list = el.pendingSources;
	if (list === null) {
		el.pendingSources = [source];
		return;
	}
	for (const s of list) {
		if (s === source) { return; }
	}
	list.push(source);
}

function removePendingSource(el: Computation, source: Computation): boolean {
	const list = el.pendingSources;
	if (list === null) { return false; }
	const rest: Computation[] = [];
	for (const s of list) {
		if (s !== source) { rest.push(s); }
	}
	if (rest.length === list.length) { return false; }
	el.pendingSources = rest.length === 0 ? null : rest;
	return true;
}

function statusError(el: Computation): Error {
	const error = el.error;
	if (error === null) { throw new Error("[STATUS_WITHOUT_ERROR] a node is pending or errored but holds no error to throw"); }
	return error;
}

function setPendingError(el: Computation, source: Computation | null, error: Error | null): void {
	if (source === null) {
		el.error = null;
		return;
	}
	if (error !== null && error instanceof NotReadyError && (error as NotReadyError).source === source) {
		el.error = error;
		return;
	}
	const current = el.error;
	if (current === null || !(current instanceof NotReadyError) || (current as NotReadyError).source !== source) {
		el.error = new NotReadyError(source);
	}
}

function clearStatus(el: Computation): void {
	el.pendingSources = null;
	el.blocked = false;
	el.status = 0;
	el.error = null;
}

function landStatus(el: Computation): void {
	removePendingSource(el, el);
	const rest = el.pendingSources;
	if (rest === null) {
		clearStatus(el);
		return;
	}
	el.blocked = false;
	el.status = STATUS_PENDING;
	setPendingError(el, rest[0], null);
}

function notifyStatus(el: Computation, error: Error): void {
	if (error instanceof NotReadyError) {
		const source = (error as NotReadyError).source;
		addPendingSource(el, source);
		el.status = STATUS_PENDING | (el.status & STATUS_UNINITIALIZED);
		setPendingError(el, source, error);
	} else {
		el.pendingSources = null;
		el.status = STATUS_ERROR;
		el.error = error;
	}
	propagateStatus(el, error);
}

function propagateStatus(el: Computation, error: Error): void {
	const pending = error instanceof NotReadyError;
	for (let l = el.subs; l !== null; l = l.nextSub) {
		const sub = l.sub;
		sub.time = clock;
		if ((sub.config & (CONFIG_VERDICT | CONFIG_REDERIVE)) !== 0 || (pending && l.gen !== sub.depGen) || (!pending && sub.type !== EFFECT_PURE)) {
			enqueueSub(sub);
			scheduled = true;
			continue;
		}
		if (pending) {
			if (hasPendingSource(sub, (error as NotReadyError).source)) { continue; }
			notifyStatus(sub, error);
		} else if (sub.error !== error || sub.pendingSources !== null) {
			notifyStatus(sub, error);
		}
	}
}

function retryReaches(el: Computation, source: Computation): boolean {
	for (let d = el.deps; d !== null; d = d.nextDep) {
		const dep = d.dep;
		if (dep === source) { return true; }
		if (dep.computed && hasPendingSource(dep as Computation, source)) { return true; }
	}
	return false;
}

function settleNode(node: Computation, el: Computation, source: Computation): void {
	if (node.visitedAt === walkEpoch) { return; }
	if ((source !== el && retryReaches(node, source)) || !removePendingSource(node, source)) {
		if ((node.config & CONFIG_VERDICT) !== 0) {
			enqueueSub(node);
			walkScheduled = true;
		}
		return;
	}
	node.visitedAt = walkEpoch;
	node.time = clock;
	const list = node.pendingSources;
	const errored = (node.status & STATUS_ERROR) !== 0;
	if (list !== null) {
		if (!errored) { setPendingError(node, list[0], null); }
	} else {
		node.status = node.status & ~STATUS_PENDING;
		if (!errored) { node.error = null; }
		if (node.blocked) {
			enqueueSub(node);
			walkScheduled = true;
		}
		node.blocked = false;
	}
	for (let l = node.subs; l !== null; l = l.nextSub) { settleNode(l.sub, el, source); }
}

function settlePendingSource(el: Computation, source: Computation): void {
	removePendingSource(el, source);
	walkEpoch += 1;
	walkScheduled = false;
	for (let l = el.subs; l !== null; l = l.nextSub) { settleNode(l.sub, el, source); }
	if (walkScheduled) { scheduled = true; }
}

function sweepErrored(node: Computation, error: Error): void {
	if (node.visitedAt === walkEpoch) { return; }
	node.visitedAt = walkEpoch;
	if (node.error === error) {
		enqueueSub(node);
		walkScheduled = true;
	}
	for (let l = node.subs; l !== null; l = l.nextSub) { sweepErrored(l.sub, error); }
}

function settleErroredDependents(el: Computation, error: Error): void {
	walkEpoch += 1;
	walkScheduled = false;
	for (let l = el.subs; l !== null; l = l.nextSub) { sweepErrored(l.sub, error); }
	if (walkScheduled) { scheduled = true; }
}

export function beginFlight(el: Computation): int32 {
	flightCounter += 1;
	el.flight = flightCounter;
	el.pendingSources = null;
	return flightCounter;
}

export function landFlight(el: Computation, id: int32, write: () => void): void {
	if (el.flight !== id || (el.flags & REACTIVE_DIRTY) !== 0) { return; }
	el.flight = 0;
	flush((): void => {
		landStatus(el);
		write();
		settlePendingSource(el, el);
		scheduled = true;
	});
}

export function failFlight(el: Computation, id: int32, error: Error): void {
	if (el.flight !== id) { return; }
	el.flight = 0;
	flush((): void => {
		notifyStatus(el, error);
		if (error instanceof NotReadyError) { settlePendingSource(el, el); }
		el.time = clock;
		scheduled = true;
	});
}

export function markRefresh(node: Computation): void {
	when (debug) {
		if (currentOwner !== null && (node.config & CONFIG_OWNED_WRITE) === 0) { throw new Error(REFRESH_OWNED_MESSAGE); }
	}
	if (!node.computed || (node.flags & REACTIVE_DISPOSED) !== 0) { return; }
	const busy = (node.flags & (REACTIVE_DIRTY | REACTIVE_CHECK | REACTIVE_IN_HEAP)) !== 0;
	node.flags = (node.flags & ~REACTIVE_CHECK) | REACTIVE_DIRTY | (busy ? 0 : REACTIVE_REASK);
	enqueueSub(node);
	schedule();
}

export function haltReactivity(cause: Error): void {
	if (halted) { return; }
	halted = true;
	console.error("[REACTIVITY_HALTED] An uncaught error halted the reactive system. No further updates will be processed.", cause);
}

export function resetErrorHalt(): void {
	halted = false;
	haltNotified = false;
}

function notifyHalted(): void {
	if (haltNotified) { return; }
	haltNotified = true;
	console.error("[REACTIVITY_HALTED] Update ignored: the reactive system was halted by an earlier uncaught error.");
}

function nearestComputed(parent: Computation | null): Computation | null {
	if (parent === null) { return null; }
	return (parent.config & CONFIG_ROOT) !== 0 ? parent.parentComputed : parent;
}

function inSnapshotScope(owner: Computation | null): boolean {
	let at = owner;
	while (at !== null) {
		if ((at.config & CONFIG_SNAPSHOT_SCOPE) !== 0) { return true; }
		at = at.parent;
	}
	return false;
}

export function setSnapshotStore(store: SnapshotStore | null): void { snapshots = store; }

export function wantsSnapshot(el: Source): boolean {
	return snapshots !== null && (el.config & (CONFIG_HAS_SNAPSHOT | CONFIG_NO_SNAPSHOT)) === 0;
}

export function keepSnapshot(el: Source, cell: unknown): void {
	const store = snapshots;
	if (store === null) { throw new Error("[SNAPSHOT_WITHOUT_CAPTURE] a snapshot was kept while no hydration capture is on"); }
	el.config = el.config | CONFIG_HAS_SNAPSHOT;
	store.keep(el, cell);
}

export function snapshotOf(el: Source): unknown {
	const store = snapshots;
	if (store === null) { throw new Error("[SNAPSHOT_WITHOUT_CAPTURE] a snapshot was read while no hydration capture is on"); }
	return store.kept(el);
}

export function markSnapshotStale(): void {
	const c = nearestComputed(currentOwner);
	if (c !== null) { c.flags = c.flags | REACTIVE_SNAPSHOT_STALE; }
}

function newNode(config: int32, flags: int32, computed: boolean, run: ((self: Computation, create: boolean) => int32) | null, type: int32, parent: Computation | null): Computation {
	return new Computation(config, flags, computed, run, type, parent, clock);
}

export function createOwner(id: string | null = null): Computation {
	const parent = currentOwner;
	const owner = newNode(CONFIG_ROOT, 0, false, null, EFFECT_PURE, parent);
	owner.id = id !== null ? id : inheritId(parent, false);
	owner.parentComputed = nearestComputed(parent);
	if (parent !== null) { linkChild(parent, owner); }
	return owner;
}

export function createComputed(
	run: (self: Computation, create: boolean) => int32,
	type: int32,
	lazy: boolean,
	transparent: boolean,
	unobservedHook: (() => void) | null,
): Computation {
	const parent = currentOwner;
	const config = (transparent ? CONFIG_TRANSPARENT : 0) |
		(parent === null || lazy ? CONFIG_AUTO_DISPOSE : 0) |
		(snapshots !== null && inSnapshotScope(parent) ? CONFIG_IN_SNAPSHOT_SCOPE : 0);
	const node = newNode(config, lazy ? REACTIVE_LAZY : 0, true, run, type, parent);
	node.id = inheritId(parent, transparent);
	node.unobserved = unobservedHook;
	node.depsTail = null;
	if (parent !== null) { linkChild(parent, node); }
	const via = nearestComputed(parent);
	if (via !== null) { node.height = via.height + 1; }
	if (!lazy) { recompute(node, true); }
	return node;
}

export function createEffectNode(
	run: (self: Computation, create: boolean) => int32,
	apply: (self: Computation) => void,
	type: int32,
	transparent: boolean,
): Computation {
	const node = createComputed(run, type, true, transparent, null);
	node.config = node.config & ~CONFIG_AUTO_DISPOSE;
	node.apply = apply;
	return node;
}

export function startEffect(node: Computation, defer: boolean): void {
	recompute(node, true);
	if (defer || (node.flags & REACTIVE_DISPOSED) !== 0) { return; }
	if (node.type === EFFECT_RENDER) {
		runEffectNode(node, true);
	} else {
		userQueue.push(node);
		schedule();
	}
}

function recompute(el: Computation, create: boolean): void {
	if (!create) {
		deleteFromHeap(el);
		el.flight = 0;
		if ((el.status & STATUS_PENDING) !== 0) { el.config = el.config & ~CONFIG_VERDICT; }
		disposeChildren(el, false);
	}
	const outgoingError: Error | null = (el.status & STATUS_ERROR) !== 0 ? el.error : null;
	const outgoingPending: Computation[] | null = (el.status & STATUS_PENDING) !== 0 ? el.pendingSources : null;
	const wasPendingSource = hasPendingSource(el, el);
	const reask = (el.flags & REACTIVE_REASK) !== 0 && !((el.status & STATUS_PENDING) !== 0 && !el.reask);
	const oldOwner = currentOwner;
	const prevTracking = tracking;
	const oldHeight = el.height;
	when (debug) { const prevLabel = swapStrictLabel(null); }
	currentOwner = el;
	tracking = true;
	el.depsTail = null;
	el.depGen = el.depGen + 1;
	el.time = clock;
	el.flags = REACTIVE_RECOMPUTING_DEPS;
	let result: int32 = RUN_UNCHANGED;
	let thrown: Error | null = null;
	let missedWake = false;
	try {
		const run = el.run;
		if (run !== null) { result = run(el, create); }
	} catch (e) {
		thrown = e;
	} finally {
		when (debug) { swapStrictLabel(prevLabel); }
		tracking = prevTracking;
		currentOwner = oldOwner;
		missedWake = (el.flags & REACTIVE_MISSED_WAKE) !== 0;
		if ((el.flags & REACTIVE_PROBED) === 0) { el.config = el.config & ~CONFIG_VERDICT; }
		el.flags = el.flags & (REACTIVE_DISPOSED | (create ? REACTIVE_SNAPSHOT_STALE : 0));
		el.reask = reask && thrown instanceof NotReadyError;
	}
	if (thrown !== null) {
		failPass(el, thrown, wasPendingSource, outgoingPending);
	} else {
		clearStatus(el);
	}
	if ((el.flags & REACTIVE_DISPOSED) !== 0) {
		clearDeps(el);
		return;
	}
	const failed = el.error !== null;
	if (el.type !== EFFECT_PURE && (!failed || (el.type === EFFECT_USER && (el.status & STATUS_ERROR) !== 0))) {
		el.config = el.config | CONFIG_MODIFIED;
		if (!create) {
			if (el.type === EFFECT_RENDER) { renderQueue.push(el); } else { userQueue.push(el); }
		}
	}
	if (!failed) {
		if (result !== RUN_UNCHANGED) {
			if (el.subs !== null) { insertSubs(el); }
		} else {
			if (el.height !== oldHeight) {
				for (let s = el.subs; s !== null; s = s.nextSub) { insertIntoHeapHeight(s.sub); }
			}
			if (outgoingError !== null) { settleErroredDependents(el, outgoingError); }
			if (outgoingPending !== null) {
				for (const source of outgoingPending) {
					if (source !== el) { settlePendingSource(el, source); }
				}
			}
		}
		if (wasPendingSource) { settlePendingSource(el, el); }
	}
	trimStaleDeps(el);
	if (result === RUN_STAGED) { stageNode(el); }
	if (missedWake) {
		enqueueSub(el);
		schedule();
	}
	if (el.type === EFFECT_RENDER) { reportRenderEffect(el); }
}

function reportRenderEffect(el: Computation): void {
	if ((el.status & STATUS_ERROR) !== 0) {
		routeStatus(el, 0, null);
		const error = statusError(el);
		if (!routeStatus(el, STATUS_ERROR, error)) {
			haltReactivity(error);
			throw error;
		}
	} else if ((el.status & STATUS_PENDING) !== 0) {
		routeStatus(el, STATUS_PENDING, statusError(el));
	} else {
		routeStatus(el, 0, null);
	}
}

function failPass(el: Computation, thrown: Error, wasPendingSource: boolean, outgoingPending: Computation[] | null): void {
	if (!(thrown instanceof NotReadyError)) {
		notifyStatus(el, thrown);
		return;
	}
	el.blocked = true;
	notifyStatus(el, thrown);
	if (wasPendingSource && el.flight === 0) { settlePendingSource(el, el); }
	if (outgoingPending !== null) {
		for (const source of outgoingPending) {
			if (source !== el && !hasPendingSource(el, source)) { settlePendingSource(el, source); }
		}
	}
}

function isStaleError(el: Computation): boolean {
	return (el.status & STATUS_ERROR) !== 0 && el.time < clock && el.flight === 0;
}

function updateIfNecessary(el: Computation): void {
	if ((el.flags & (REACTIVE_RECOMPUTING_DEPS | REACTIVE_DISPOSED)) !== 0) { return; }
	if ((el.flags & REACTIVE_CHECK) !== 0) {
		for (let d = el.deps; d !== null; d = d.nextDep) {
			const dep = d.dep;
			if (dep.computed) { updateIfNecessary(dep as Computation); }
			if ((el.flags & REACTIVE_DIRTY) !== 0) { break; }
		}
	}
	if ((el.flags & REACTIVE_DIRTY) !== 0 || isStaleError(el)) { recompute(el, false); }
	el.flags = el.flags & (REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT | REACTIVE_DISPOSED | REACTIVE_SNAPSHOT_STALE);
}

function prepareComputed(comp: Computation): void {
	if ((comp.flags & REACTIVE_LAZY) !== 0) {
		comp.flags = comp.flags & ~REACTIVE_LAZY;
		recompute(comp, true);
	} else if ((comp.flags & REACTIVE_DISPOSED) !== 0 && (comp.config & CONFIG_AUTO_DISPOSE) !== 0) {
		const parent = comp.parent;
		if (parent !== null) {
			if ((parent.flags & REACTIVE_DISPOSED) !== 0) {
				comp.config = comp.config & ~CONFIG_AUTO_DISPOSE;
				return;
			}
			linkChild(parent, comp);
		}
		recompute(comp, true);
	}
}

function pullComputed(dep: Computation, c: Computation): void {
	if (dep.height >= heapMin) {
		markNode(c, REACTIVE_DIRTY);
		markHeap();
		updateIfNecessary(dep);
	}
	const height = dep.height;
	if (height >= c.height && dep.parent !== c) { c.height = height + 1; }
}

function serveStaged(el: Source, c: Computation | null): boolean {
	if (c === null || (el.config & CONFIG_STAGED) === 0) { return false; }
	if (unflushedStaged && !running && (el.config & CONFIG_PROMOTED) === 0) {
		c.flags = c.flags | REACTIVE_MISSED_WAKE;
		return false;
	}
	return true;
}

function throwIfUnready(el: Computation, c: Computation | null, underScope: boolean): void {
	const status = el.status;
	if ((status & STATUS_PENDING) !== 0) {
		if (c !== null) {
			const retriedByServerPass = underScope && onServer();
			if (!tracking && el !== c && !retriedByServerPass) { link(el, c); }
			throw statusError(el);
		}
		if ((status & STATUS_UNINITIALIZED) !== 0) { throw statusError(el); }
	} else if ((status & STATUS_ERROR) !== 0) {
		if (retriesError(el)) {
			recompute(el, false);
			throwIfUnready(el, c, underScope);
			return;
		}
		throw statusError(el);
	}
}

function retriesError(el: Computation): boolean {
	return tracking && el.time < clock && (el.flags & (REACTIVE_RECOMPUTING_DEPS | REACTIVE_DISPOSED)) === 0;
}

function quietPending(el: Computation): boolean {
	const list = el.pendingSources;
	if (list === null) { return el.reask; }
	for (const source of list) {
		if (!source.reask) { return false; }
	}
	return true;
}

function verdictRead(el: Source, c: Computation | null): boolean {
	if (c !== null && tracking) {
		link(el, c);
		if (el.computed) {
			verdictOpen = false;
			try {
				pullComputed(el as Computation, c);
			} finally {
				verdictOpen = true;
			}
		}
	}
	if (el.computed) {
		const comp = el as Computation;
		if ((comp.status & STATUS_PENDING) !== 0) {
			if ((comp.status & STATUS_UNINITIALIZED) === 0) {
				if (probing && !quietPending(comp)) { probeFound = true; }
				return false;
			}
			if (c !== null && !tracking && comp !== c) { link(el, c); }
			throw statusError(comp);
		}
		if ((comp.status & STATUS_ERROR) !== 0) { throw statusError(comp); }
	}
	return latestActive ? serveStaged(el, c) : false;
}

export function readSource(el: Source): int32 {
	let c = currentOwner;
	const underScope = c !== null && (c.config & CONFIG_ROOT) !== 0;
	if (underScope) { c = (c as Computation).parentComputed; }
	if (el.computed) { prepareComputed(el as Computation); }
	let staged = false;
	if (verdictOpen) {
		staged = verdictRead(el, c);
	} else {
		when (debug) { assertTrackedRead(el); }
		if (c !== null && tracking) {
			link(el, c);
			if (el.computed) { pullComputed(el as Computation, c); }
		}
		if (el.computed) { throwIfUnready(el as Computation, c, underScope); }
		if (snapshots !== null && c !== null && (c.config & CONFIG_IN_SNAPSHOT_SCOPE) !== 0 && (el.config & CONFIG_HAS_SNAPSHOT) !== 0) {
			return READ_SNAPSHOT;
		}
		staged = serveStaged(el, c);
	}
	if (c === null && el.computed && el.subs === null) {
		const comp = el as Computation;
		if ((comp.config & CONFIG_AUTO_DISPOSE) !== 0 && (comp.config & CONFIG_DORMANT_QUEUED) === 0 && (comp.status & STATUS_PENDING) === 0) {
			comp.config = comp.config | CONFIG_DORMANT_QUEUED;
			dormantNodes.push(comp);
			dormantPending = true;
		}
	}
	return staged ? READ_STAGED : READ_VALUE;
}

function stageNode(el: Source): void {
	el.config = el.config | CONFIG_STAGED;
	pendingNodes.push(el);
	if (!running) { unflushedStaged = true; }
}

export function assertWritable(el: Source): void {
	when (debug) {
		if (currentOwner !== null && (el.config & CONFIG_OWNED_WRITE) === 0) { throw new Error(OWNED_WRITE_MESSAGE); }
	}
}

export function writeSource(el: Source, wasStaged: boolean): void {
	if (el.computed) { (el as Computation).time = clock; }
	if (!wasStaged) { stageNode(el); }
	if (currentOwner !== null && !running && (el.config & CONFIG_PROMOTED) === 0) {
		el.config = el.config | CONFIG_PROMOTED;
		promotedWrites.push(el);
	}
	insertSubs(el);
	schedule();
}

function commitPendingNodes(): void {
	const nodes = pendingNodes;
	pendingNodes = [];
	for (const n of nodes) {
		if ((n.config & CONFIG_STAGED) === 0) { continue; }
		n.config = n.config & ~CONFIG_STAGED;
		const commit = n.commit;
		if (commit !== null) { commit(); }
	}
}

export function runEffectNode(node: Computation, firstApply: boolean): void {
	if ((node.config & CONFIG_MODIFIED) === 0 || (node.flags & REACTIVE_DISPOSED) !== 0) { return; }
	const held = heldRun;
	if (held !== null && held(node)) { return; }
	node.config = node.config & ~CONFIG_MODIFIED;
	const apply = node.apply;
	if (apply === null) { return; }
	const oldOwner = currentOwner;
	const prevTracking = tracking;
	if (!firstApply) { currentOwner = null; }
	tracking = false;
	when (debug) { const prevLabel = swapStrictLabel(null); }
	try {
		apply(node);
	} catch (e) {
		node.pendingSources = null;
		node.status = STATUS_ERROR;
		node.error = e;
		if (!routeStatus(node, STATUS_ERROR, e)) {
			haltReactivity(e);
			throw e;
		}
	} finally {
		when (debug) { swapStrictLabel(prevLabel); }
		currentOwner = oldOwner;
		tracking = prevTracking;
	}
}

function runQueue(first: boolean): void {
	const queue = first ? renderQueue : userQueue;
	if (first) { renderQueue = []; } else { userQueue = []; }
	for (let i = 0; i < queue.length; i += 1) { runEffectNode(queue[i], false); }
}

function flushOnce(): void {
	if (running) { return; }
	running = true;
	unflushedStaged = false;
	for (const el of promotedWrites) { el.config = el.config & ~CONFIG_PROMOTED; }
	promotedWrites = [];
	const oldOwner = currentOwner;
	const prevTracking = tracking;
	currentOwner = null;
	tracking = false;
	try {
		sweepDormant();
		runHeap();
		commitPendingNodes();
		clock += 1;
		sweepBoundaries();
		scheduled = heapMax >= heapMin || pendingNodes.length !== 0;
		runQueue(true);
		runQueue(false);
	} finally {
		running = false;
		currentOwner = oldOwner;
		tracking = prevTracking;
	}
}

export function flush(): void {
	if (running || halted) { return; }
	let rounds: int32 = 0;
	while (scheduled || dormantPending) {
		rounds += 1;
		if (rounds === LOOP_LIMIT) { throw new Error("Potential Infinite Loop Detected. Kept alive by scheduled work"); }
		flushOnce();
	}
}

export function flush<T>(fn: () => T): T {
	syncDepth += 1;
	try {
		return fn();
	} finally {
		try {
			flush();
		} finally {
			syncDepth -= 1;
		}
	}
}

function schedule(): void {
	if (halted) {
		notifyHalted();
		return;
	}
	if (scheduled) { return; }
	scheduled = true;
	if (syncDepth === 0 && !running) {
		when (server) {
			flush();
		} else {
			// parked: queueMicrotask(flush) as the reference does; ~/metascript/.inbox/compiler/2026-10-20-queuemicrotask-undeclared.md
			Promise.resolve(0).then((unused: int32): void => { flush(); });
		}
	}
}

function markVerdictReader(): void {
	let c = currentOwner;
	if (c !== null && (c.config & CONFIG_ROOT) !== 0) { c = c.parentComputed; }
	if (c !== null && tracking) {
		c.config = c.config | CONFIG_VERDICT;
		c.flags = c.flags | REACTIVE_PROBED;
	}
}

export function latest<T>(fn: () => T): T {
	markVerdictReader();
	const prevLatest = latestActive;
	const prevOpen = verdictOpen;
	latestActive = true;
	verdictOpen = true;
	try {
		return fn();
	} finally {
		latestActive = prevLatest;
		verdictOpen = prevOpen;
	}
}

export function isPending<T>(fn: () => T): boolean {
	markVerdictReader();
	const prevProbing = probing;
	const prevFound = probeFound;
	const prevOpen = verdictOpen;
	probing = true;
	probeFound = false;
	verdictOpen = true;
	let answer = false;
	let unready: Error | null = null;
	try {
		fn();
		answer = probeFound;
	} catch (e) {
		answer = probeFound;
		if (e instanceof NotReadyError && !probeFound && currentOwner !== null) { unready = e; }
	} finally {
		probing = prevProbing;
		probeFound = prevFound;
		verdictOpen = prevOpen;
	}
	if (unready !== null) { throw unready; }
	return answer;
}
