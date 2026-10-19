// @stdout: overload-arrow ok 21
// note: an arrow argument to an overloaded call runs the first overload, in rank order, whose parameter the arrow fits: a sync or an async compute picks `(prev) => int32` or `(prev) => Promise<int32>` with or without annotations, a named function picks the same, an untyped arrow skips a `string` overload, in either declaration order and for a generic pair. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

async function later(): Promise<int32> { return 3; }
function syncFn(p: int32 | null): int32 { return 5; }
async function asyncFn(p: int32 | null): Promise<int32> { return 6; }

function syncFirst(compute: (prev: int32 | null) => int32): string { return "sync " + compute(null).toString(); }
function syncFirst(compute: (prev: int32 | null) => Promise<int32>): string { return "async"; }
function asyncFirst(compute: (prev: int32 | null) => Promise<int32>): string { return "async"; }
function asyncFirst(compute: (prev: int32 | null) => int32): string { return "sync " + compute(null).toString(); }
function memo<T>(compute: (prev: T | null) => T): string { return "sync"; }
function memo<T>(compute: (prev: T | null) => Promise<T>): string { return "async"; }

function on(name: string): string { return "name:" + name; }
function on(cb: (x: number) => number): string { return "cb:" + cb(1.5).toString(); }
function on2(cb: (x: number) => number): string { return "cb:" + cb(1.5).toString(); }
function on2(name: string): string { return "name:" + name; }

row("syncFirst sync arrow", syncFirst((p: int32 | null): int32 => 1), "sync 1");
row("syncFirst untyped sync arrow", syncFirst((p) => 2), "sync 2");
row("syncFirst async arrow", syncFirst(async (p: int32 | null): Promise<int32> => 4), "async");
row("syncFirst untyped async arrow", syncFirst(async (p) => 4), "async");
row("syncFirst promise arrow", syncFirst((p: int32 | null): Promise<int32> => later()), "async");
row("syncFirst named sync", syncFirst(syncFn), "sync 5");
row("syncFirst named async", syncFirst(asyncFn), "async");
row("asyncFirst sync arrow", asyncFirst((p: int32 | null): int32 => 1), "sync 1");
row("asyncFirst untyped sync arrow", asyncFirst((p) => 2), "sync 2");
row("asyncFirst async arrow", asyncFirst(async (p: int32 | null): Promise<int32> => 4), "async");
row("asyncFirst untyped async arrow", asyncFirst(async (p) => 4), "async");
row("asyncFirst named sync", asyncFirst(syncFn), "sync 5");
row("asyncFirst named async", asyncFirst(asyncFn), "async");
row("memo explicit sync", memo<int32>((p: int32 | null): int32 => 1), "sync");
row("memo explicit async", memo<int32>(async (p: int32 | null): Promise<int32> => 4), "async");
row("memo inferred sync", memo((p: int32 | null): int32 => 1), "sync");
row("memo inferred async", memo(async (p: int32 | null): Promise<int32> => 4), "async");
row("on untyped arrow", on((x) => x + 1), "cb:2.5");
row("on name", on("n"), "name:n");
row("on2 untyped arrow", on2((x) => x + 1), "cb:2.5");
row("on2 name", on2("n"), "name:n");
console.log(wrong == "" ? "overload-arrow ok " + rows.toString() : "overload-arrow WRONG" + wrong);
