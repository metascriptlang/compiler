// Language tests: interfaces — structs, nested, arrays, mutation, composition

// ===== Shared interfaces =====

interface Vec2 {
	x: number;
	y: number;
}

interface Color {
	r: number;
	g: number;
	b: number;
}

interface Pixel {
	pos: Vec2;
	color: Color;
}

interface Rect {
	topLeft: Vec2;
	width: number;
	height: number;
}

interface Range {
	start: number;
	end: number;
}

interface Entry {
	key: string;
	val: number;
}

interface Table {
	entries: Entry[];
}

interface Config {
	debug: boolean;
	verbose: boolean;
	maxRetries: number;
}

interface QueryBuilder {
	table: string;
	conditions: string[];
	limit: number;
}

// ===== Shared functions =====

function addVec(a: Vec2, b: Vec2): Vec2 {
	return { x: a.x + b.x, y: a.y + b.y };
}

function dotVec(a: Vec2, b: Vec2): number {
	return a.x * b.x + a.y * b.y;
}

function distSq(p: Vec2): number {
	return p.x * p.x + p.y * p.y;
}

function rectArea(r: Rect): number {
	return r.width * r.height;
}

function rangeLen(r: Range): number {
	return r.end - r.start;
}

function rangeContains(r: Range, val: number): boolean {
	return val >= r.start && val < r.end;
}

function tableSet(t: Table, key: string, val: number): void {
	let i = 0;
	while (i < t.entries.length) {
		if (t.entries[i].key == key) { t.entries[i].val = val; return; }
		i += 1;
	}
	t.entries.push({ key: key, val: val });
}

function tableGet(t: Table, key: string): number {
	let i = 0;
	while (i < t.entries.length) {
		if (t.entries[i].key == key) return t.entries[i].val;
		i += 1;
	}
	return -1;
}

function buildQuery(q: QueryBuilder): string {
	let sql = "SELECT * FROM " + q.table;
	if (q.conditions.length > 0) {
		sql = sql + " WHERE";
		let i = 0;
		while (i < q.conditions.length) {
			if (i > 0) sql = sql + " AND";
			sql = sql + " " + q.conditions[i];
			i += 1;
		}
	}
	if (q.limit > 0) sql = sql + " LIMIT " + q.limit;
	return sql;
}

// ===== Tests =====

test "basic struct construction and field access" {
	const v: Vec2 = { x: 3, y: 4 };
	assert v.x == 3;
	assert v.y == 4;
	assert distSq(v) == 25;

	const origin: Vec2 = { x: 0, y: 0 };
	assert distSq(origin) == 0;
}

test "vector arithmetic" {
	const v1: Vec2 = { x: 1, y: 2 };
	const v2: Vec2 = { x: 3, y: 4 };
	const v3 = addVec(v1, v2);
	assert v3.x == 4;
	assert v3.y == 6;
	assert dotVec(v1, v2) == 11;
}

test "nested interfaces (Pixel)" {
	const px: Pixel = {
		pos: { x: 10, y: 20 },
		color: { r: 255, g: 128, b: 0 },
	};
	assert px.pos.x == 10;
	assert px.pos.y == 20;
	assert px.color.r == 255;
	assert px.color.b == 0;
}

test "nested interfaces (Rect)" {
	const r: Rect = { topLeft: { x: 0, y: 0 }, width: 5, height: 3 };
	assert rectArea(r) == 15;
	assert r.topLeft.x == 0;
}

interface Counter { count: number; label: string; }

function inc(c: Counter): void { c.count += 1; }
function reset(c: Counter): void { c.count = 0; }

test "interface mutation" {
	const ctr: Counter = { count: 0, label: "ops" };
	inc(ctr);
	inc(ctr);
	inc(ctr);
	assert ctr.count == 3;
	assert ctr.label == "ops";
	reset(ctr);
	assert ctr.count == 0;
}

interface IntStack { data: number[]; }

function stackPush(s: IntStack, val: number): void { s.data.push(val); }
function stackPop(s: IntStack): number {
	if (s.data.length == 0) return -1;
	const val = s.data[s.data.length - 1];
	s.data.pop();
	return val;
}

test "interface with array field (stack)" {
	const stack: IntStack = { data: [] };
	stackPush(stack, 10);
	stackPush(stack, 20);
	stackPush(stack, 30);
	assert stack.data.length == 3;
	assert stackPop(stack) == 30;
	assert stackPop(stack) == 20;
	assert stack.data.length == 1;
}

test "interface as return type (Range)" {
	const r: Range = { start: 5, end: 15 };
	assert rangeLen(r) == 10;
	assert rangeContains(r, 5);
	assert rangeContains(r, 14);
	assert !rangeContains(r, 15);
	assert !rangeContains(r, 4);
}

test "array of interfaces (Table)" {
	const tbl: Table = { entries: [] };
	tableSet(tbl, "x", 10);
	tableSet(tbl, "y", 20);
	tableSet(tbl, "z", 30);
	assert tableGet(tbl, "x") == 10;
	assert tableGet(tbl, "z") == 30;
	assert tableGet(tbl, "missing") == -1;
	tableSet(tbl, "x", 99);
	assert tableGet(tbl, "x") == 99;
	assert tbl.entries.length == 3;
}

function isDevMode(cfg: Config): boolean { return cfg.debug && cfg.verbose; }

test "boolean fields" {
	const dev: Config = { debug: true, verbose: true, maxRetries: 3 };
	const prod: Config = { debug: false, verbose: false, maxRetries: 10 };
	assert isDevMode(dev);
	assert !isDevMode(prod);
	assert dev.maxRetries == 3;
	assert prod.maxRetries == 10;
}

test "builder pattern (SQL)" {
	const q: QueryBuilder = { table: "users", conditions: [], limit: 0 };
	q.conditions.push("age > 18");
	q.conditions.push("active = true");
	q.limit = 10;
	assert buildQuery(q) == "SELECT * FROM users WHERE age > 18 AND active = true LIMIT 10";
}

interface SpXY { x: int32; y: int32; }
interface SpXYZ { x: int32; y: int32; z: int32; }
let spLog = "";
function spOne(): int32 { spLog = spLog + "o"; return 9; }
function spPoint(): SpXY { spLog = spLog + "P"; return { x: 1, y: 2 }; }
function spSum(p: SpXYZ): int32 { return p.x * 100 + p.y * 10 + p.z; }

test "an object spread runs after the properties before it" {
	spLog = "";
	const n = spSum({ z: spOne(), ...spPoint() });
	assert spLog == "oP";
	assert n == 129;
}

test "an object spread in an untaken branch never runs" {
	spLog = "";
	const flag = spLog.length > 0;
	const q: SpXY = flag ? { ...spPoint(), y: 5 } : { x: 0, y: 0 };
	assert spLog == "";
	assert q.x == 0;
}

test "the fields an object spread provides keep their values" {
	const q: SpXYZ = { z: 3, ...spPoint() };
	assert q.x == 1;
	assert q.y == 2;
	assert q.z == 3;
}
