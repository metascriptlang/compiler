import { Axis } from "./haro/src/workspace/tree";
import { CommandKind, DEFAULT_DIVIDER_CELLS, Direction, Workspace, WorkspaceCommand, apply, create, focusedPane, layout, tabWith } from "./haro/src/workspace/workspace";
import { urlSpans } from "./haro/src/screen/links";

const COLS: int32 = 240;
const ROWS: int32 = 64;

function must(w: Workspace, c: WorkspaceCommand): void {
	const r = w.apply(c, COLS, ROWS);
	if (!r.ok) { throw new Error(`refused: ${r.error.toString()}`); }
}

function area(w: Workspace): number {
	const active = w.active;
	if (active === null) { return 0; }
	const t = w.tabWith(active);
	if (t === null) { return 0; }
	let a: number = 0;
	for (const p of t.layout(COLS, ROWS, w.dividerCells)) { a += p.rect.cols * p.rect.rows; }
	return a;
}

function workspaceRound(): number {
	const created = Workspace.create(DEFAULT_DIVIDER_CELLS);
	if (!created.ok) { throw new Error("divider refused"); }
	const w = created.value;
	must(w, { kind: CommandKind.NewTab });
	let acc: number = 0;
	for (let s = 0; s < 12; s += 1) {
		const f = w.focusedPane();
		if (f === null) { break; }
		w.apply({ kind: CommandKind.Split, pane: f, axis: s % 2 == 0 ? Axis.SideBySide : Axis.Stacked }, COLS, ROWS);
		acc += area(w);
	}
	const dirs = [Direction.Left, Direction.Up, Direction.Right, Direction.Down];
	for (let k = 0; k < 64; k += 1) {
		w.apply({ kind: CommandKind.FocusDirection, direction: dirs[k % 4] }, COLS, ROWS);
		const r = w.apply({ kind: CommandKind.Resize, direction: dirs[(k + 1) % 4], cells: 1 }, COLS, ROWS);
		acc += area(w);
	}
	return acc;
}

const WORDS = ["ls", "-la", "error:", "see", "https://example.com/path?q=1", "build", "ok", "http://localhost:8080/", "file.ms:12:3", "warning", "(https://docs.rs/x)", "done."];

function makeLines(n: int32): string[] {
	const out: string[] = [];
	for (let i = 0; i < n; i += 1) {
		let s = "";
		for (let j = 0; j < 12; j += 1) { s = s + WORDS[(i * 7 + j * 3) % 12] + " "; }
		out.push(s);
	}
	return out;
}

const ITER = 40;
const lines = makeLines(2000);
let check: number = 0;
const t0 = performance.now();
for (let it = 0; it < ITER; it += 1) {
	check += workspaceRound();
	for (const l of lines) { check += urlSpans(l).length; }
}
const ms = performance.now() - t0;
console.log(`haro iter=${ITER} ms=${Math.round(ms)} check=${check}`);
