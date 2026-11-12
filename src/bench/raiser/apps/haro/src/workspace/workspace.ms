import {
	Axis,
	CellRect,
	Frame,
	MIN_PANE_CELLS,
	Node,
	NodeKind,
	Pane,
	PaneId,
	Placed,
	TabId,
	along,
	ancestors,
	cellRect,
	firstCells,
	leaf,
	paneWith,
	panes,
	place,
	resizeLimits,
	setFirstCells,
	withSplit,
	without,
} from "./tree";

export const DEFAULT_DIVIDER_CELLS: int32 = 1;

export enum Direction {
	Left,
	Right,
	Up,
	Down,
}

export interface Tab {
	id: TabId;
	title: string | null;
	root: Node;
	focused: PaneId;
	zoomed: PaneId | null;
}

export interface Workspace {
	tabs: Tab[];
	active: TabId | null;
	dividerCells: int32;
	issuedPanes: int32;
	issuedTabs: int32;
	clock: int64;
}

export enum WorkspaceError {
	DividerOutOfRange,
	SizeOutOfRange,
	CellsOutOfRange,
	UnknownPane,
	UnknownTab,
	NoTabAtIndex,
	NoRoomToSplit,
	NoDivider,
	EmptyWorkspace,
}

export enum CommandKind {
	NewTab,
	CloseTab,
	GotoTab,
	CycleTab,
	MoveTab,
	RenameTab,
	Split,
	ClosePane,
	FocusPane,
	FocusDirection,
	CyclePane,
	Resize,
	MoveDivider,
	ToggleZoom,
	Fit,
}

export struct WorkspaceCommand = match (kind: CommandKind) {
	CommandKind.NewTab => {},
	CommandKind.CloseTab => { tab: TabId },
	CommandKind.GotoTab => { index: int32 },
	CommandKind.CycleTab => { by: int32 },
	CommandKind.MoveTab => { by: int32 },
	CommandKind.RenameTab => { tab: TabId, title: string | null },
	CommandKind.Split => { pane: PaneId, axis: Axis },
	CommandKind.ClosePane => { pane: PaneId },
	CommandKind.FocusPane => { pane: PaneId },
	CommandKind.FocusDirection => { direction: Direction },
	CommandKind.CyclePane => { by: int32 },
	CommandKind.Resize => { direction: Direction, cells: int32 },
	CommandKind.MoveDivider => { pane: PaneId, axis: Axis, by: int32 },
	CommandKind.ToggleZoom => {},
	CommandKind.Fit => {},
};

export struct TabEntry {
	id: TabId;
	title: string | null;
}

export enum EventKind {
	PaneClosed,
	TabsChanged,
	PaneOpened,
	PaneResized,
	ZoomChanged,
	FocusChanged,
	WorkspaceEmpty,
}

export struct WorkspaceEvent = match (kind: EventKind) {
	EventKind.PaneClosed => { pane: PaneId },
	EventKind.TabsChanged => { tabs: TabEntry[], active: TabId | null },
	EventKind.PaneOpened => {
		pane: PaneId,
		tab: TabId,
		origin: PaneId | null,
		rect: CellRect,
	},
	EventKind.PaneResized => { pane: PaneId, rect: CellRect },
	EventKind.ZoomChanged => { tab: TabId, pane: PaneId | null },
	EventKind.FocusChanged => { pane: PaneId },
	EventKind.WorkspaceEmpty => {},
};

struct ZoomEntry {
	tab: TabId;
	pane: PaneId | null;
}

struct Snapshot {
	panes: PaneId[];
	tabs: TabEntry[];
	active: TabId | null;
	zooms: ZoomEntry[];
	focused: PaneId | null;
}

export function create(
	this typeof Workspace,
	dividerCells: int32,
): Result<Workspace, WorkspaceError> {
	if (dividerCells < 0) {
		return Result.err(WorkspaceError.DividerOutOfRange);
	}
	return Result.ok({
		tabs: [],
		active: null,
		dividerCells: dividerCells,
		issuedPanes: 0,
		issuedTabs: 0,
		clock: 0,
	});
}

export function layout(
	this tab: Tab,
	cols: int32,
	rows: int32,
	dividerCells: int32,
): Placed[] {
	const whole = cellRect(0, 0, cols, rows);
	const placed = tab.root.place(whole, dividerCells);
	const zoomed = tab.zoomed;
	if (zoomed === null) { return placed; }
	return placed.map((p: Placed): Placed =>
		p.pane.id == zoomed ? { pane: p.pane, rect: whole } : p
	);
}

export function activeTab(this w: Workspace): Tab | null {
	const active = w.active;
	if (active === null) { return null; }
	return w.tabWith(active);
}

export function focusedPane(this w: Workspace): PaneId | null {
	return w.activeTab()?.focused ?? null;
}

export function tabWith(this w: Workspace, id: TabId): Tab | null {
	for (const tab of w.tabs) {
		if (tab.id == id) { return tab; }
	}
	return null;
}

function tabIndex(this w: Workspace, id: TabId): int32 {
	for (let i: int32 = 0; i < w.tabs.length; i++) {
		if (w.tabs[i].id == id) { return i; }
	}
	return -1;
}

function tabOf(this w: Workspace, id: PaneId): Tab | null {
	for (const tab of w.tabs) {
		if (tab.root.paneWith(id) !== null) { return tab; }
	}
	return null;
}

function wrapped(index: int32, count: int32): int32 {
	return ((index % count) + count) % count;
}

function touch(this w: Workspace, pane: Pane): void {
	w.clock += 1;
	pane.focusedAt = w.clock;
}

function focusIn(this w: Workspace, tab: Tab, id: PaneId): void {
	const pane = tab.root.paneWith(id);
	if (pane === null) { return; }
	tab.focused = id;
	w.touch(pane);
}

function issuePane(this w: Workspace, origin: PaneId | null): Pane {
	w.issuedPanes += 1;
	return {
		id: w.issuedPanes as PaneId,
		origin: origin,
		focusedAt: 0,
		rect: cellRect(0, 0, 0, 0),
	};
}

function newTab(this w: Workspace): void {
	w.issuedTabs += 1;
	const pane = w.issuePane(null);
	const tab: Tab = {
		id: w.issuedTabs as TabId,
		title: null,
		root: leaf(pane),
		focused: pane.id,
		zoomed: null,
	};
	w.tabs.push(tab);
	w.active = tab.id;
	w.touch(pane);
}

function closeTab(this w: Workspace, id: TabId): Result<void, WorkspaceError> {
	const index = w.tabIndex(id);
	if (index < 0) { return Result.err(WorkspaceError.UnknownTab); }
	const kept: Tab[] = [];
	for (const tab of w.tabs) {
		if (!(tab.id == id)) { kept.push(tab); }
	}
	w.tabs = kept;
	const active = w.active;
	if (active !== null && active == id) {
		w.active = kept.length == 0
			? null
			: kept[Math.min(index, kept.length - 1)].id;
	}
	return Result.ok(null);
}

function moveTab(this w: Workspace, by: int32): void {
	const active = w.active;
	if (active === null) { return; }
	const from = w.tabIndex(active);
	const to = wrapped(from + by, w.tabs.length);
	const moving = w.tabs[from];
	const others: Tab[] = [];
	for (const tab of w.tabs) {
		if (!(tab.id == active)) { others.push(tab); }
	}
	const order: Tab[] = [];
	for (let i: int32 = 0; i < others.length; i++) {
		if (i == to) { order.push(moving); }
		order.push(others[i]);
	}
	if (to == others.length) { order.push(moving); }
	w.tabs = order;
}

function split(
	this w: Workspace,
	id: PaneId,
	axis: Axis,
	cols: int32,
	rows: int32,
): Result<void, WorkspaceError> {
	const tab = w.tabOf(id);
	if (tab === null) { return Result.err(WorkspaceError.UnknownPane); }
	const divider = w.dividerCells;
	for (const p of tab.root.place(cellRect(0, 0, cols, rows), divider)) {
		if (p.pane.id == id && p.rect.along(axis) < 2 * MIN_PANE_CELLS + divider) {
			return Result.err(WorkspaceError.NoRoomToSplit);
		}
	}
	const created = w.issuePane(id);
	tab.root = tab.root.withSplit(id, created, axis);
	tab.zoomed = null;
	w.focusIn(tab, created.id);
	return Result.ok(null);
}

function center2(r: CellRect): [int32, int32] {
	return [2 * r.x + r.cols, 2 * r.y + r.rows];
}

function nearest(placed: Placed[], from: CellRect): Pane {
	const [cx, cy] = center2(from);
	let best = placed[0];
	let bestDistance: int64 = -1;
	for (const p of placed) {
		const [x, y] = center2(p.rect);
		const dx = (x - cx) as int64;
		const dy = (y - cy) as int64;
		const distance = dx * dx + dy * dy;
		if (
			bestDistance < 0 ||
			distance < bestDistance ||
			(distance == bestDistance && p.pane.focusedAt > best.pane.focusedAt)
		) {
			best = p;
			bestDistance = distance;
		}
	}
	return best.pane;
}

function closePane(
	this w: Workspace,
	id: PaneId,
	cols: int32,
	rows: int32,
): Result<void, WorkspaceError> {
	const tab = w.tabOf(id);
	if (tab === null) { return Result.err(WorkspaceError.UnknownPane); }
	const whole = cellRect(0, 0, cols, rows);
	const closed = tab.root.paneWith(id);
	const old = tab.root.place(whole, w.dividerCells);
	const rest = tab.root.without(id);
	if (closed === null || rest === null) { return w.closeTab(tab.id); }
	tab.root = rest;
	tab.zoomed = null;
	if (!(tab.focused == id)) { return Result.ok(null); }
	const origin = closed.origin;
	if (origin !== null && rest.paneWith(origin) !== null) {
		w.focusIn(tab, origin);
		return Result.ok(null);
	}
	let from = whole;
	for (const p of old) {
		if (p.pane.id == id) { from = p.rect; }
	}
	const next = nearest(rest.place(whole, w.dividerCells), from);
	w.focusIn(tab, next.id);
	return Result.ok(null);
}

function focusPane(
	this w: Workspace,
	id: PaneId,
): Result<void, WorkspaceError> {
	const tab = w.tabOf(id);
	if (tab === null) { return Result.err(WorkspaceError.UnknownPane); }
	w.active = tab.id;
	if (tab.focused == id) { return Result.ok(null); }
	const zoomed = tab.zoomed;
	if (zoomed !== null && !(zoomed == id)) { tab.zoomed = null; }
	w.focusIn(tab, id);
	return Result.ok(null);
}

function touches(
	from: CellRect,
	to: CellRect,
	d: Direction,
	gap: int32,
): boolean {
	return match (d) {
		Direction.Left => to.x + to.cols + gap == from.x,
		Direction.Right => from.x + from.cols + gap == to.x,
		Direction.Up => to.y + to.rows + gap == from.y,
		Direction.Down => from.y + from.rows + gap == to.y,
	};
}

function overlap(from: CellRect, to: CellRect, d: Direction): int32 {
	if (d == Direction.Left || d == Direction.Right) {
		return Math.min(from.y + from.rows, to.y + to.rows) -
			Math.max(from.y, to.y);
	}
	return Math.min(from.x + from.cols, to.x + to.cols) - Math.max(from.x, to.x);
}

function neighbour(
	placed: Placed[],
	id: PaneId,
	d: Direction,
	gap: int32,
): Pane | null {
	let from: CellRect | null = null;
	for (const p of placed) {
		if (p.pane.id == id) { from = p.rect; }
	}
	if (from === null) { return null; }
	let best: Pane | null = null;
	let bestOverlap: int32 = 0;
	for (const p of placed) {
		if (!touches(from, p.rect, d, gap)) { continue; }
		const shared = overlap(from, p.rect, d);
		if (shared <= 0) { continue; }
		if (
			best === null ||
			shared > bestOverlap ||
			(shared == bestOverlap && p.pane.focusedAt > best.focusedAt)
		) {
			best = p.pane;
			bestOverlap = shared;
		}
	}
	return best;
}

function focusDirection(
	this w: Workspace,
	tab: Tab,
	d: Direction,
	cols: int32,
	rows: int32,
): void {
	const placed = tab.root.place(cellRect(0, 0, cols, rows), w.dividerCells);
	const target = neighbour(placed, tab.focused, d, w.dividerCells);
	if (target === null) { return; }
	tab.zoomed = null;
	w.focusIn(tab, target.id);
}

function cyclePane(this w: Workspace, tab: Tab, by: int32): void {
	const order = tab.root.panes();
	if (order.length < 2) { return; }
	let at: int32 = 0;
	for (let i: int32 = 0; i < order.length; i++) {
		if (order[i].id == tab.focused) { at = i; }
	}
	const next = order[wrapped(at + by, order.length)];
	if (next.id == tab.focused) { return; }
	tab.zoomed = null;
	w.focusIn(tab, next.id);
}

function axisOf(d: Direction): Axis {
	return match (d) {
		Direction.Left | Direction.Right => Axis.SideBySide,
		Direction.Up | Direction.Down => Axis.Stacked,
	};
}

function shift(this w: Workspace, tab: Tab, frame: Frame, by: int32): void {
	const divider = w.dividerCells;
	const size = frame.rect.along(frame.split.axis);
	const [low, high] = frame.split.resizeLimits(size, divider);
	if (low > high) { return; }
	const current = frame.split.firstCells(size, divider);
	const moved = Math.min(Math.max(current + by, low), high);
	tab.zoomed = null;
	frame.split.setFirstCells(moved, size, divider);
}

function resize(
	this w: Workspace,
	tab: Tab,
	d: Direction,
	cells: int32,
	cols: int32,
	rows: int32,
): void {
	const axis = axisOf(d);
	const whole = cellRect(0, 0, cols, rows);
	const frames = tab.root.ancestors(tab.focused, whole, w.dividerCells);
	if (frames === null) { return; }
	for (const frame of frames) {
		if (frame.split.axis != axis) { continue; }
		const back = d == Direction.Left || d == Direction.Up;
		w.shift(tab, frame, back ? -cells : cells);
		return;
	}
}

function moveDivider(
	this w: Workspace,
	id: PaneId,
	axis: Axis,
	by: int32,
	cols: int32,
	rows: int32,
): Result<void, WorkspaceError> {
	const tab = w.tabOf(id);
	if (tab === null) { return Result.err(WorkspaceError.UnknownPane); }
	if (by == 0) { return Result.err(WorkspaceError.CellsOutOfRange); }
	const whole = cellRect(0, 0, cols, rows);
	for (const frame of tab.root.ancestors(id, whole, w.dividerCells) ?? []) {
		if (frame.split.axis != axis) { continue; }
		if (frame.split.first.paneWith(id) === null) { continue; }
		w.shift(tab, frame, by);
		return Result.ok(null);
	}
	return Result.err(WorkspaceError.NoDivider);
}

function toggleZoom(this w: Workspace, tab: Tab): void {
	if (tab.zoomed !== null) {
		tab.zoomed = null;
		return;
	}
	if (tab.root.kind == NodeKind.Split) { tab.zoomed = tab.focused; }
}

function run(
	this w: Workspace,
	c: WorkspaceCommand,
	cols: int32,
	rows: int32,
): Result<void, WorkspaceError> {
	if (c.kind == CommandKind.NewTab) {
		w.newTab();
		return Result.ok(null);
	}
	if (c.kind == CommandKind.CloseTab) { return w.closeTab(c.tab); }
	if (c.kind == CommandKind.RenameTab) {
		const tab = w.tabWith(c.tab);
		if (tab === null) { return Result.err(WorkspaceError.UnknownTab); }
		tab.title = c.title;
		return Result.ok(null);
	}
	if (c.kind == CommandKind.Split) {
		return w.split(c.pane, c.axis, cols, rows);
	}
	if (c.kind == CommandKind.ClosePane) {
		return w.closePane(c.pane, cols, rows);
	}
	if (c.kind == CommandKind.FocusPane) { return w.focusPane(c.pane); }
	if (c.kind == CommandKind.MoveDivider) {
		return w.moveDivider(c.pane, c.axis, c.by, cols, rows);
	}
	if (c.kind == CommandKind.Fit) { return Result.ok(null); }
	if (c.kind == CommandKind.GotoTab) {
		if (c.index < 0 || c.index >= w.tabs.length) {
			return Result.err(WorkspaceError.NoTabAtIndex);
		}
		w.active = w.tabs[c.index].id;
		return Result.ok(null);
	}
	const tab = w.activeTab();
	if (tab === null) { return Result.err(WorkspaceError.EmptyWorkspace); }
	if (c.kind == CommandKind.CycleTab) {
		const at = w.tabIndex(tab.id);
		w.active = w.tabs[wrapped(at + c.by, w.tabs.length)].id;
	} else if (c.kind == CommandKind.MoveTab) {
		w.moveTab(c.by);
	} else if (c.kind == CommandKind.FocusDirection) {
		w.focusDirection(tab, c.direction, cols, rows);
	} else if (c.kind == CommandKind.CyclePane) {
		w.cyclePane(tab, c.by);
	} else if (c.kind == CommandKind.Resize) {
		if (c.cells < 1) { return Result.err(WorkspaceError.CellsOutOfRange); }
		w.resize(tab, c.direction, c.cells, cols, rows);
	} else if (c.kind == CommandKind.ToggleZoom) {
		w.toggleZoom(tab);
	}
	return Result.ok(null);
}

function snapshot(this w: Workspace): Snapshot {
	const ids: PaneId[] = [];
	const entries: TabEntry[] = [];
	const zooms: ZoomEntry[] = [];
	for (const tab of w.tabs) {
		for (const pane of tab.root.panes()) { ids.push(pane.id); }
		entries.push({ id: tab.id, title: tab.title });
		zooms.push({ tab: tab.id, pane: tab.zoomed });
	}
	return {
		panes: ids,
		tabs: entries,
		active: w.active,
		zooms: zooms,
		focused: w.focusedPane(),
	};
}

function holds(ids: PaneId[], id: PaneId): boolean {
	for (const known of ids) {
		if (known == id) { return true; }
	}
	return false;
}

function sameId(a: PaneId | null, b: PaneId | null): boolean {
	if (a === null || b === null) { return a === null && b === null; }
	return a == b;
}

function sameTabs(a: Snapshot, b: Snapshot): boolean {
	if (a.tabs.length != b.tabs.length) { return false; }
	const x = a.active;
	const y = b.active;
	if (x === null || y === null) {
		if (!(x === null && y === null)) { return false; }
	} else if (!(x == y)) { return false; }
	for (let i: int32 = 0; i < a.tabs.length; i++) {
		if (!(a.tabs[i].id == b.tabs[i].id)) { return false; }
		if (a.tabs[i].title != b.tabs[i].title) { return false; }
	}
	return true;
}

function zoomBefore(before: Snapshot, tab: TabId): PaneId | null {
	for (const z of before.zooms) {
		if (z.tab == tab) { return z.pane; }
	}
	return null;
}

function changes(
	this w: Workspace,
	before: Snapshot,
	cols: int32,
	rows: int32,
): WorkspaceEvent[] {
	const after = w.snapshot();
	const events: WorkspaceEvent[] = [];
	for (const id of before.panes) {
		if (!holds(after.panes, id)) {
			events.push({ kind: EventKind.PaneClosed, pane: id });
		}
	}
	if (!sameTabs(before, after)) {
		events.push({
			kind: EventKind.TabsChanged,
			tabs: after.tabs,
			active: after.active,
		});
	}
	const resized: WorkspaceEvent[] = [];
	for (const tab of w.tabs) {
		for (const p of tab.layout(cols, rows, w.dividerCells)) {
			if (!holds(before.panes, p.pane.id)) {
				events.push({
					kind: EventKind.PaneOpened,
					pane: p.pane.id,
					tab: tab.id,
					origin: p.pane.origin,
					rect: p.rect,
				});
			} else if (!(p.pane.rect == p.rect)) {
				resized.push({
					kind: EventKind.PaneResized,
					pane: p.pane.id,
					rect: p.rect,
				});
			}
			p.pane.rect = p.rect;
		}
	}
	for (const e of resized) { events.push(e); }
	for (const z of after.zooms) {
		if (!sameId(zoomBefore(before, z.tab), z.pane)) {
			events.push({ kind: EventKind.ZoomChanged, tab: z.tab, pane: z.pane });
		}
	}
	const focused = after.focused;
	if (focused !== null && !sameId(before.focused, focused)) {
		events.push({ kind: EventKind.FocusChanged, pane: focused });
	}
	if (before.tabs.length > 0 && after.tabs.length == 0) {
		events.push({ kind: EventKind.WorkspaceEmpty });
	}
	return events;
}

export function apply(
	this w: Workspace,
	c: WorkspaceCommand,
	cols: int32,
	rows: int32,
): Result<WorkspaceEvent[], WorkspaceError> {
	if (cols < 1 || rows < 1) {
		return Result.err(WorkspaceError.SizeOutOfRange);
	}
	const before = w.snapshot();
	try w.run(c, cols, rows);
	return Result.ok(w.changes(before, cols, rows));
}
