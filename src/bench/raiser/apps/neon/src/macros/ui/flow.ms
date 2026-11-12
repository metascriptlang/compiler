// Control flow — For / ForKeyedBy / ForUnkeyed / Repeat / Show / Match. Each returns a region NeonNode;
// the engines in core/array.ms and the host reconciler do the work. A row is described here and
// mounted by the reconciler at its final position, so nothing below touches the host.

import { mapArray, mapArrayKeyedBy, mapArrayByPosition, repeat } from "../../core/array";
import { createMemo } from "../../core/memo";
import { Accessor, Signal, accessor, untrack } from "../../core/signal";
import { createErrorBoundary, createLoadingBoundary, routeThrown } from "../../core/boundary";
import { createOwner, getOwner, getNextChildId, flush, disposeChildren, isServer, asServer } from "../../core/runtime";
import { onCleanup } from "../../core/cleanup";
import { runWithOwner } from "../../core/owner";
import { Computation, NotReadyError, ContextEntry } from "../../core/types";
import { Hole, Rules, ServerContext, ServerMarks, MAX_PASSES, serverContext, withServerContext, pendingWaits, unconverged } from "../../core/serverContext";
import { serverCaught } from "../../render/ssr";
import { NeonNode, RowHome, regionNode, builtRow, mountContent, holderOf } from "../../render/node";
import { Host, HostNode } from "../../render/hostTypes";
import { Row, makeRow, mountAt, removeRow, place } from "../../render/reconcile";
import { HOLES_DONE, HOLES_WAIT, runHoles } from "../../render/bind";
import { List } from "../../core/list";
import { listRegion } from "../../render/listRegion";

function fallbackRow(host: Host, home: RowHome, fb: NeonNode | null): (() => Row) | null {
	if (fb === null) { return null; }
	const view = fb as NeonNode;
	return (): Row => builtRow(host, home, view);
}

function indexRead(declared: boolean | null): boolean {
	return declared === null ? true : (declared as boolean);
}

export function For<T>(props: {
	each: Accessor<T[]>;
	children: (item: T, index: Accessor<number>) => NeonNode;
	fallback?: NeonNode | null;
	usesIndex?: boolean | null;
}): NeonNode {
	return regionNode((h, home) => mapArray<T, Row>(
		props.each,
		(item: T, index: Accessor<number>): Row => builtRow(h, home, props.children(item, index)),
		fallbackRow(h, home, props.fallback),
		indexRead(props.usesIndex),
	));
}

export function ForKeyedBy<T, K>(props: {
	each: Accessor<T[]>;
	keyed: (item: T) => K;
	children: (item: Accessor<T>, index: Accessor<number>) => NeonNode;
	fallback?: NeonNode | null;
	usesIndex?: boolean | null;
}): NeonNode {
	return regionNode((h, home) => mapArrayKeyedBy<T, K, Row>(
		props.each,
		props.keyed,
		(item: Accessor<T>, index: Accessor<number>): Row => builtRow(h, home, props.children(item, index)),
		fallbackRow(h, home, props.fallback),
		indexRead(props.usesIndex),
	));
}

export function ForUnkeyed<T>(props: {
	each: Accessor<T[]>;
	children: (item: Accessor<T>, index: number) => NeonNode;
	fallback?: NeonNode | null;
}): NeonNode {
	return regionNode((h, home) => mapArrayByPosition<T, Row>(
		props.each,
		(item: Accessor<T>, index: number): Row => builtRow(h, home, props.children(item, index)),
		fallbackRow(h, home, props.fallback),
	));
}

export function Repeat(props: {
	count: Accessor<number>;
	from?: Accessor<number> | null;
	fallback?: NeonNode | null;
	children: (index: number) => NeonNode;
}): NeonNode {
	return regionNode((h, home) => repeat<Row>(
		props.count,
		(index: number): Row => builtRow(h, home, props.children(index)),
		props.from === null ? null : (props.from as () => number),
		fallbackRow(h, home, props.fallback),
	));
}

export function ForList<T>(props: {
	each: List<T>;
	children: (item: Accessor<T>) => NeonNode;
	keyed?: ((item: T) => number) | null;
}): NeonNode {
	return listRegion<T>(props.each, props.children, props.keyed);
}

class MountedState {
	failed: boolean = false;
	scope: Computation | null = null;
}

function mountGuarded(mount: () => void, state: MountedState): void {
	try {
		mount();
	} catch (e) {
		if (e instanceof NotReadyError) { throw e; }
		routeThrown(e);
		state.failed = true;
	}
}

function mountIn(scope: Computation, children: NeonNode, state: MountedState, host: Host, parent: HostNode, before: HostNode | null): void {
	runWithOwner(scope, (): number => {
		mountGuarded((): void => { children(host, parent, before); }, state);
		return 0;
	});
}

function mountedUnder(children: NeonNode, context: ContextEntry | null, state: MountedState, id: string | null = null): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const scope = createOwner(id);
		scope.context = context;
		state.scope = scope;
		mountIn(scope, children, state, host, parent, before);
	};
}

function mountedPlain(children: NeonNode, tree: Computation, state: MountedState): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const scope = createOwner();
		scope.context = tree.context;
		scope.parentComputed = tree;
		state.scope = scope;
		runWithOwner(scope, (): number => { children(host, parent, before); return 0; });
	};
}

type ErroredFallback = (err: Accessor<Error>, reset: () => void) => NeonNode;

function errorRows(host: Host, home: RowHome, children: NeonNode, fallbackOf: ErroredFallback, state: MountedState): Accessor<Row[]> {
	let content: NeonNode | null = null;
	let fallback: NeonNode | null = null;
	let contentRow: Row | null = null;
	let firstMount = true;
	let revision: int32 = 0;
	const holder = holderOf(host, home);
	const shows = createErrorBoundary<int32>(
		(): int32 => {
			if (content === null) { content = mountedPlain(children, getOwner() as Computation, state); }
			if (contentRow === null) {
				const tree = getOwner() as Computation;
				const row = runWithOwner(tree.parent, (): Row => makeRow(content as NeonNode));
				row.keep = holder;
				const first = firstMount;
				firstMount = false;
				try {
					mountContent(host, holder, home.parent, home.before, row, first);
				} catch (e) {
					if (state.scope !== null) { disposeChildren(state.scope as Computation, true); }
					state.scope = null;
					throw e;
				}
				contentRow = row;
			}
			return 0;
		},
		(err: Accessor<Error>, reset: () => void): int32 => {
			fallback = (host: Host, parent: HostNode, before: HostNode | null): void => {
				fallbackOf(err, (): void => { flush((): number => { reset(); return 0; }); })(host, parent, before);
			};
			revision += 1;
			return revision;
		},
	);
	return createMemo<Row[]>(() => {
		if (shows() === 0) { return [contentRow as Row]; }
		return [builtRow(host, home, fallback as NeonNode)];
	});
}

function errorRowsOnServer(host: Host, children: NeonNode, fallbackOf: ErroredFallback, failure: Signal<Error | null>, state: MountedState): Accessor<Row[]> {
	let content: NeonNode | null = null;
	let fallback: NeonNode | null = null;
	let contentRow: Row | null = null;
	let boundaryOwner: Computation | null = null;
	const showsContent = createErrorBoundary<boolean>(
		(): boolean => {
			const failed = failure.get();
			if (failed !== null) { throw failed; }
			if (content === null) {
				const tree = getOwner() as Computation;
				boundaryOwner = tree.parent;
				content = mountedUnder(children, tree.context, state);
			}
			return true;
		},
		(err: Accessor<Error>, reset: () => void): boolean => {
			const caught = err();
			failure.set(caught);
			const shown = serverCaught(caught);
			fallback = (host: Host, parent: HostNode, before: HostNode | null): void => {
				mountGuarded((): void => {
					fallbackOf(shown, (): void => { flush((): number => { failure.set(null); reset(); return 0; }); })(host, parent, before);
				}, state);
			};
			return false;
		},
	);
	return createMemo<Row[]>(() => {
		if (showsContent()) {
			if (contentRow === null) { contentRow = runWithOwner(boundaryOwner, (): Row => makeRow(content as NeonNode)); }
			return [contentRow as Row];
		}
		contentRow = null;
		if (state.scope !== null) { disposeChildren(state.scope as Computation, true); }
		return [makeRow(fallback as NeonNode)];
	});
}

type RowMount = (host: Host, parent: HostNode, before: HostNode | null) => Row | null;

function spanOfMounted(mount: RowMount): Accessor<Row[]> {
	let self: Row | null = null;
	const outer = makeRow((host: Host, parent: HostNode, before: HostNode | null): void => {
		const inner = mount(host, parent, before);
		if (inner === null) { return; }
		(self as Row).start = (inner as Row).start;
		(self as Row).end = (inner as Row).end;
	});
	self = outer;
	return accessor((): Row[] => [outer]);
}

function settledOnServer(rows: Accessor<Row[]>, state: MountedState): Accessor<Row[]> {
	return spanOfMounted((host: Host, parent: HostNode, before: HostNode | null): Row | null => {
		let shown = rows()[0];
		mountAt(host, parent, before, shown);
		if (!state.failed) { return shown; }
		flush();
		removeRow(host, parent, shown);
		shown = rows()[0];
		mountAt(host, parent, before, shown);
		return shown;
	});
}

export function Errored(props: {
	children: NeonNode;
	fallback: (err: Accessor<Error>, reset: () => void) => NeonNode;
}): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const state = new MountedState();
		const server = isServer();
		regionNode((h, home) => {
			if (!server) { return errorRows(h, home, props.children, props.fallback, state); }
			return settledOnServer(errorRowsOnServer(h, props.children, props.fallback, new Signal<Error | null>(null, null, true), state), state);
		})(host, parent, before);
	};
}

function loadingRows(host: Host, home: RowHome, children: NeonNode, fallback: NeonNode | null): Accessor<Row[]> {
	const state = new MountedState();
	const holder = holderOf(host, home);
	let contentRow: Row | null = null;
	let firstMount = true;
	const showsContent = createLoadingBoundary<boolean>(
		(): boolean => {
			if (contentRow !== null) { throw new Error("[LOADING_CONTENT_RERUN] a Loading's content was mounted again while an earlier mount stood"); }
			const row = makeRow(mountedUnder(children, (getOwner() as Computation).context, state));
			row.keep = holder;
			const first = firstMount;
			firstMount = false;
			mountContent(host, holder, home.parent, home.before, row, first);
			contentRow = row;
			return true;
		},
		(): boolean => false,
	);
	return createMemo<Row[]>(() => {
		if (showsContent()) { return [contentRow as Row]; }
		if (fallback === null) { return [] as Row[]; }
		return [builtRow(host, home, fallback as NeonNode)];
	});
}

class Life {
	dead: boolean = false;
}

class Pending {
	scope: Computation;
	source: Computation;
	holes: Hole[] = [];
	markup: string = "";
	rules: Rules | null = null;

	constructor(scope: Computation, source: Computation) {
		this.scope = scope;
		this.source = source;
	}

	sources(): Computation[] {
		if (this.holes.length === 0) { return [this.source]; }
		const open: Computation[] = [];
		for (const h of this.holes) { if (h.value === null) { open.push(h.source); } }
		return open;
	}
}

function placeholder(marks: ServerMarks, id: string, fallback: NeonNode | null): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		place(host, parent, marks.open(id) as HostNode, before);
		if (fallback !== null) {
			const shown = makeRow(fallback as NeonNode);
			shown.owner = createOwner(id);
			mountAt(host, parent, before, shown);
		}
		place(host, parent, marks.close(id) as HostNode, before);
	};
}

function rerunContent(ctx: ServerContext, marks: ServerMarks, host: Host, holder: HostNode, scope: Computation, children: NeonNode, state: MountedState, pending: Pending): boolean {
	return asServer((): boolean => withServerContext(ctx, (): boolean => {
		const again = makeRow((h: Host, p: HostNode, b: HostNode | null): void => { mountIn(scope, children, state, h, p, b); });
		again.owner = scope;
		let settled = false;
		let completed = false;
		const outer = ctx.holes;
		const mine: Hole[] = [];
		ctx.holes = mine;
		try {
			mountAt(host, holder, null, again);
			settled = true;
			completed = true;
		} catch (e) {
			if (!(e instanceof NotReadyError)) { throw e; }
			pending.source = (e as NotReadyError).source;
		} finally {
			ctx.holes = outer;
			if (completed) { flush(); }
		}
		if (!settled) { disposeChildren(scope, false); return false; }
		const html = marks.html(holder);
		const live = marks.kept(html, mine);
		if (live.length === 0) { return true; }
		pending.holes = live;
		pending.markup = html;
		return false;
	}));
}

async function settleContent(ctx: ServerContext, marks: ServerMarks, id: string, pending: Pending, life: Life, beside: HostNode, again: (holder: HostNode) => boolean): Promise<void> {
	let passes = 1;
	let settled = false;
	try {
		while (!settled) {
			for (const w of pendingWaits(ctx, pending.sources())) { await w; }
			if (life.dead) { return; }
			if (passes >= MAX_PASSES) { throw unconverged("<Loading> at owner id \"" + id + "\""); }
			passes += 1;
			if (pending.holes.length > 0) {
				const state = runHoles(ctx, pending.holes);
				if (state === HOLES_DONE) {
					if (pending.rules !== null) { marks.replay(pending.rules as Rules); }
					ctx.fragments.set(id, marks.fill(pending.markup, pending.holes));
					settled = true;
					continue;
				}
				if (state === HOLES_WAIT) { continue; }
				disposeChildren(pending.scope, false);
				pending.holes = [];
				pending.rules = null;
			}
			const holder = marks.holder(beside) as HostNode;
			if (marks.within(id, (): boolean => again(holder))) {
				ctx.fragments.set(id, marks.html(holder));
				settled = true;
			}
		}
	} catch (e) {
		if (ctx.failure === null) { ctx.failure = e; }
	}
}

function clientContentId(parent: Computation, boundary: Computation): string | null {
	if (boundary.id === null) { return null; }
	getNextChildId(parent);
	getNextChildId(parent);
	return boundary.id + "00";
}

function loadingOnServer(children: NeonNode, fallback: NeonNode | null): Accessor<Row[]> {
	const state = new MountedState();
	const parent = getOwner() as Computation;
	const context = parent.context;
	const boundary = createOwner();
	const contentId = clientContentId(parent, boundary);
	return spanOfMounted((host: Host, parent: HostNode, before: HostNode | null): Row | null => {
		const ctx = serverContext();
		const marks = ctx === null ? null : (ctx as ServerContext).marks;
		const beside = marks === null ? null : (marks as ServerMarks).holder(parent) as HostNode;
		const content = makeRow(mountedUnder(children, context, state, contentId));
		let source: Computation | null = null;
		const outer = ctx === null ? null : (ctx as ServerContext).holes;
		const mine: Hole[] = [];
		const rules = new Rules();
		let outerRules: Rules | null = null;
		if (marks !== null) {
			(ctx as ServerContext).holes = mine;
			outerRules = (marks as ServerMarks).rules(rules);
		}
		try {
			mountAt(host, parent, before, content);
		} catch (e) {
			if (!(e instanceof NotReadyError)) { throw e; }
			source = (e as NotReadyError).source;
		} finally {
			if (marks !== null) {
				(ctx as ServerContext).holes = outer;
				(marks as ServerMarks).rules(outerRules);
			}
		}
		const scope = state.scope as Computation;
		let held: Hole[] = [];
		let markup = "";
		if (source === null) {
			if (marks === null) { return content; }
			markup = (marks as ServerMarks).take(content.start as HostNode);
			held = (marks as ServerMarks).kept(markup, mine);
			if (held.length === 0) {
				(marks as ServerMarks).replay(rules);
				return content;
			}
			source = held[0].source;
		}
		removeRow(host, parent, content);
		if (ctx === null) {
			disposeChildren(scope, true);
			if (fallback === null) { return null; }
			const waiting = makeRow(fallback as NeonNode);
			mountAt(host, parent, before, waiting);
			return waiting;
		}
		const served = ctx as ServerContext;
		const pending = new Pending(scope, source as Computation);
		if (marks === null) { throw new Error("SSR: a Loading under a server context that has no writer to hold its placeholder"); }
		if (held.length === 0) {
			disposeChildren(scope, false);
			(marks as ServerMarks).replay(rules);
		} else {
			pending.holes = held;
			pending.markup = markup;
			pending.rules = rules;
		}
		const id = boundary.id;
		if (id === null) { throw new Error("[SSR_LOADING_WITHOUT_ID] a Loading on the server needs an owner id; render it under a root that carries one"); }
		const waiting = makeRow(placeholder(marks as ServerMarks, id as string, fallback));
		mountAt(host, parent, before, waiting);
		const life = new Life();
		onCleanup((): void => { life.dead = true; });
		served.loops.push(settleContent(served, marks as ServerMarks, id as string, pending, life, beside as HostNode, (holder: HostNode): boolean => rerunContent(served, marks as ServerMarks, host, holder, scope, children, state, pending)));
		return waiting;
	});
}

export function Loading(props: {
	children: NeonNode;
	fallback?: NeonNode | null;
}): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		regionNode((h, home) => isServer() ? loadingOnServer(props.children, props.fallback) : loadingRows(h, home, props.children, props.fallback))(host, parent, before);
	};
}

function shownRows(host: Host, home: RowHome, on: boolean, children: NeonNode, fallback: NeonNode | null): Row[] {
	if (on) { return [builtRow(host, home, children)]; }
	if (fallback !== null) { return [builtRow(host, home, fallback as NeonNode)]; }
	return [] as Row[];
}

// Conditional: children rebuild only when the condition's truthiness flips (equals memo).
export function Show(props: {
	when: Accessor<boolean>;
	children: NeonNode;
	fallback?: NeonNode | null;
}): NeonNode {
	return regionNode((h, home) => {
		const cond = createMemo<boolean>(() => props.when());
		return createMemo<Row[]>(() => shownRows(h, home, cond(), props.children, props.fallback));
	});
}

export function ShowKeyed(props: {
	when: Accessor<boolean>;
	children: NeonNode;
	fallback?: NeonNode | null;
}): NeonNode {
	return regionNode((h, home) => createMemo<Row[]>(() => shownRows(h, home, props.when(), props.children, props.fallback)));
}

export function ShowWith<T>(props: {
	when: Accessor<boolean>;
	value: Accessor<T>;
	children: (value: Accessor<T>) => NeonNode;
	fallback?: NeonNode | null;
}): NeonNode {
	const narrowed = accessor((): T => {
		if (!props.when()) { throw new Error("<Show>: the narrowed value was read while its condition is false"); }
		return props.value();
	});
	return Show({
		when: props.when,
		children: (host: Host, parent: HostNode, before: HostNode | null): void => { props.children(narrowed)(host, parent, before); },
		fallback: props.fallback,
	});
}

export function ShowKeyedWith<T>(props: {
	when: Accessor<boolean>;
	value: Accessor<T>;
	children: (value: T) => NeonNode;
	fallback?: NeonNode | null;
}): NeonNode {
	return ShowKeyed({
		when: props.when,
		children: (host: Host, parent: HostNode, before: HostNode | null): void => { props.children(props.value())(host, parent, before); },
		fallback: props.fallback,
	});
}

export function showWhen<M>(source: () => M, use: (value: Accessor<M>) => NeonNode): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		use(createMemo<M>((prev: M | null): M => source()))(host, parent, before);
	};
}

export class BoundCase {
	test: Accessor<boolean>;
	follow: () => void;
	content: () => NeonNode;
	constructor(test: Accessor<boolean>, follow: () => void, content: () => NeonNode) {
		this.test = test;
		this.follow = follow;
		this.content = content;
	}
}

export class CaseArm {
	bind: (earlier: Accessor<boolean>) => BoundCase;
	constructor(bind: (earlier: Accessor<boolean>) => BoundCase) {
		this.bind = bind;
	}
}

function noFollow(): void {}

function narrowedCase<T>(earlier: Accessor<boolean>, when: Accessor<boolean>, value: Accessor<T>): Accessor<T> {
	return accessor((): T => {
		if (untrack((): boolean => earlier()) || !when()) { throw new Error("<Case>: the narrowed value was read while its case is not selected"); }
		return value();
	});
}

export function Case(props: {
	when: Accessor<boolean>;
	children: NeonNode;
}): CaseArm {
	return new CaseArm((earlier: Accessor<boolean>): BoundCase => new BoundCase(props.when, noFollow, (): NeonNode => props.children));
}

export function CaseKeyed(props: {
	when: Accessor<boolean>;
	children: NeonNode;
}): CaseArm {
	return new CaseArm((earlier: Accessor<boolean>): BoundCase => new BoundCase(props.when, (): void => { props.when(); }, (): NeonNode => props.children));
}

export function CaseWith<T>(props: {
	when: Accessor<boolean>;
	value: Accessor<T>;
	children: (value: Accessor<T>) => NeonNode;
}): CaseArm {
	return new CaseArm((earlier: Accessor<boolean>): BoundCase => {
		const narrowed = narrowedCase<T>(earlier, props.when, props.value);
		return new BoundCase(props.when, noFollow, (): NeonNode => (host: Host, parent: HostNode, before: HostNode | null): void => { props.children(narrowed)(host, parent, before); });
	});
}

export function CaseKeyedWith<T>(props: {
	when: Accessor<boolean>;
	value: Accessor<T>;
	children: (value: T) => NeonNode;
}): CaseArm {
	return new CaseArm((earlier: Accessor<boolean>): BoundCase => new BoundCase(props.when, (): void => { props.when(); }, (): NeonNode => (host: Host, parent: HostNode, before: HostNode | null): void => { props.children(props.value())(host, parent, before); }));
}

export function caseWhen<M>(source: () => M, use: (value: Accessor<M>) => CaseArm): CaseArm {
	return new CaseArm((earlier: Accessor<boolean>): BoundCase => {
		const value = createMemo<M>((prev: M | null): M => earlier() ? (prev as M) : source());
		return use(value).bind(earlier);
	});
}

function unmatchedRows(host: Host, home: RowHome, fallback: NeonNode | null): Row[] {
	if (fallback === null) { return [] as Row[]; }
	return [builtRow(host, home, fallback as NeonNode)];
}

export function Match(props: {
	cases: CaseArm[];
	fallback?: NeonNode | null;
}): NeonNode {
	return regionNode((h, home) => {
		const owner = getOwner();
		const bound: BoundCase[] = [];
		const taken: Accessor<boolean>[] = [];
		const never = accessor((): boolean => false);
		const selected = createMemo<int32>((): int32 => {
			for (let i = 0; i < props.cases.length; i = i + 1) {
				if (i === bound.length) {
					const at = i;
					const earlier = at === 0 ? never : taken[at - 1];
					runWithOwner(owner, (): number => {
						const arm = props.cases[at].bind(earlier);
						bound.push(arm);
						taken.push(createMemo<boolean>((): boolean => earlier() || arm.test()));
						return 0;
					});
				}
				if (taken[i]()) { return i; }
			}
			return -1;
		});
		return createMemo<Row[]>(() => {
			const at = selected();
			if (at < 0) { return unmatchedRows(h, home, props.fallback); }
			bound[at].follow();
			return [builtRow(h, home, bound[at].content())];
		});
	});
}
