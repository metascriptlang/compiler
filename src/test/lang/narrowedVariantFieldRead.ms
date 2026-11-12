// A guarded variant field read keeps the declared type of the variant the guard pinned,
// through every receiver shape: local, array element, field path and Result payload.

enum PaneKind { Optional, Scoped, Scalar }

struct PaneTarget { host: int32; pane: int32; }

struct PaneCommand = match (kind: PaneKind) {
	PaneKind.Optional => { pane: PaneTarget | null },
	PaneKind.Scoped => { pane: PaneTarget },
	PaneKind.Scalar => { pane: int32 },
};

struct PaneHolder { items: PaneCommand[]; inner: PaneInner; }

struct PaneInner { items: PaneCommand[]; }

function paneCommands(): PaneCommand[] {
	return [
		{ kind: PaneKind.Scoped, pane: { host: 7, pane: 2 } },
		{ kind: PaneKind.Scalar, pane: 1 },
		{ kind: PaneKind.Optional, pane: { host: 9, pane: 4 } },
	];
}

test "narrowed variant read: a struct payload through an array element" {
	const commands = paneCommands();
	let host = 0;
	if (commands[0].kind == PaneKind.Scoped) host = commands[0].pane.host;
	assert host == 7;
}

test "narrowed variant read: a scalar payload through an array element" {
	const commands = paneCommands();
	let pane = 0;
	if (commands[1].kind == PaneKind.Scalar) pane = commands[1].pane;
	assert pane == 1;
}

test "narrowed variant read: a variable index is the same reference" {
	const commands = paneCommands();
	const i = 1;
	let pane = 0;
	if (commands[i].kind == PaneKind.Scalar) pane = commands[i].pane + 1;
	assert pane == 2;
}

test "narrowed variant read: an array reached through fields" {
	const holder: PaneHolder = { items: paneCommands(), inner: { items: paneCommands() } };
	let outer = 0;
	let nested = 0;
	if (holder.items[0].kind == PaneKind.Scoped) outer = holder.items[0].pane.pane;
	if (holder.inner.items[1].kind == PaneKind.Scalar) nested = holder.inner.items[1].pane;
	assert outer == 2;
	assert nested == 1;
}

test "narrowed variant read: the nullable variant still reads through its carrier" {
	const commands = paneCommands();
	let host = 0;
	if (commands[2].kind == PaneKind.Optional) {
		const target = commands[2].pane;
		if (target != null) host = target.host;
	}
	assert host == 9;
	let direct = 0;
	if (commands[2].kind == PaneKind.Optional && commands[2].pane != null) direct = commands[2].pane.pane;
	assert direct == 4;
}

test "narrowed variant read: a local binding agrees with the array element" {
	const commands = paneCommands();
	const c = commands[0];
	let host = 0;
	if (c.kind == PaneKind.Scoped) host = c.pane.host;
	assert host == 7;
}

interface ShapeCircle { kind: "circle"; r: float64; }

interface ShapeSquare { kind: "square"; side: float64; }

type Shape = ShapeCircle | ShapeSquare;

enum ClickKind { Click, Key }

struct ClickEvent = match (kind: ClickKind) {
	ClickKind.Click => { x: int32 },
	ClickKind.Key => { code: int32 },
};

function squareResult(): Result<Shape, string> {
	const s: ShapeSquare = { kind: "square", side: 3.0 };
	return Result.ok(s);
}

function clickResult(): Result<ClickEvent, string> {
	const e: ClickEvent = { kind: ClickKind.Click, x: 7 };
	return Result.ok(e);
}

test "narrowed variant read: a Result payload narrowed in one condition" {
	const r = squareResult();
	let side = 0.0;
	if (r.ok && r.value.kind == "square") side = r.value.side;
	assert side == 3.0;
}

test "narrowed variant read: a Result payload narrowed in a nested condition" {
	const r = squareResult();
	let side = 0.0;
	if (r.ok) {
		if (r.value.kind == "square") side = r.value.side;
	}
	assert side == 3.0;
}

test "narrowed variant read: a Result payload with an enum discriminant" {
	const r = clickResult();
	let x = 0;
	if (r.ok && r.value.kind == ClickKind.Click) x = r.value.x;
	assert x == 7;
}
