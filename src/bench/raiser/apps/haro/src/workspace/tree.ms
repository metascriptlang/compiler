export type PaneId = distinct int32;
export type TabId = distinct int32;
@delegate export function `==`(this a: PaneId, b: PaneId): boolean;
@delegate export function `==`(this a: TabId, b: TabId): boolean;

export const MIN_PANE_CELLS: int32 = 1;

export enum Axis {
	SideBySide,
	Stacked,
}

export struct CellRect {
	x: int32;
	y: int32;
	cols: int32;
	rows: int32;
}

export function cellRect(
	x: int32,
	y: int32,
	cols: int32,
	rows: int32,
): CellRect {
	return { x: x, y: y, cols: cols, rows: rows };
}

export interface Pane {
	id: PaneId;
	origin: PaneId | null;
	focusedAt: int64;
	rect: CellRect;
}

export interface Split {
	axis: Axis;
	ratio: float64;
	first: Node;
	second: Node;
}

export enum NodeKind {
	Pane,
	Split,
}

export struct Node = match (kind: NodeKind) {
	NodeKind.Pane => { pane: Pane },
	NodeKind.Split => { split: Split },
};

export struct Placed {
	pane: Pane;
	rect: CellRect;
}

export struct Frame {
	split: Split;
	rect: CellRect;
}

export function leaf(pane: Pane): Node {
	return { kind: NodeKind.Pane, pane: pane };
}

export function along(this r: CellRect, axis: Axis): int32 {
	return match (axis) {
		Axis.SideBySide => r.cols,
		Axis.Stacked => r.rows,
	};
}

function clamp(value: int32, low: int32, high: int32): int32 {
	return Math.min(Math.max(value, low), high);
}

function minAlong(this n: Node, axis: Axis, divider: int32): int32 {
	if (n.kind == NodeKind.Pane) { return MIN_PANE_CELLS; }
	const a = n.split.first.minAlong(axis, divider);
	const b = n.split.second.minAlong(axis, divider);
	if (n.split.axis == axis) { return a + divider + b; }
	return Math.max(a, b);
}

function dividerIn(size: int32, divider: int32): int32 {
	return Math.min(divider, size);
}

export function firstCells(
	this s: Split,
	size: int32,
	divider: int32,
): int32 {
	const available = size - dividerIn(size, divider);
	const wanted = Math.floor(available * s.ratio + 0.5) as int32;
	const low = s.first.minAlong(s.axis, divider);
	const high = available - s.second.minAlong(s.axis, divider);
	if (low <= high) { return clamp(wanted, low, high); }
	return clamp(wanted, 0, available);
}

export function resizeLimits(
	this s: Split,
	size: int32,
	divider: int32,
): [int32, int32] {
	const available = size - dividerIn(size, divider);
	return [
		s.first.minAlong(s.axis, divider),
		available - s.second.minAlong(s.axis, divider),
	];
}

export function setFirstCells(
	this s: Split,
	cells: int32,
	size: int32,
	divider: int32,
): void {
	const available = size - dividerIn(size, divider);
	if (available > 0) { s.ratio = (cells as float64) / (available as float64); }
}

function childRects(
	this s: Split,
	r: CellRect,
	divider: int32,
): [CellRect, CellRect] {
	const size = r.along(s.axis);
	const gap = dividerIn(size, divider);
	const first = s.firstCells(size, divider);
	const second = size - gap - first;
	if (s.axis == Axis.SideBySide) {
		return [
			{ ...r, cols: first },
			{ ...r, x: r.x + first + gap, cols: second },
		];
	}
	return [
		{ ...r, rows: first },
		{ ...r, y: r.y + first + gap, rows: second },
	];
}

function placeInto(
	this n: Node,
	r: CellRect,
	divider: int32,
	out: Placed[],
): void {
	if (n.kind == NodeKind.Pane) {
		out.push({ pane: n.pane, rect: r });
		return;
	}
	const [a, b] = n.split.childRects(r, divider);
	n.split.first.placeInto(a, divider, out);
	n.split.second.placeInto(b, divider, out);
}

export function place(this n: Node, r: CellRect, divider: int32): Placed[] {
	const out: Placed[] = [];
	n.placeInto(r, divider, out);
	return out;
}

export function panes(this n: Node): Pane[] {
	return n
		.place({ x: 0, y: 0, cols: 0, rows: 0 }, 0)
		.map((p: Placed): Pane => p.pane);
}

export function paneWith(this n: Node, id: PaneId): Pane | null {
	if (n.kind == NodeKind.Pane) { return n.pane.id == id ? n.pane : null; }
	return n.split.first.paneWith(id) ?? n.split.second.paneWith(id);
}

export function ancestors(
	this n: Node,
	id: PaneId,
	r: CellRect,
	divider: int32,
): Frame[] | null {
	if (n.kind == NodeKind.Pane) { return n.pane.id == id ? [] : null; }
	const [a, b] = n.split.childRects(r, divider);
	const found = n.split.first.ancestors(id, a, divider) ??
		n.split.second.ancestors(id, b, divider);
	if (found === null) { return null; }
	found.push({ split: n.split, rect: r });
	return found;
}

export function withSplit(
	this n: Node,
	id: PaneId,
	created: Pane,
	axis: Axis,
): Node {
	if (n.kind == NodeKind.Pane) {
		if (!(n.pane.id == id)) { return n; }
		const split: Split = {
			axis: axis,
			ratio: 0.5,
			first: n,
			second: leaf(created),
		};
		return { kind: NodeKind.Split, split: split };
	}
	n.split.first = n.split.first.withSplit(id, created, axis);
	n.split.second = n.split.second.withSplit(id, created, axis);
	return n;
}

export function without(this n: Node, id: PaneId): Node | null {
	if (n.kind == NodeKind.Pane) { return n.pane.id == id ? null : n; }
	const first = n.split.first.without(id);
	if (first === null) { return n.split.second; }
	const second = n.split.second.without(id);
	if (second === null) { return n.split.first; }
	n.split.first = first;
	n.split.second = second;
	return n;
}

function pane(id: int32): Pane {
	return {
		id: id as PaneId,
		origin: null,
		focusedAt: 0,
		rect: { x: 0, y: 0, cols: 0, rows: 0 },
	};
}

function columns(count: int32): Node {
	let n = leaf(pane(0));
	for (let i: int32 = 0; i < count - 1; i++) {
		n = n.withSplit(i as PaneId, pane(i + 1), Axis.SideBySide);
	}
	return n;
}

function covers(this placed: Placed[], whole: CellRect, divider: int32): int32 {
	let edge = whole.x;
	let gaps: int32 = 0;
	if (placed.length == 0 || placed[0].rect.x != whole.x) { return -1; }
	for (const p of placed) {
		const gap = p.rect.x - edge;
		if (gap < 0 || gap > divider || p.rect.cols < 0) { return -1; }
		if (p.rect.y != whole.y || p.rect.rows != whole.rows) { return -1; }
		gaps += gap;
		edge = p.rect.x + p.rect.cols;
	}
	return edge == whole.x + whole.cols ? gaps : -1;
}

test "a split halves a pane and gives the odd cell to the first child" {
	const n = leaf(pane(0)).withSplit(0 as PaneId, pane(1), Axis.SideBySide);
	const placed = n.place({ x: 0, y: 0, cols: 81, rows: 24 }, 1);
	assert placed.length == 2;
	assert placed[0].rect == cellRect(0, 0, 40, 24);
	assert placed[1].rect == cellRect(41, 0, 40, 24);
}

test "nested splits fill an odd tab exactly with and without dividers" {
	for (const divider of [0, 1]) {
		for (const cols of [7, 31, 80, 101]) {
			const whole: CellRect = { x: 0, y: 0, cols: cols, rows: 9 };
			const n = columns(4);
			assert n.place(whole, divider).covers(whole, divider) == 3 * divider;
		}
	}
}

test "a stacked split lays rows and leaves columns whole" {
	const n = leaf(pane(0)).withSplit(0 as PaneId, pane(1), Axis.Stacked);
	const placed = n.place({ x: 2, y: 3, cols: 10, rows: 7 }, 0);
	assert placed[0].rect == cellRect(2, 3, 10, 4);
	assert placed[1].rect == cellRect(2, 7, 10, 3);
}

test "a ratio that would starve a subtree is held at its minimum" {
	const n = columns(3);
	if (n.kind == NodeKind.Split) { n.split.ratio = 0.01; }
	const placed = n.place({ x: 0, y: 0, cols: 9, rows: 1 }, 1);
	assert placed[0].rect.cols == MIN_PANE_CELLS;
	for (const p of placed) { assert p.rect.cols >= MIN_PANE_CELLS; }
}

test "a tab too small for its panes still sums exactly" {
	const whole: CellRect = { x: 0, y: 0, cols: 2, rows: 1 };
	const n = columns(4);
	assert n.place(whole, 1).covers(whole, 1) >= 0;
}

test "removing a pane lets its sibling take the parent's place" {
	let n = leaf(pane(0));
	n = n.withSplit(0 as PaneId, pane(1), Axis.SideBySide);
	n = n.withSplit(1 as PaneId, pane(2), Axis.Stacked);
	n = n.withSplit(2 as PaneId, pane(3), Axis.SideBySide);
	const left = n.without(2 as PaneId);
	assert left !== null;
	if (left !== null) {
	const ids = left.panes().map((p: Pane): int32 => p.id as int32);
	assert ids.length == 3;
	assert ids[0] == 0 && ids[1] == 1 && ids[2] == 3;
	const placed = left.place({ x: 0, y: 0, cols: 21, rows: 11 }, 1);
	assert placed[2].rect == cellRect(11, 6, 10, 5);
	}
	assert leaf(pane(0)).without(0 as PaneId) === null;
}
