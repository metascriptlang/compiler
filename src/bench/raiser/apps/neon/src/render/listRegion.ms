import { createRenderEffect } from "../core/effect";
import { Cleanup, Computation, NotReadyError } from "../core/types";
import { onCleanup } from "../core/cleanup";
import { createRoot, runWithOwner } from "../core/owner";
import { getOwner, isServer } from "../core/runtime";
import { Accessor, Signal, accessor, untrack } from "../core/signal";
import { List, ListQueue, ListOp, ListOpKind, matchByIds } from "../core/list";
import { Host, HostNode, NeonNode } from "./hostTypes";
import { Row, makeRow, mountAt, moveRow, removeRow, reconcileArrays } from "./reconcile";
import { RowHome, regionHome, buildHeld } from "./node";
import { regionAnchor, regionParent, sealRegion, serverRegionStart, serverRegionEnd, skipRegionEffect } from "./claim";

// The region's stores live in one object passed to every step, never captured by a nested
// closure: src/core/array.ms keeps mapArray's stores as parameters for the same reason.
// The effect's compute takes the list's ops, builds the rows they need into the holder and updates
// these stores (Solid mapArray, packages/signals/src/map.ts:362); the host work they imply is
// queued as steps and the effect's apply only plays the steps.
interface Region<Item> {
	host: Host;
	parent: HostNode;
	anchor: HostNode;
	placed: boolean;
	home: RowHome;
	owner: Computation | null;
	list: List<Item>;
	row: (item: Accessor<Item>) => NeonNode;
	// Zero or one key function: a nullable function of Item in a field of this generic interface is
	// the shape that does not reach its Maybe carrier on C
	// (~/metascript/.inbox/compiler/2026-09-21-value-into-a-union-parameter-passes-the-raw-address.md).
	keys: ((item: Item) => number)[];
	rows: Row[];
	cells: Signal<Item>[];
	disposers: (() => void)[];
	steps: Step[];
}

enum StepKind { Insert, Move, Remove, Reconcile }

interface Step {
	kind: StepKind;
	row: Row | null;
	before: Row | null;
	prev: Row[];
	next: Row[];
}

class Built<Item> {
	row: Row;
	cell: Signal<Item>;
	dispose: () => void;

	constructor(row: Row, cell: Signal<Item>, dispose: () => void) {
		this.row = row;
		this.cell = cell;
		this.dispose = dispose;
	}
}

// The row's scope lives under the region's owner, not under the effect that builds it, and a pending
// read in its view belongs to that effect (src/core/array.ms mapRows: owner.parentComputed = getOwner()).
function makeBuilt<Item>(g: Region<Item>, v: Item, within: Computation | null): Built<Item> {
	return runWithOwner(g.owner, (): Built<Item> => createRoot((d) => {
		if (within !== null) { (getOwner() as Computation).parentComputed = within; }
		try {
			const cell = new Signal<Item>(v, null, true);
			return new Built<Item>(makeRow(g.row(accessor((): Item => cell.get()))), cell, d);
		} catch (e) {
			d();
			throw e;
		}
	}));
}

function buildHeldOrDispose<Item>(g: Region<Item>, b: Built<Item>): void {
	try {
		buildHeld(g.host, g.home, b.row);
	} catch (e) {
		b.dispose();
		throw e;
	}
}

function step(kind: StepKind, row: Row | null, before: Row | null): Step {
	return { kind, row, before, prev: [] as Row[], next: [] as Row[] };
}

function rowAfter<Item>(g: Region<Item>, i: number): Row | null {
	if (i >= g.rows.length) { return null; }
	return g.rows[i];
}

function insertFirst<Item>(g: Region<Item>, v: Item): void {
	const b = makeBuilt<Item>(g, v, null);
	g.rows.push(b.row);
	g.cells.push(b.cell);
	g.disposers.push(b.dispose);
	mountAt(g.host, g.parent, g.anchor, b.row);
}

function insertRow<Item>(g: Region<Item>, i: number, v: Item, within: Computation | null): void {
	const b = makeBuilt<Item>(g, v, within);
	buildHeldOrDispose<Item>(g, b);
	g.rows.push(b.row);
	g.cells.push(b.cell);
	g.disposers.push(b.dispose);
	const last = g.rows.length - 1;
	for (let j = last; j > i; j -= 1) {
		g.rows[j] = g.rows[j - 1];
		g.cells[j] = g.cells[j - 1];
		g.disposers[j] = g.disposers[j - 1];
	}
	g.rows[i] = b.row;
	g.cells[i] = b.cell;
	g.disposers[i] = b.dispose;
	g.steps.push(step(StepKind.Insert, b.row, rowAfter<Item>(g, i + 1)));
}

function removeRowAt<Item>(g: Region<Item>, i: number): void {
	g.disposers[i]();
	g.steps.push(step(StepKind.Remove, g.rows[i], null));
	const last = g.rows.length - 1;
	for (let j = i; j < last; j += 1) {
		g.rows[j] = g.rows[j + 1];
		g.cells[j] = g.cells[j + 1];
		g.disposers[j] = g.disposers[j + 1];
	}
	g.rows.pop();
	g.cells.pop();
	g.disposers.pop();
}

function moveRowTo<Item>(g: Region<Item>, from: number, to: number): void {
	const r = g.rows[from];
	const c = g.cells[from];
	const d = g.disposers[from];
	if (from < to) {
		for (let j = from; j < to; j += 1) {
			g.rows[j] = g.rows[j + 1];
			g.cells[j] = g.cells[j + 1];
			g.disposers[j] = g.disposers[j + 1];
		}
	} else {
		for (let j = from; j > to; j -= 1) {
			g.rows[j] = g.rows[j - 1];
			g.cells[j] = g.cells[j - 1];
			g.disposers[j] = g.disposers[j - 1];
		}
	}
	g.rows[to] = r;
	g.cells[to] = c;
	g.disposers[to] = d;
	g.steps.push(step(StepKind.Move, r, rowAfter<Item>(g, to + 1)));
}

// Each new row takes the old row that carries the same item — by number key when the list has one,
// by item identity otherwise, which is what <For> does. A row's DOM and its reactive scope belong to
// the item, not to the slot, so a replaceAll that reorders moves nodes instead of rewriting values.
// Every new row is built before anything is taken from the stores, so a pending read leaves them as they were.
function resetTo<Item>(g: Region<Item>, items: Item[], within: Computation | null): void {
	const have = g.rows.length;
	const n = items.length;

	const reuse: number[] = new Array(n);
	if (g.keys.length > 0) {
		const keyOf = g.keys[0];
		const oldIds: number[] = new Array(have);
		for (let i = 0; i < have; i += 1) { oldIds[i] = keyOf(g.cells[i].peek()); }
		const newIds: number[] = new Array(n);
		const seen = new Map<number, number>();
		for (let j = 0; j < n; j += 1) {
			const k = keyOf(items[j]);
			if (seen.has(k)) {
				throw new Error("ForList: the key " + k.toString() + " is used by rows "
					+ (seen.get(k) as number).toString() + " and " + j.toString());
			}
			seen.set(k, j);
			newIds[j] = k;
		}
		matchByIds<number>(oldIds, newIds, reuse);
	} else {
		const oldIds: Item[] = new Array(have);
		for (let i = 0; i < have; i += 1) { oldIds[i] = g.cells[i].peek(); }
		g.list.matchByIdentity(oldIds, items, reuse);
	}

	const fresh: Built<Item>[] = [];
	const freshAt: number[] = [];
	try {
		for (let j = 0; j < n; j += 1) {
			if (reuse[j] >= 0) { continue; }
			const b = makeBuilt<Item>(g, items[j], within);
			fresh.push(b);
			freshAt.push(j);
			buildHeldOrDispose<Item>(g, b);
		}
	} catch (e) {
		for (const b of fresh) { b.dispose(); }
		throw e;
	}

	const nextRows: Row[] = new Array(n);
	const nextCells: Signal<Item>[] = new Array(n);
	const nextDisposers: (() => void)[] = new Array(n);
	const kept: boolean[] = new Array(have);
	for (let i = 0; i < have; i += 1) { kept[i] = false; }

	for (let k = 0; k < fresh.length; k += 1) {
		const j = freshAt[k];
		nextRows[j] = fresh[k].row;
		nextCells[j] = fresh[k].cell;
		nextDisposers[j] = fresh[k].dispose;
	}
	for (let j = 0; j < n; j += 1) {
		const from = reuse[j];
		if (from < 0) { continue; }
		nextRows[j] = g.rows[from];
		nextCells[j] = g.cells[from];
		nextDisposers[j] = g.disposers[from];
		kept[from] = true;
		g.cells[from].set(items[j]);
	}

	for (let i = 0; i < have; i += 1) {
		if (!kept[i]) { g.disposers[i](); }
	}

	const reconcile = step(StepKind.Reconcile, null, null);
	reconcile.prev = g.rows;
	reconcile.next = nextRows;
	g.steps.push(reconcile);
	g.rows = nextRows;
	g.cells = nextCells;
	g.disposers = nextDisposers;
}

function applyOp<Item>(g: Region<Item>, op: ListOp<Item>, within: Computation | null): void {
	match (op.kind) {
		ListOpKind.Insert => insertRow<Item>(g, op.a, op.v, within),
		ListOpKind.Move => moveRowTo<Item>(g, op.a, op.b),
		ListOpKind.Remove => removeRowAt<Item>(g, op.a),
		ListOpKind.Set => g.cells[op.a].set(op.v),
	};
}

// An op that raises inside a row body is taken off the queue, so the region is left loud and never
// re-applied on the next bump; a pending read leaves its op, and the ones after it, for the retry.
function takeOps<Item>(g: Region<Item>, q: ListQueue<Item>, items: Item[], within: Computation | null): void {
	if (q.reset) {
		try {
			resetTo<Item>(g, items, within);
		} catch (e) {
			if (!(e instanceof NotReadyError)) { q.reset = false; q.ops = []; }
			throw e;
		}
		q.reset = false;
		q.ops = [];
		return;
	}
	const pending = q.ops;
	let done = 0;
	try {
		while (done < pending.length) {
			applyOp<Item>(g, pending[done], within);
			done += 1;
		}
	} catch (e) {
		q.ops = pending.slice(done + (e instanceof NotReadyError ? 0 : 1), pending.length);
		throw e;
	}
	q.ops = [];
}

function nodeBefore<Item>(g: Region<Item>, before: Row | null): HostNode | null {
	if (before === null) { return g.anchor; }
	return before.start;
}

function playSteps<Item>(g: Region<Item>): void {
	const steps = g.steps;
	g.steps = [];
	for (const s of steps) {
		match (s.kind) {
			StepKind.Insert | StepKind.Move => moveRow(g.host, g.parent, s.row as Row, nodeBefore<Item>(g, s.before)),
			StepKind.Remove => removeRow(g.host, g.parent, s.row as Row),
			StepKind.Reconcile => reconcileArrays(g.host, g.parent, s.prev, s.next, g.anchor, "ForList"),
		};
	}
}

export function listRegion<Item>(
	list: List<Item>,
	row: (item: Accessor<Item>) => NeonNode,
	keyOf: ((item: Item) => number) | null,
): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		if (isServer()) {
			serverRegionStart(host, parent, before);
			const disposers: (() => void)[] = [];
			onCleanup(() => { for (const d of disposers) { d(); } });
			for (const v of untrack((): Item[] => list.read())) {
				mountAt(host, parent, before, createRoot((d) => {
					disposers.push(d);
					return makeRow(row(accessor((): Item => v)));
				}));
			}
			skipRegionEffect();
			serverRegionEnd(host, parent, before);
			return;
		}
		const anchor = regionAnchor(host, parent, before);

		const g: Region<Item> = {
			host: host,
			parent: parent,
			anchor: anchor,
			placed: false,
			home: regionHome(host, parent, anchor),
			owner: getOwner(),
			list: list,
			row: row,
			keys: keyOf === null ? [] : [keyOf as (item: Item) => number],
			rows: [],
			cells: [],
			disposers: [],
			steps: [],
		};

		const q = list.attach();
		onCleanup(() => {
			list.detach(q);
			for (const d of g.disposers) { d(); }
		});

		const initial = untrack((): Item[] => list.read());
		for (let i = 0; i < initial.length; i += 1) { insertFirst<Item>(g, initial[i]); }

		createRenderEffect<Item[]>(
			(prev: Item[] | null): Item[] => {
				const items = list.read();
				takeOps<Item>(g, q, items, getOwner());
				return items;
			},
			(items: Item[], prev: Item[] | null): Cleanup | null => {
				if (g.placed) { g.parent = regionParent(host, anchor, "ForList"); }
				playSteps<Item>(g);
				g.placed = true;
				return null;
			},
		);
		sealRegion(host, parent, anchor);
	};
}
