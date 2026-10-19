import { Rng, seeded } from "./rng";
import { Features, Mod, defaults, overlay } from "./features";
import { CORE_OFF, Parts, byteDigest, countOf, generate, generateParts } from "./gen";

export struct File {
	name: string;
	text: string;
}

const IMPLICIT_FNS: string[] = ["onDestroy", "onCopy", "onMove", "onMoved", "onTrace", "onClone", "getDynamicField", "setDynamicField", "toString", "valueOf", "toItems"];
const UNIT_KINDS: string[] = ["function", "struct", "class", "enum", "interface", "type", "actor", "macro", "converter", "let", "const"];
const TYPE_KINDS: string[] = ["struct", "class", "enum", "interface", "type", "actor"];
const MODIFIERS: string[] = ["async", "abstract", "declare", "extern", "export"];
const MODULE_LIMIT: int32 = 8;

struct Tok {
	text: string;
	start: int32;
	end: int32;
	member: boolean;
	write: boolean;
}

function codeAt(text: string, i: int32): int32 {
	if (i < 0 || i >= text.byteLength) { return 0; }
	return text.byteAt(i);
}

function isSpaceCode(c: int32): boolean { return c == 32 || c == 9 || c == 10 || c == 13; }
function isIdentStart(c: int32): boolean { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36; }
function isIdentPart(c: int32): boolean { return isIdentStart(c) || (c >= 48 && c <= 57); }

function skipSpaceForward(text: string, from: int32): int32 {
	let i = from;
	while (i < text.byteLength && isSpaceCode(codeAt(text, i))) { i++; }
	return i;
}

function skipSpaceBack(text: string, from: int32): int32 {
	let i = from;
	while (i >= 0 && isSpaceCode(codeAt(text, i))) { i--; }
	return i;
}

function wordEndingAt(text: string, last: int32): string {
	let i = last;
	while (i >= 0 && isIdentPart(codeAt(text, i))) { i--; }
	return text.byteSlice(i + 1, last + 1);
}

function writesAfter(text: string, end: int32): boolean {
	const j = skipSpaceForward(text, end);
	const c1 = codeAt(text, j);
	const c2 = codeAt(text, j + 1);
	const c3 = codeAt(text, j + 2);
	if (c1 == 61) { return c2 != 61 && c2 != 62; }
	if (c1 == 43 || c1 == 45 || c1 == 42 || c1 == 47 || c1 == 37 || c1 == 38 || c1 == 124 || c1 == 94) {
		if (c2 == 61) { return true; }
		if ((c1 == 43 || c1 == 45) && c2 == c1) { return true; }
		if ((c1 == 38 || c1 == 124 || c1 == 42) && c2 == c1 && c3 == 61) { return true; }
	}
	if (c1 == 60 && c2 == 60 && c3 == 61) { return true; }
	if (c1 == 62 && c2 == 62 && (c3 == 61 || (c3 == 62 && codeAt(text, j + 3) == 61))) { return true; }
	return c1 == 63 && c2 == 63 && c3 == 61;
}

function writesBefore(text: string, start: int32): boolean {
	const k = skipSpaceBack(text, start - 1);
	if (k >= 1 && (codeAt(text, k) == 43 || codeAt(text, k) == 45) && codeAt(text, k - 1) == codeAt(text, k)) { return true; }
	const word = wordEndingAt(text, k);
	return word == "ref" || word == "out";
}

class Scanner {
	text: string = "";
	pos: int32 = 0;
	toks: Tok[] = [];
	error: string = "";

	quoted(): void {
		const quote = codeAt(this.text, this.pos);
		const opened = this.pos;
		this.pos++;
		while (this.pos < this.text.byteLength) {
			const c = codeAt(this.text, this.pos);
			if (c == 92) { this.pos += 2; continue; }
			this.pos++;
			if (c == quote) { return; }
		}
		this.error = "a string opened at " + String(opened) + " is never closed";
	}

	template(): void {
		const opened = this.pos;
		this.pos++;
		while (this.pos < this.text.byteLength && this.error == "") {
			const c = codeAt(this.text, this.pos);
			if (c == 92) { this.pos += 2; continue; }
			if (c == 96) {
				this.pos++;
				return;
			}
			if (c == 36 && codeAt(this.text, this.pos + 1) == 123) {
				this.pos += 2;
				this.code(true);
				continue;
			}
			this.pos++;
		}
		if (this.error == "") { this.error = "a template literal opened at " + String(opened) + " is never closed"; }
	}

	code(inExpr: boolean): void {
		let depth = 0;
		while (this.pos < this.text.byteLength && this.error == "") {
			const c = codeAt(this.text, this.pos);
			if (c == 34 || c == 39) {
				this.quoted();
			} else if (c == 96) {
				this.template();
			} else if (c == 47 && codeAt(this.text, this.pos + 1) == 47) {
				while (this.pos < this.text.byteLength && codeAt(this.text, this.pos) != 10) { this.pos++; }
			} else if (c == 47 && codeAt(this.text, this.pos + 1) == 42) {
				this.pos += 2;
				while (this.pos < this.text.byteLength && !(codeAt(this.text, this.pos) == 42 && codeAt(this.text, this.pos + 1) == 47)) { this.pos++; }
				this.pos += 2;
			} else if (c == 123) {
				depth++;
				this.pos++;
			} else if (c == 125) {
				this.pos++;
				if (inExpr && depth == 0) { return; }
				depth--;
			} else if (isIdentStart(c)) {
				const start = this.pos;
				while (this.pos < this.text.byteLength && isIdentPart(codeAt(this.text, this.pos))) { this.pos++; }
				const before = skipSpaceBack(this.text, start - 1);
				const member = codeAt(this.text, before) == 46 && codeAt(this.text, before - 1) != 46;
				this.toks.push({
					text: this.text.byteSlice(start, this.pos),
					start: start,
					end: this.pos,
					member: member,
					write: !member && (writesAfter(this.text, this.pos) || writesBefore(this.text, start)),
				});
			} else if (c >= 48 && c <= 57) {
				while (this.pos < this.text.byteLength && isIdentPart(codeAt(this.text, this.pos))) { this.pos++; }
			} else {
				this.pos++;
			}
		}
		if (inExpr && this.error == "") { this.error = "a template expression is never closed"; }
	}
}

function scanTokens(text: string): Result<Tok[], string> {
	const s = new Scanner();
	s.text = text;
	s.code(false);
	if (s.error != "") { return Result.err(s.error); }
	return Result.ok(s.toks);
}

function rewrite(text: string, toks: Tok[], from: string[], to: string[]): string {
	let out = "";
	let at = 0;
	for (const t of toks) {
		if (t.member) { continue; }
		const k = from.indexOf(t.text);
		if (k < 0) { continue; }
		out += text.byteSlice(at, t.start) + to[k];
		at = t.end;
	}
	return out + text.byteSlice(at, text.byteLength);
}

class Unit {
	kind: string = "";
	name: string = "";
	pre: string = "";
	text: string = "";
	glue: boolean = false;
	fragile: boolean = false;
	ext: boolean = false;
	lent: boolean = false;
	preToks: Tok[] = [];
	deps: int32[] = [];
	writes: int32[] = [];
	toks: Tok[] = [];
	module: int32 = -1;
	shown: boolean = false;
}

function hasRest(u: Unit): boolean { return u.kind == "function" && u.text.split("\n")[0].contains("..."); }

function instantiatesItself(u: Unit): boolean { return u.kind == "class" && u.text.contains("new " + u.name + "<"); }

function hasDefault(u: Unit): boolean {
	const line = u.text.split("\n")[0];
	if (u.kind != "function") { return false; }
	let depth = 0;
	let from = -1;
	for (let i = 0; i < line.byteLength; i++) {
		const c = codeAt(line, i);
		if (c == 40) {
			if (depth == 0) { from = i; }
			depth++;
		}
		if (c == 41) {
			depth--;
			if (depth == 0) { return line.byteSlice(from, i).contains(" = "); }
		}
	}
	return false;
}

function loadsFirst(u: Unit): boolean { return hasRest(u) || instantiatesItself(u); }

function identAfter(line: string, from: int32): string {
	let i = skipSpaceForward(line, from);
	const start = i;
	while (i < line.byteLength && isIdentPart(codeAt(line, i))) { i++; }
	return line.byteSlice(start, i);
}

function skipDecorators(line: string): int32 {
	let i = 0;
	while (codeAt(line, i) == 64) {
		i++;
		while (isIdentPart(codeAt(line, i))) { i++; }
		if (codeAt(line, i) == 40) {
			let depth = 0;
			while (i < line.byteLength) {
				const c = codeAt(line, i);
				i++;
				if (c == 40) { depth++; }
				if (c == 41) {
					depth--;
					if (depth == 0) { break; }
				}
			}
		}
		i = skipSpaceForward(line, i);
	}
	return i;
}

function unitHead(line: string): Result<Unit, string> {
	const u = new Unit();
	let at = skipDecorators(line);
	let kind = "";
	while (kind == "") {
		const word = identAfter(line, at);
		if (word == "") { return Result.err("project mode does not understand the declaration '" + line.slice(0, 60) + "'"); }
		at = skipSpaceForward(line, at) + word.byteLength;
		if (!MODIFIERS.includes(word)) { kind = word; }
	}
	if (kind == "function" && codeAt(line, at) == 42) { at++; }
	if (!UNIT_KINDS.includes(kind)) { return Result.err("project mode does not understand the declaration '" + line.slice(0, 60) + "'"); }
	u.kind = kind;
	if (kind == "function" && codeAt(line, skipSpaceForward(line, at)) == 96) {
		const open = line.indexOf("`");
		u.name = line.slice(open, line.indexOf("`", open + 1) + 1);
		u.glue = true;
		return Result.ok(u);
	}
	u.name = identAfter(line, at);
	if (u.name == "") { return Result.err("project mode does not understand the declaration '" + line.slice(0, 60) + "'"); }
	u.glue = kind == "function" && IMPLICIT_FNS.includes(u.name);
	u.ext = kind == "function" && !u.glue && line.contains("(this ");
	return Result.ok(u);
}

function splitUnits(block: string): Result<Unit[], string> {
	const units: Unit[] = [];
	let pre = "";
	for (const line of block.split("\n")) {
		const first = codeAt(line, 0);
		if (line == "" || first == 9 || first == 125 || first == 32) {
			if (pre != "") { return Result.err("a decorator is followed by '" + line.slice(0, 60) + "' instead of a declaration"); }
			if (units.length == 0) {
				if (line == "") { continue; }
				return Result.err("a declaration block starts inside a body: '" + line.slice(0, 60) + "'");
			}
			units[units.length - 1].text += line + "\n";
			continue;
		}
		if (first == 64 && skipDecorators(line) >= line.byteLength) {
			pre += line + "\n";
			continue;
		}
		const u = try unitHead(line);
		u.pre = pre;
		pre = "";
		u.text = line + "\n";
		units.push(u);
	}
	if (pre != "") { return Result.err("a decorator ends the block without a declaration: '" + pre.trim() + "'"); }
	for (const u of units) { u.text = u.text.trimEnd() + "\n"; }
	return Result.ok(units);
}

class Dsu {
	parent: int32[] = [];

	grow(n: int32): void {
		this.parent = [];
		for (let i = 0; i < n; i++) { this.parent.push(i); }
	}

	find(x: int32): int32 {
		let r = x;
		while (this.parent[r] != r) { r = this.parent[r]; }
		let c = x;
		while (this.parent[c] != r) {
			const next = this.parent[c];
			this.parent[c] = r;
			c = next;
		}
		return r;
	}

	join(a: int32, b: int32): boolean {
		const ra = this.find(a);
		const rb = this.find(b);
		if (ra == rb) { return false; }
		if (ra < rb) { this.parent[rb] = ra; } else { this.parent[ra] = rb; }
		return true;
	}
}

class Tarjan {
	adj: int32[][] = [];
	index: int32[] = [];
	low: int32[] = [];
	onStack: boolean[] = [];
	stack: int32[] = [];
	comp: int32[] = [];
	counter: int32 = 0;
	count: int32 = 0;

	start(n: int32): void {
		this.adj = [];
		this.index = [];
		this.low = [];
		this.onStack = [];
		this.comp = [];
		for (let i = 0; i < n; i++) {
			this.adj.push([]);
			this.index.push(-1);
			this.low.push(0);
			this.onStack.push(false);
			this.comp.push(-1);
		}
	}

	visit(v: int32): void {
		this.index[v] = this.counter;
		this.low[v] = this.counter;
		this.counter++;
		this.stack.push(v);
		this.onStack[v] = true;
		for (const w of this.adj[v]) {
			if (this.index[w] < 0) {
				this.visit(w);
				if (this.low[w] < this.low[v]) { this.low[v] = this.low[w]; }
			} else if (this.onStack[w] && this.index[w] < this.low[v]) {
				this.low[v] = this.index[w];
			}
		}
		if (this.low[v] == this.index[v]) {
			while (true) {
				const w = this.stack.pop();
				this.onStack[w] = false;
				this.comp[w] = this.count;
				if (w == v) { break; }
			}
			this.count++;
		}
	}
}

class Re {
	before: string = "";
	after: string = "";
}

class Hub {
	module: int32 = 0;
	source: int32 = 0;
	star: boolean = false;
	entries: Re[] = [];
}

class Route {
	module: int32 = 0;
	name: string = "";
}

class Rewrite {
	imports: string = "";
	sources: int32[] = [];
	from: string[] = [];
	to: string[] = [];
}

export function moduleFileName(index: int32): string { return "m" + String(index) + ".ms"; }

export function isModuleFileName(name: string): boolean {
	if (name == "main.ms") { return true; }
	if (!name.startsWith("m") || !name.endsWith(".ms") || name.length < 5 || name.length > 6) { return false; }
	for (let i = 1; i < name.length - 3; i++) {
		const c = codeAt(name, i);
		if (c < 48 || c > 57) { return false; }
	}
	return true;
}

function shuffled(rng: Rng, n: int32): int32[] {
	const out: int32[] = [];
	for (let i = 0; i < n; i++) { out.push(i); }
	for (let i = n - 1; i > 0; i--) {
		const j = rng.below(i + 1);
		const t = out[i];
		out[i] = out[j];
		out[j] = t;
	}
	return out;
}

class StdImport {
	line: string = "";
	names: string[] = [];
}

class Splitter {
	headLine: string = "";
	directives: string[] = [];
	stdImports: StdImport[] = [];
	units: Unit[] = [];
	mainText: string = "";
	mainToks: Tok[] = [];
	mainDeps: int32[] = [];
	mainWrites: int32[] = [];
	idents: Set<string> = new Set<string>();
	fixed: Set<string> = new Set<string>();
	borrowers: Set<string> = new Set<string>();
	names: string[] = [];
	dsu: Dsu = new Dsu();
	rng: Rng = new Rng();
	shapes: BitSet<Mod> = 0 as BitSet<Mod>;
	modules: int32 = 0;

	unitIndex(name: string): int32 {
		for (let i = 0; i < this.names.length; i++) { if (this.names[i] == name) { return i; } }
		return -1;
	}

	mention(toks: Tok[], self: string, deps: int32[], writes: int32[]): void {
		for (const t of toks) {
			if (t.text == self) { continue; }
			const k = this.unitIndex(t.text);
			if (k < 0) { continue; }
			if (t.member && !this.units[k].ext) { continue; }
			if (!deps.includes(k)) { deps.push(k); }
			if (t.write && !writes.includes(k)) { writes.push(k); }
		}
	}

	lendGlobals(text: string, toks: Tok[], writes: int32[]): void {
		for (const t of toks) {
			if (t.member || !this.borrowers.has(t.text)) { continue; }
			let i = skipSpaceForward(text, t.end);
			if (codeAt(text, i) == 60) {
				let angle = 0;
				while (i < text.byteLength) {
					const c = codeAt(text, i);
					i++;
					if (c == 60) { angle++; }
					if (c == 62) {
						angle--;
						if (angle == 0) { break; }
					}
				}
				i = skipSpaceForward(text, i);
			}
			if (codeAt(text, i) != 40) { continue; }
			const open = i;
			let paren = 0;
			while (i < text.byteLength) {
				const c = codeAt(text, i);
				i++;
				if (c == 40) { paren++; }
				if (c == 41) {
					paren--;
					if (paren == 0) { break; }
				}
			}
			for (const a of toks) {
				if (a.start < open || a.end > i || a.member) { continue; }
				const k = this.unitIndex(a.text);
				if (k < 0 || this.units[k].kind != "let") { continue; }
				this.units[k].lent = true;
				if (!writes.includes(k)) { writes.push(k); }
			}
		}
	}

	readHead(head: string): Result<boolean, string> {
		const lines = head.trimEnd().split("\n");
		this.headLine = lines[0];
		for (let i = 1; i < lines.length; i++) {
			if (lines[i].startsWith("//")) {
				this.directives.push(lines[i]);
				continue;
			}
			if (!(try this.addImport(lines[i]))) { return Result.err("project mode does not understand the head line '" + lines[i] + "'"); }
		}
		return Result.ok(true);
	}

	addImport(line: string): Result<boolean, string> {
		const open = line.indexOf("{");
		const close = line.indexOf("}");
		if (!line.startsWith("import ") || open < 0 || close < open) { return Result.ok(false); }
		for (const known of this.stdImports) { if (known.line == line) { return Result.ok(true); } }
		const imp = new StdImport();
		imp.line = line;
		for (const n of line.slice(open + 1, close).split(",")) { imp.names.push(n.trim()); }
		this.stdImports.push(imp);
		return Result.ok(true);
	}

	withoutImports(block: string): Result<string, string> {
		let kept = "";
		for (const line of block.split("\n")) {
			if (line.startsWith("import ") && try this.addImport(line)) { continue; }
			kept += line + "\n";
		}
		return Result.ok(kept);
	}

	read(parts: Parts): Result<boolean, string> {
		try this.readHead(parts.head);
		for (const block of [parts.helpers, parts.globals, parts.fns]) {
			const found = try splitUnits(try this.withoutImports(block));
			for (const u of found) { this.units.push(u); }
		}
		this.mainText = parts.plant + parts.top + parts.tail;
		for (const u of this.units) {
			const toks = try scanTokens(u.text);
			u.toks = toks;
			u.preToks = try scanTokens(u.pre);
			this.names.push(u.glue ? "" : u.name);
			for (const t of toks) { this.idents.add(t.text); }
			for (const t of u.preToks) { this.idents.add(t.text); }
		}
		this.mainToks = try scanTokens(this.mainText);
		for (const t of this.mainToks) { this.idents.add(t.text); }
		for (const u of this.units) {
			if (u.kind == "function" && u.text.split("\n")[0].contains("Borrow<")) { this.borrowers.add(u.name); }
		}
		for (const u of this.units) {
			const self = u.glue ? "" : u.name;
			this.mention(u.toks, self, u.deps, u.writes);
			this.mention(u.preToks, self, u.deps, u.writes);
			this.lendGlobals(u.text, u.toks, u.writes);
		}
		this.mention(this.mainToks, "", this.mainDeps, this.mainWrites);
		this.lendGlobals(this.mainText, this.mainToks, this.mainWrites);
		for (let i = 0; i < this.units.length; i++) {
			if (this.units[i].kind != "converter") { continue; }
			this.fixed.add(this.units[i].name);
			for (let j = 0; j <= this.units.length; j++) {
				const deps = j == this.units.length ? this.mainDeps : this.units[j].deps;
				if (j != i && !deps.includes(i)) { deps.push(i); }
			}
		}
		this.inheritMacroDeps();
		this.markFragile();
		for (const u of this.units) {
			if (u.kind == "macro" || u.ext || hasDefault(u)) { this.fixed.add(u.name); }
		}
		for (let i = 0; i < this.units.length; i++) {
			const u = this.units[i];
			if (u.kind == "macro" || (u.pre + u.text).contains("@comptime")) { this.fixTransitive(u.deps); }
			if (u.kind != "macro" && !(u.pre + u.text.split("\n")[0]).contains("@comptime")) { continue; }
			for (const c of this.units) { if (c.deps.includes(i)) { this.fixTransitive(c.deps); } }
			if (this.mainDeps.includes(i)) { this.fixTransitive(this.mainDeps); }
		}
		if (this.mainText.contains("@comptime")) { this.fixTransitive(this.mainDeps); }
		for (const u of this.units) {
			if (u.kind != "class" && u.kind != "interface") { continue; }
			const line = u.text.split("\n")[0];
			if (u.kind == "class" && line.contains(u.name + "<")) { this.fixed.add(u.name); }
			for (const word of [" extends ", " implements "]) {
				const at = line.indexOf(word);
				if (at >= 0) { this.fixed.add(identAfter(line, at + word.length)); }
			}
		}
		return Result.ok(true);
	}

	fixTransitive(roots: int32[]): void {
		const todo = roots.slice(0, roots.length);
		const done: int32[] = [];
		while (todo.length > 0) {
			const d = todo.pop();
			if (done.includes(d)) { continue; }
			done.push(d);
			this.fixed.add(this.units[d].name);
			for (const e of this.units[d].deps) { todo.push(e); }
		}
	}

	inheritMacroDeps(): void {
		const n = this.units.length;
		let changed = true;
		while (changed) {
			changed = false;
			for (let i = 0; i <= n; i++) {
				const deps = i == n ? this.mainDeps : this.units[i].deps;
				const found = deps.slice(0, deps.length);
				for (const d of found) {
					if (this.units[d].kind != "macro") { continue; }
					for (const e of this.units[d].deps) {
						if (e != i && !deps.includes(e)) {
							deps.push(e);
							changed = true;
						}
					}
				}
			}
		}
	}

	kindOf(i: int32): string { return this.units[i].kind; }

	edgesInto(t: Tarjan): void {
		const n = this.units.length;
		for (let i = 0; i < n; i++) {
			for (const d of this.units[i].deps) {
				const a = this.dsu.find(i);
				const b = this.dsu.find(d);
				if (a != b && !t.adj[a].includes(b)) { t.adj[a].push(b); }
			}
		}
		for (const d of this.mainDeps) {
			const a = this.dsu.find(n);
			const b = this.dsu.find(d);
			if (a != b && !t.adj[a].includes(b)) { t.adj[a].push(b); }
		}
	}

	merge(): void {
		const n = this.units.length;
		this.dsu.grow(n + 1);
		for (let i = 0; i < n; i++) {
			const u = this.units[i];
			for (const d of u.deps) {
				if ((u.glue || u.ext || u.kind == "converter") && TYPE_KINDS.includes(this.kindOf(d))) { this.dsu.join(i, d); }
			}
			for (const w of u.writes) { this.dsu.join(i, w); }
			for (const d of u.deps) {
				if (this.units[d].lent) { this.dsu.join(i, d); }
			}
			if (this.names[i] != "") { this.dsu.join(i, this.unitIndex(this.names[i])); }
		}
		for (const w of this.mainWrites) { this.dsu.join(n, w); }
		for (const d of this.mainDeps) {
			if (this.units[d].lent) { this.dsu.join(n, d); }
		}
		let changed = true;
		while (changed) {
			changed = false;
			for (let i = 0; i < n; i++) {
				for (const d of this.units[i].deps) {
					if (this.dsu.find(d) == this.dsu.find(n) && this.dsu.find(i) != this.dsu.find(n)) {
						this.dsu.join(i, n);
						changed = true;
					}
				}
			}
			const t = new Tarjan();
			t.start(n + 1);
			this.edgesInto(t);
			for (let i = 0; i <= n; i++) {
				if (this.dsu.find(i) == i && t.index[i] < 0) { t.visit(i); }
			}
			const first: int32[] = [];
			for (let c = 0; c < t.count; c++) { first.push(-1); }
			for (let i = 0; i <= n; i++) {
				if (this.dsu.find(i) != i) { continue; }
				const c = t.comp[i];
				if (first[c] < 0) {
					first[c] = i;
				} else {
					this.dsu.join(first[c], i);
					changed = true;
				}
			}
		}
	}

	count: int32 = 0;
	hubs: Hub[] = [];
	cyclic: boolean = false;
	routeKeys: string[] = [];
	routeVals: Route[] = [];
	selectHost: int32 = -1;
	selectDecl: string = "";
	selectImport: string = "";
	selectUse: string = "";

	assign(): Result<boolean, string> {
		const n = this.units.length;
		const mainRoot = this.dsu.find(n);
		const deps: int32[][] = [];
		const dependents: int32[][] = [];
		for (let i = 0; i <= n; i++) {
			deps.push([]);
			dependents.push([]);
		}
		for (let i = 0; i < n; i++) {
			const a = this.dsu.find(i);
			if (a == mainRoot) { continue; }
			for (const d of this.units[i].deps) {
				const b = this.dsu.find(d);
				if (b == mainRoot) { return Result.err(this.units[i].name + " depends on a declaration only the entry module can own"); }
				if (b != a && !deps[a].includes(b)) {
					deps[a].push(b);
					dependents[b].push(a);
				}
			}
		}
		const left: int32[] = [];
		const ready: int32[] = [];
		let total = 0;
		for (let i = 0; i <= n; i++) {
			left.push(deps[i].length);
			if (this.dsu.find(i) == i && i != mainRoot) {
				total++;
				if (deps[i].length == 0) { ready.push(i); }
			}
		}
		const pinned: boolean[] = [];
		for (let i = 0; i <= n; i++) { pinned.push(false); }
		const pending: int32[] = [];
		for (let i = 0; i < n; i++) {
			if (loadsFirst(this.units[i]) && !pinned[this.dsu.find(i)]) {
				pinned[this.dsu.find(i)] = true;
				pending.push(this.dsu.find(i));
			}
		}
		while (pending.length > 0) {
			const r = pending.pop();
			for (const d of deps[r]) {
				if (!pinned[d]) {
					pinned[d] = true;
					pending.push(d);
				}
			}
		}
		const order: int32[] = [];
		while (ready.length > 0) {
			let pick = this.rng.below(ready.length);
			for (let i = 0; i < ready.length; i++) { if (pinned[ready[i]]) { pick = i; break; } }
			const r = ready[pick];
			ready[pick] = ready[ready.length - 1];
			ready.pop();
			order.push(r);
			for (const q of dependents[r]) {
				left[q]--;
				if (left[q] == 0) { ready.push(q); }
			}
		}
		if (order.length != total) { return Result.err("the declarations of the program depend on each other in a cycle the splitter could not merge"); }
		let lead = 0;
		while (lead < order.length && pinned[order[lead]]) { lead++; }
		const first = lead > 1 ? lead : 1;
		const room = total - first;
		const k = this.modules < room + 1 ? this.modules : room + 1;
		const cuts: int32[] = [];
		if (k > 1) {
			const slots = shuffled(this.rng, room);
			for (let c = 0; c < k - 1; c++) { cuts.push(first + slots[c]); }
			for (let a = 1; a < cuts.length; a++) {
				let b = a;
				while (b > 0 && cuts[b - 1] > cuts[b]) {
					const t = cuts[b];
					cuts[b] = cuts[b - 1];
					cuts[b - 1] = t;
					b--;
				}
			}
		}
		const moduleOf: int32[] = [];
		for (let i = 0; i <= n; i++) { moduleOf.push(-1); }
		for (let p = 0; p < order.length; p++) {
			let m = 0;
			for (const c of cuts) { if (c <= p) { m++; } }
			moduleOf[order[p]] = m;
		}
		this.count = k;
		if (k >= 2 && this.shapes.has(Mod.Cycle) && this.rng.chance(60)) { this.closeCycle(order, deps, moduleOf, k, pinned); }
		for (let i = 0; i < n; i++) {
			const r = this.dsu.find(i);
			this.units[i].module = r == mainRoot ? k : moduleOf[r];
		}
		return Result.ok(true);
	}

	markFragile(): void {
		for (const u of this.units) {
			const head = u.text.split("\n")[0];
			u.fragile = u.kind == "macro" || (u.pre + head).contains("@comptime") || u.text.contains("when (") || (u.kind == "class" && head.contains(" extends Error"));
		}
		let changed = true;
		while (changed) {
			changed = false;
			for (const u of this.units) {
				const head = u.text.split("\n")[0];
				const at = head.indexOf(" extends ");
				if (u.kind != "class" || u.fragile || at < 0) { continue; }
				const base = this.unitIndex(identAfter(head, at + 9));
				if (base >= 0 && this.units[base].fragile) {
					u.fragile = true;
					changed = true;
				}
			}
		}
	}

	fragileAcross(moduleOf: int32[], lo: int32, hi: int32): boolean {
		for (let i = 0; i < this.units.length; i++) {
			const mi = moduleOf[this.dsu.find(i)];
			if (mi < lo || mi > hi) { continue; }
			for (const d of this.units[i].deps) {
				const md = moduleOf[this.dsu.find(d)];
				if (this.units[d].fragile && md != mi && md >= lo && md <= hi) { return true; }
			}
		}
		return false;
	}

	holdsType(root: int32): boolean {
		for (let i = 0; i < this.units.length; i++) {
			if (this.dsu.find(i) == root && (this.kindOf(i) == "struct" || this.kindOf(i) == "class")) { return true; }
		}
		return false;
	}

	closeCycle(order: int32[], deps: int32[][], moduleOf: int32[], k: int32, pinned: boolean[]): void {
		const sizes: int32[] = [];
		for (let m = 0; m < k; m++) { sizes.push(0); }
		for (const r of order) { sizes[moduleOf[r]]++; }
		const perm = shuffled(this.rng, order.length);
		for (const pi of perm) {
			const x = order[pi];
			const a = moduleOf[x];
			if (a == k - 1 || sizes[a] < 2 || this.holdsType(x)) { continue; }
			let inside = false;
			for (const y of order) { if (y != x && moduleOf[y] == a && deps[y].includes(x)) { inside = true; } }
			if (!inside) { continue; }
			let b = -1;
			for (let m = a + 1; m < k && b < 0; m++) {
				for (const z of order) {
					if (moduleOf[z] != m) { continue; }
					for (const w of deps[z]) { if (w != x && moduleOf[w] == a) { b = m; } }
				}
			}
			if (b < 0) { continue; }
			let restInside = false;
			for (const r of order) { if (pinned[r] && moduleOf[r] >= a && moduleOf[r] <= b) { restInside = true; } }
			if (restInside) { continue; }
			moduleOf[x] = b;
			if (this.fragileAcross(moduleOf, a, b)) {
				moduleOf[x] = a;
				continue;
			}
			this.cyclic = true;
			return;
		}
	}

	fresh(base: string): string {
		let name = base;
		while (this.idents.has(name)) { name += "_"; }
		this.idents.add(name);
		return name;
	}

	route(owner: int32, name: string, consumer: int32): Route {
		const key = String(consumer) + ":" + name;
		const seen = this.routeKeys.indexOf(key);
		if (seen >= 0) { return this.routeVals[seen]; }
		const r = this.pick(owner, name, consumer);
		this.routeKeys.push(key);
		this.routeVals.push(r);
		return r;
	}

	pick(owner: int32, name: string, consumer: int32): Route {
		const hubbed = !this.cyclic && !this.fixed.has(name) && (this.shapes.has(Mod.Reexport) || this.shapes.has(Mod.Star));
		if (hubbed && consumer - owner > 1 && this.rng.chance(50)) {
			const hub = owner + 1 + this.rng.below(consumer - owner - 1);
			const via = this.reexport(hub, this.route(owner, name, hub));
			if (via.module >= 0) { return via; }
		}
		for (const u of this.units) { if (u.name == name && !u.glue) { u.shown = true; } }
		return { module: owner, name: name };
	}

	reexport(hub: int32, up: Route): Route {
		const own: Hub[] = [];
		let found: Hub | null = null;
		for (const x of this.hubs) {
			if (x.module != hub) { continue; }
			own.push(x);
			if (x.source == up.module) { found = x; }
		}
		if (found === null) {
			if (own.length > 0 && own[0].star) { return { module: -1, name: "" }; }
			const named = this.shapes.has(Mod.Reexport);
			const star = own.length == 0 && this.shapes.has(Mod.Star) && (!named || this.rng.chance(50));
			if (!star && !named) { return { module: -1, name: "" }; }
			found = new Hub();
			found.module = hub;
			found.source = up.module;
			found.star = star;
			this.hubs.push(found);
		}
		if (found.star) { return { module: hub, name: up.name }; }
		for (const e of found.entries) { if (e.before == up.name) { return { module: hub, name: e.after }; } }
		const after = this.shapes.has(Mod.Alias) && this.rng.chance(40) ? this.fresh(up.name + "_r") : up.name;
		found.entries.push({ before: up.name, after: after });
		return { module: hub, name: after };
	}

	addNeeds(out: int32[], deps: int32[], module: int32): void {
		for (const d of deps) {
			if (this.units[d].module == module) { continue; }
			let known = false;
			for (const o of out) { if (this.units[o].name == this.units[d].name) { known = true; } }
			if (!known) { out.push(d); }
		}
	}

	needs(module: int32): int32[] {
		const out: int32[] = [];
		const main = this.count;
		for (const u of this.units) {
			if (u.module != module) { continue; }
			this.addNeeds(out, u.deps, module);
		}
		if (module == main) { this.addNeeds(out, this.mainDeps, module); }
		return out;
	}

	consume(module: int32): Rewrite {
		const rw = new Rewrite();
		const needed = this.needs(module);
		const routes: Route[] = [];
		const sources: int32[] = [];
		for (const d of needed) {
			const r = this.route(this.units[d].module, this.units[d].name, module);
			routes.push(r);
			if (!sources.includes(r.module)) { sources.push(r.module); }
		}
		rw.sources = sources;
		for (const s of sources) {
			const file = "\"./m" + String(s) + "\"";
			let list = "";
			if (this.shapes.has(Mod.Namespace) && this.rng.chance(35)) {
				const space = this.fresh("ns" + String(s) + "x");
				for (let i = 0; i < needed.length; i++) {
					if (routes[i].module != s) { continue; }
					const name = this.units[needed[i]].name;
					if (this.fixed.has(name)) {
						list += (list == "" ? "" : ", ") + routes[i].name;
						continue;
					}
					rw.from.push(name);
					rw.to.push(space + "." + routes[i].name);
				}
				rw.imports += "import * as " + space + " from " + file + ";\n";
				if (list != "") { rw.imports += "import { " + list + " } from " + file + ";\n"; }
				continue;
			}
			for (let i = 0; i < needed.length; i++) {
				if (routes[i].module != s) { continue; }
				const name = this.units[needed[i]].name;
				const local = !this.fixed.has(name) && this.shapes.has(Mod.Alias) && this.rng.chance(35) ? this.fresh(name + "_a") : name;
				if (local != name) {
					rw.from.push(name);
					rw.to.push(local);
				}
				list += (list == "" ? "" : ", ") + (local == routes[i].name ? local : routes[i].name + " as " + local);
			}
			rw.imports += "import { " + list + " } from " + file + ";\n";
		}
		return rw;
	}

	hubLines(module: int32): string {
		let out = "";
		for (const h of this.hubs) {
			if (h.module != module) { continue; }
			const file = "\"./m" + String(h.source) + "\"";
			if (h.star) {
				out += "export * from " + file + ";\n";
				continue;
			}
			let list = "";
			for (const e of h.entries) { list += (list == "" ? "" : ", ") + (e.before == e.after ? e.before : e.before + " as " + e.after); }
			out += "export { " + list + " } from " + file + ";\n";
		}
		return out;
	}

	loadFirst(): string {
		if (!this.cyclic) { return ""; }
		for (const u of this.units) { if (loadsFirst(u)) { return "import \"./m0\";\n"; } }
		return "";
	}

	uses(m: int32, names: string[]): boolean {
		for (const u of this.units) {
			if (u.module != m) { continue; }
			for (const t of u.toks) { if (names.includes(t.text)) { return true; } }
			for (const t of u.preToks) { if (names.includes(t.text)) { return true; } }
		}
		if (m == this.count) { for (const t of this.mainToks) { if (names.includes(t.text)) { return true; } } }
		return false;
	}

	headText(m: int32): string {
		const main = m == this.count;
		let text = this.headLine + (main ? "" : " module=m" + String(m)) + "\n";
		if (main) { for (const d of this.directives) { text += d + "\n"; } }
		for (const imp of this.stdImports) { if (this.uses(m, imp.names)) { text += imp.line + "\n"; } }
		return text;
	}

	moduleText(m: int32, rw: Rewrite): string {
		const k = this.count;
		let text = this.headText(m);
		text += (m == k ? this.loadFirst() : "") + rw.imports + (m == k ? this.selectImport : "") + this.hubLines(m);
		if (m < k && this.shapes.has(Mod.Init)) { text += "console.log(\"init m" + String(m) + "\");\n"; }
		for (const u of this.units) {
			if (u.module == m) { text += u.pre + (u.shown || u.glue || u.ext || u.kind == "converter" ? "export " : "") + rewrite(u.text, u.toks, rw.from, rw.to); }
		}
		if (m == this.selectHost) { text += this.selectDecl; }
		return m == k ? text + rewrite(this.mainText, this.mainToks, rw.from, rw.to) + this.selectUse : text;
	}

	importGlueModules(rewrites: Rewrite[]): void {
		const k = this.count;
		const holdsGlue: boolean[] = [];
		const adj: int32[][] = [];
		for (let m = 0; m <= k; m++) {
			holdsGlue.push(false);
			adj.push(rewrites[m].sources.slice(0, rewrites[m].sources.length));
		}
		for (const u of this.units) { if (u.glue) { holdsGlue[u.module] = true; } }
		for (const h of this.hubs) { adj[h.module].push(h.source); }
		if (this.cyclic) { adj[k].push(0); }
		for (let m = 1; m <= k; m++) {
			const seen: int32[] = [];
			const todo = adj[m].slice(0, adj[m].length);
			while (todo.length > 0) {
				const x = todo.pop();
				if (seen.includes(x)) { continue; }
				seen.push(x);
				for (const y of adj[x]) { todo.push(y); }
			}
			for (let g = 0; g < m && g < k; g++) {
				if (holdsGlue[g] && seen.includes(g) && !rewrites[m].sources.includes(g)) { rewrites[m].imports += "import \"./m" + String(g) + "\";\n"; }
			}
		}
	}

	select(): void {
		if (!this.shapes.has(Mod.Select) || this.count < 1) { return; }
		this.selectHost = this.rng.below(this.count);
		const name = this.fresh("selPick");
		const form = this.rng.below(3);
		const spelled = [
			["a * 3 + b", "b + a * 3", "a + a + a + b"],
			["(a ^ b) + (a & b) * 2", "(a | b) + (a & b)", "a + b"],
			["a * b + a", "a * (b + 1)", "(b + 1) * a"],
		][this.rng.below(3)];
		const sig = "(a: int32, b: int32): int32";
		if (form == 0) {
			this.selectDecl = "when (js) {\n\texport function " + name + sig + " { return " + spelled[0] + "; }\n} else when (c) {\n\texport function " + name + sig + " { return " + spelled[1] + "; }\n} else {\n\texport function " + name + sig + " { return " + spelled[2] + "; }\n}\n";
		} else if (form == 1) {
			this.selectDecl = "export function " + name + sig + " {\n\twhen (js) { return " + spelled[0] + "; } else when (c) { return " + spelled[1] + "; } else { return " + spelled[2] + "; }\n}\n";
		} else {
			const base = this.fresh("selBase");
			this.selectDecl = "when (js) {\n\texport const " + base + ": int32 = 2 + 3;\n} else when (c) {\n\texport const " + base + ": int32 = 3 + 2;\n} else {\n\texport const " + base + ": int32 = 5;\n}\n" +
				"export function " + name + sig + " { return " + base + " * a + b; }\n";
		}
		const file = "\"./m" + String(this.selectHost) + "\"";
		let style = this.rng.below(3);
		if ((style == 1 && !this.shapes.has(Mod.Alias)) || (style == 2 && !this.shapes.has(Mod.Namespace))) { style = 0; }
		let callee = name;
		if (style == 0) {
			this.selectImport = "import { " + name + " } from " + file + ";\n";
		} else if (style == 1) {
			callee = this.fresh(name + "_s");
			this.selectImport = "import { " + name + " as " + callee + " } from " + file + ";\n";
		} else {
			const space = this.fresh("selNs");
			callee = space + "." + name;
			this.selectImport = "import * as " + space + " from " + file + ";\n";
		}
		this.selectUse = "console.log(\"sel \" + String(" + callee + "(" + String(this.rng.below(10)) + ", " + String(this.rng.below(10)) + ")));\n";
	}

	build(): File[] {
		const k = this.count;
		const rewrites: Rewrite[] = [];
		for (let m = 0; m <= k; m++) { rewrites.push(this.consume(m)); }
		this.importGlueModules(rewrites);
		this.select();
		const files: File[] = [{ name: "main.ms", text: this.moduleText(k, rewrites[k]) }];
		for (let m = 0; m < k; m++) { files.push({ name: moduleFileName(m), text: this.moduleText(m, rewrites[m]) }); }
		return files;
	}
}

export function generateProject(seed: uint64, f: Features): Result<File[], string> {
	const parts = generateParts(seed, f);
	if (f.modules == 0) {
		return Result.ok([{ name: "main.ms", text: parts.head + parts.helpers + parts.plant + parts.globals + parts.fns + parts.top + parts.tail }]);
	}
	if (f.modules > MODULE_LIMIT) { return Result.err("modules=" + String(f.modules) + " is above " + String(MODULE_LIMIT)); }
	const sp = new Splitter();
	sp.rng = Rng.seeded(seed ^ (0x4D4F44554C455300 as uint64));
	sp.shapes = f.shapes;
	sp.modules = f.modules;
	const read = sp.read(parts);
	if (!read.ok) { return Result.err(read.error); }
	sp.merge();
	const assigned = sp.assign();
	if (!assigned.ok) { return Result.err(assigned.error); }
	return Result.ok(sp.build());
}

function projectOf(seed: uint64, text: string): File[] {
	const f = Features.defaults().overlay(text);
	if (!f.ok) {
		console.log(text + ": " + f.error);
		return [];
	}
	const r = generateProject(seed, f.value);
	if (!r.ok) {
		console.log("seed " + String(seed) + " " + text + ": " + r.error);
		return [];
	}
	return r.value;
}

function importsOf(text: string): string[] {
	const out: string[] = [];
	for (const line of text.split("\n")) {
		const at = line.indexOf(" from \"./");
		if (at < 0 || !line.endsWith(";") || !(line.startsWith("import ") || line.startsWith("export "))) { continue; }
		const rest = line.slice(at + 9, line.length);
		out.push(rest.slice(0, rest.indexOf("\"")));
	}
	return out;
}

function unresolved(files: File[]): string {
	const names: string[] = [];
	for (const f of files) { names.push(f.name.slice(0, f.name.length - 3)); }
	for (const f of files) {
		for (const target of importsOf(f.text)) { if (!names.includes(target)) { return f.name + " imports " + target; } }
	}
	return "";
}

function cyclicModules(files: File[]): string[] {
	const names: string[] = [];
	for (const f of files) { names.push(f.name.slice(0, f.name.length - 3)); }
	const reach: boolean[][] = [];
	for (let i = 0; i < files.length; i++) {
		reach.push([]);
		for (let j = 0; j < files.length; j++) { reach[i].push(false); }
	}
	for (let i = 0; i < files.length; i++) {
		for (const target of importsOf(files[i].text)) {
			const j = names.indexOf(target);
			if (j >= 0) { reach[i][j] = true; }
		}
	}
	for (let k = 0; k < files.length; k++) {
		for (let i = 0; i < files.length; i++) {
			for (let j = 0; j < files.length; j++) { if (reach[i][k] && reach[k][j]) { reach[i][j] = true; } }
		}
	}
	const out: string[] = [];
	for (let i = 0; i < files.length; i++) { if (reach[i][i]) { out.push(names[i]); } }
	return out;
}

function declarations(text: string): int32 {
	let n = 0;
	for (const line of text.split("\n")) {
		const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
		for (const kind of UNIT_KINDS) { if (bare.startsWith(kind + " ")) { n++; } }
	}
	return n;
}

function selectDeclarations(files: File[]): int32 {
	let n = 0;
	for (const f of files) {
		for (const line of f.text.split("\n")) { if (line.startsWith("export function selPick")) { n++; } }
	}
	return n;
}

function joined(files: File[]): string {
	let all = "";
	for (const f of files) { all += f.text; }
	return all;
}

test "only main and the generated module names are file names a project may hold" {
	for (const ok of ["main.ms", "m0.ms", "m7.ms", "m12.ms"]) { assert isModuleFileName(ok); }
	for (const bad of ["", "m.ms", "m0.js", "m0.jms", "M0.ms", "m0x.ms", "mm.ms", "m123.ms", "a/m0.ms", "../m0.ms", "m0/x.ms", "main.js", "x.ms"]) { assert !isModuleFileName(bad); }
	assert moduleFileName(3) == "m3.ms";
}

test "the scanner skips strings, comments and template text and flags a write" {
	const text = "let a = \"g0 = 1\"; // g1 = 2\ng2 = 3; const t = `x${g3}y g4`; /* g5 */ g6 += 1; g7++; g12 **= 2; if (g8 == 1) { ++g9; } o.g10 = 1; f(g11 => g11);";
	const r = scanTokens(text);
	assert r.ok;
	if (r.ok) {
		let seen = "";
		let wrote = "";
		for (const t of r.value) {
			if (t.text.startsWith("g")) { seen += t.text + " "; }
			if (t.write) { wrote += t.text + " "; }
		}
		assert seen == "g2 g3 g6 g7 g12 g8 g9 g10 g11 g11 ";
		assert wrote == "a g2 t g6 g7 g12 g9 ";
	}
	assert !scanTokens("let a = \"open").ok;
}

test "a declaration the splitter does not know is an error that names it" {
	const r = splitUnits("namespace Colour { }\n");
	assert !r.ok;
	if (!r.ok) { assert r.error.contains("namespace Colour"); }
	assert !splitUnits("function (this typeof T).m() {}\n").ok;
}

test "modules=0 is the single-file program, byte for byte" {
	for (const text of ["", "funcs=2 globals=2", "types=int32 fams=closure,own", "plant=backend", "depth=2 stmts=2 entries=2"]) {
		for (let seed = 1; seed <= 12; seed++) {
			const f = Features.defaults().overlay(text);
			assert f.ok;
			if (!f.ok) { continue; }
			const files = projectOf(seed as uint64, text);
			assert files.length == 1 && files[0].name == "main.ms";
			assert files[0].text == generate(seed as uint64, f.value);
		}
	}
}

test "a split project is deterministic, holds every declaration once and imports only its own modules" {
	for (let modules = 2; modules <= 4; modules++) {
		for (let seed = 1; seed <= 10; seed++) {
			const text = "modules=" + String(modules);
			const files = projectOf(seed as uint64, text);
			const again = projectOf(seed as uint64, text);
			assert files.length > 0 && files.length == again.length;
			assert unresolved(files) == "";
			assert files[0].name == "main.ms";
			for (let i = 0; i < files.length; i++) {
				assert files[i].text == again[i].text && files[i].name == again[i].name;
				assert isModuleFileName(files[i].name);
				assert i == 0 || files[i].name == moduleFileName(i - 1);
			}
			assert files.length >= 2 && files.length <= modules + 1;
			assert declarations(joined(files)) - selectDeclarations(files) == declarations(projectOf(seed as uint64, "modules=0")[0].text);
			assert cyclicModules(files).length < files.length;
		}
	}
}

test "every module shape appears and modshapes=none keeps all of them out" {
	let named = false;
	let alias = false;
	let space = false;
	let star = false;
	let init = false;
	let cycle = false;
	for (let seed = 1; seed <= 60; seed++) {
		const files = projectOf(seed as uint64, "modules=4");
		assert files.length > 0;
		for (const f of files) {
			for (const line of f.text.split("\n")) {
				if (line.startsWith("export {") && line.contains(" from \"./")) { named = true; }
				if (line.startsWith("import {") && line.contains(" as ")) { alias = true; }
				if (line.startsWith("import * as ")) { space = true; }
				if (line.startsWith("export * from ")) { star = true; }
				if (line.startsWith("console.log(\"init m")) { init = true; }
			}
		}
		if (cyclicModules(files).length > 0) { cycle = true; }
		const plain = projectOf(seed as uint64, "modules=4 modshapes=none");
		assert plain.length > 0;
		for (const f of plain) {
			assert !f.text.contains("\nexport {") && !f.text.contains("\nexport * ") && !f.text.contains("\nimport * ") && !f.text.contains("init m");
			for (const line of f.text.split("\n")) { assert !(line.startsWith("import {") && line.contains(" as ")); }
		}
		assert cyclicModules(plain).length == 0;
	}
	assert named && alias && space && star && init && cycle;
}

function restFunctions(files: File[]): string[] {
	const out: string[] = [];
	for (const f of files) {
		for (const line of f.text.split("\n")) {
			const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
			if (!bare.startsWith("function ") || !line.contains("...")) { continue; }
			out.push(f.name.slice(0, f.name.length - 3) + ":" + bare.slice(9, bare.indexOf("(")));
		}
	}
	return out;
}

function selfInstancing(files: File[]): string[] {
	const out: string[] = [];
	for (const f of files) {
		let name = "";
		for (const line of f.text.split("\n")) {
			const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
			if (bare.startsWith("class ") && bare.contains("<")) { name = bare.slice(6, bare.indexOf("<")); }
			if (line.startsWith("}")) { name = ""; }
			if (name != "" && line.contains("new " + name + "<")) { out.push(f.name.slice(0, f.name.length - 3) + ":" + name); name = ""; }
		}
	}
	return out;
}

test "a rest function and a class that instantiates itself sit in the first module or in main, and main loads the first module before any import cycle can close" {
	let cycles = 0;
	let rests = 0;
	let selfs = 0;
	for (let seed = 1; seed <= 60; seed++) {
		for (const shapes of ["modshapes=cycle", "modshapes=reexport,star,ns,alias,cycle"]) {
			const files = projectOf(seed as uint64, "modules=4 " + shapes);
			assert files.length > 0;
			const cyclic = cyclicModules(files);
			const rest = restFunctions(files);
			rests += rest.length;
			const selves = selfInstancing(files);
			selfs += selves.length;
			for (const r of rest) { assert r.startsWith("m0:") || r.startsWith("main:"); }
			for (const r of selves) { assert r.startsWith("m0:") || r.startsWith("main:"); }
			if (cyclic.length == 0) { continue; }
			cycles++;
			assert !cyclic.includes("m0");
			if (rest.length + selves.length > 0) { assert files[0].name == "main.ms" && files[0].text.contains("\nimport \"./m0\";\n"); }
		}
	}
	assert cycles > 0 && rests > 0 && selfs > 0;
}

function projectDigest(files: File[]): int64 {
	let h = 0 as int64;
	for (const f of files) {
		h = (h * (131 as int64) + byteDigest(f.name + "\n" + f.text.slice(f.text.indexOf("\n") + 1, f.text.length) + "\n")) % (1000000007 as int64);
	}
	return h;
}

test "a project module selects its code by backend with when, whose three branches compute one value" {
	let declared = 0;
	let inBody = 0;
	let constant = 0;
	let named = 0;
	let aliased = 0;
	let spaced = 0;
	for (let seed = 1; seed <= 40; seed++) {
		const files = projectOf(seed as uint64, "modules=3 fams=closure");
		assert files.length > 0 && unresolved(files) == "";
		const all = joined(files);
		assert countOf(all, "console.log(\"sel \" + String(") == 1 && countOf(all, "export function selPick") >= 1;
		assert files[0].text.endsWith(");\n") && files[0].text.contains("console.log(\"sel \" + String(");
		for (const f of files) {
			assert f.name == "main.ms" || !f.text.contains("console.log(\"sel ");
			if (f.text.contains("\nwhen (js) {\n\texport function selPick")) {
				declared++;
				assert f.text.contains("} else when (c) {\n\texport function selPick") && f.text.contains("} else {\n\texport function selPick");
			}
			if (f.text.contains("\texport function selPick") == false && f.text.contains("\twhen (js) { return ")) {
				inBody++;
				assert f.text.contains("; } else when (c) { return ") && f.text.contains("; } else { return ");
			}
			if (f.text.contains("export const selBase: int32 = 2 + 3;")) {
				constant++;
				assert f.text.contains("export const selBase: int32 = 3 + 2;") && f.text.contains("export const selBase: int32 = 5;");
			}
		}
		const main = files[0].text;
		if (main.contains("import { selPick } from \"./m")) { named++; }
		if (main.contains("import { selPick as selPick_s } from \"./m")) { aliased++; }
		if (main.contains("import * as selNs from \"./m") && main.contains("selNs.selPick(")) { spaced++; }
	}
	assert declared > 3 && inBody > 3 && constant > 3 && named > 3 && aliased > 3 && spaced > 3;
}

test "the select shape imports by name only when the alias and namespace shapes are off, and modshapes=none keeps it out" {
	for (let seed = 1; seed <= 30; seed++) {
		const only = joined(projectOf(seed as uint64, "modules=3 modshapes=select"));
		assert only.contains("selPick") && !only.contains("selPick_s") && !only.contains("selNs");
		const none = joined(projectOf(seed as uint64, "modules=3 modshapes=none"));
		assert !none.contains("selPick") && !none.contains("when (js)") && !none.contains("\"sel ");
	}
}

test "module shapes other than select keep the stream of the splitter without it" {
	const off = "alias,ns,reexport,star,cycle,init";
	const cases = ["modules=4 fams=closure,agg " + CORE_OFF + " modshapes=" + off, "modules=3 fams=none w.core.optional=0 w.core.void=0 w.core.alias=0 w.core.ushr=0 modshapes=ns,star"];
	const pins: int64[] = [341073509, 235616312, 916984209, 372824637, 799339767, 1749349, 784271022, 766585468, 390463679];
	const seeds: uint64[] = [1, 2, 3, 4, 5, 6, 1, 2, 3];
	for (let i = 0; i < seeds.length; i++) { assert projectDigest(projectOf(seeds[i], cases[i < 6 ? 0 : 1])) == pins[i]; }
}

test "an import cycle is closed by a function or a global, never by a struct or a class" {
	let upward = 0;
	for (let seed = 1; seed <= 60; seed++) {
		const files = projectOf(seed as uint64, "modules=4 modshapes=cycle");
		assert files.length > 0;
		const types: string[] = [];
		for (const f of files) {
			for (const line of f.text.split("\n")) {
				const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
				if (bare.startsWith("struct ") || bare.startsWith("class ")) {
					const rest = bare.slice(bare.indexOf(" ") + 1, bare.length);
					types.push(rest.slice(0, rest.indexOf(" ")).split("<")[0]);
				}
			}
		}
		for (const f of files) {
			if (f.name == "main.ms") { continue; }
			const me = f.name.slice(1, f.name.length - 3).parseInt();
			for (const line of f.text.split("\n")) {
				if (!line.startsWith("import {") || !line.contains(" from \"./m")) { continue; }
				const at = line.indexOf(" from \"./m");
				if (line.slice(at + 10, line.length - 2).parseInt() <= me) { continue; }
				upward++;
				for (const entry of line.slice(line.indexOf("{") + 1, line.indexOf("}")).split(",")) { assert !types.includes(entry.trim()); }
			}
		}
	}
	assert upward > 0;
}

test "a re-export hub never sits in a project with an import cycle" {
	let hubs = 0;
	let cycles = 0;
	for (let seed = 1; seed <= 80; seed++) {
		const files = projectOf(seed as uint64, "modules=4");
		assert files.length > 0;
		const cyclic = cyclicModules(files).length > 0;
		if (cyclic) { cycles++; }
		for (const f of files) {
			for (const line of f.text.split("\n")) {
				if (line.startsWith("export * from ") || (line.startsWith("export {") && line.contains(" from \"./"))) {
					hubs++;
					assert !cyclic;
				}
			}
		}
	}
	assert hubs > 0 && cycles > 0;
}

function isGlobalName(name: string): boolean {
	if (name == "ownHooks") { return true; }
	if (name.length < 2 || codeAt(name, 0) != 103) { return false; }
	for (let i = 1; i < name.length; i++) {
		const c = codeAt(name, i);
		if (c < 48 || c > 57) { return false; }
	}
	return true;
}

test "a global that a file assigns is declared in that file, because an import binding is read-only in TypeScript" {
	let assigned = 0;
	for (let seed = 1; seed <= 30; seed++) {
		const files = projectOf(seed as uint64, "modules=4");
		assert files.length > 0;
		for (const f of files) {
			const toks = scanTokens(f.text);
			assert toks.ok;
			if (!toks.ok) { continue; }
			for (const t of toks.value) {
				if (!t.write || t.member || !isGlobalName(t.text)) { continue; }
				assigned++;
				assert f.text.contains("let " + t.text + ":");
			}
		}
	}
	assert assigned > 0;
}

const FAMILY_VECTORS: string[] = ["", "fams=closure", "fams=union", "fams=generic", "fams=agg", "fams=coll", "fams=str", "fams=own", "fams=iter", "fams=seq", "fams=gcls", "fams=enum", "fams=exc", "fams=cls", "fams=conv", "fams=meta", "fams=native", "fams=spawn", "fams=actor", "fams=race", "fams=async"];

test "a project splits over the default family vector and over each family alone, for 20 seeds" {
	for (const vector of FAMILY_VECTORS) {
		for (let seed = 1; seed <= 20; seed++) {
			const files = projectOf(seed as uint64, vector + " modules=" + String(2 + seed % 4));
			assert files.length >= 2;
			assert unresolved(files) == "";
		}
	}
}

test "the splitter reads decorators, modifiers, generators, operators and implicit functions as declarations" {
	const block = "@metaDescribe\nclass A {\n\tx: int32 = 1;\n}\n@comptime function f(a: int32): int32 { return a; }\nabstract class B { }\nfunction* g(): Iterator<int32> {\n\tyield 1;\n}\nfunction `+`(this a: A, b: A): A { return a; }\nfunction toString(this a: A): string { return \"\"; }\nfunction twice(this a: A): int32 { return 2; }\nconverter cv(a: A): int32 { return 1; }\nmacro m(n: Node): Node { return n; }\nactor Act { }\ninterface I { }\ntype T = A;\nenum E { P }\n";
	const r = splitUnits(block);
	assert r.ok;
	if (!r.ok) { return; }
	const kinds = ["class", "function", "class", "function", "function", "function", "function", "converter", "macro", "actor", "interface", "type", "enum"];
	assert r.value.length == kinds.length;
	for (let i = 0; i < kinds.length && i < r.value.length; i++) { assert r.value[i].kind == kinds[i]; }
	assert r.value[0].pre == "@metaDescribe\n" && r.value[0].name == "A";
	assert r.value[4].glue && r.value[4].name == "`+`";
	assert r.value[5].glue && !r.value[5].ext;
	assert r.value[6].ext && !r.value[6].glue;
	assert !splitUnits("@metaDescribe\n").ok;
	assert !splitUnits("@a\n\tx\n").ok;
}

test "an operator, an implicit function and a converter are exported, and a macro or a comptime function is never renamed on import" {
	let exported = 0;
	for (const vector of ["fams=conv", "fams=own", "fams=meta", "fams=seq"]) {
		for (let seed = 1; seed <= 20; seed++) {
			const files = projectOf(seed as uint64, vector + " modules=4 modshapes=alias,ns");
			assert files.length > 0;
			for (const f of files) {
				for (const line of f.text.split("\n")) {
					for (const head of ["function `", "function onDestroy(", "function onCopy(", "function toString(this ", "function toItems(this ", "converter "]) {
						assert !line.startsWith(head);
						if (line.startsWith("export " + head)) { exported++; }
					}
					if (!line.startsWith("import {")) { continue; }
					for (const name of importedNames(line)) {
						assert !(name.startsWith("metaFn") && name.contains(" as ")) && !(name.startsWith("cvConv") && name.contains(" as "));
					}
				}
			}
		}
	}
	assert exported > 0;
}

function importedNames(line: string): string[] {
	const open = line.indexOf("{");
	const close = line.indexOf("}");
	const out: string[] = [];
	if (open < 0 || close < open) { return out; }
	for (const n of line.slice(open + 1, close).split(",")) { out.push(n.trim()); }
	return out;
}

function fragileNames(files: File[]): string[] {
	const out: string[] = [];
	for (const f of files) {
		for (const line of f.text.split("\n")) {
			const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
			if (bare.startsWith("@comptime function ")) { out.push(bare.slice(19, bare.indexOf("("))); }
			if (bare.startsWith("class ") && bare.contains(" extends Error {")) { out.push(bare.slice(6, bare.indexOf(" "))); }
		}
	}
	return out;
}

test "an import cycle never carries an Error subclass or a comptime function between its modules" {
	let cycles = 0;
	let fragile = 0;
	for (let seed = 1; seed <= 60; seed++) {
		const files = projectOf(seed as uint64, "fams=exc,meta modules=4 modshapes=cycle");
		assert files.length > 0;
		const names = fragileNames(files);
		fragile += names.length;
		const cyclic = cyclicModules(files);
		if (cyclic.length == 0) { continue; }
		cycles++;
		for (const f of files) {
			if (!cyclic.includes(f.name.slice(0, f.name.length - 3))) { continue; }
			for (const line of f.text.split("\n")) {
				const at = line.indexOf(" from \"./");
				if (at < 0 || !line.startsWith("import {") || !cyclic.includes(line.slice(at + 9, line.length - 2))) { continue; }
				for (const n of importedNames(line)) { assert !names.includes(n.split(" ")[0]); }
			}
		}
	}
	assert cycles > 0 && fragile > 0;
}

function reaches(files: File[], from: string, to: string): boolean {
	const seen: string[] = [];
	const todo: string[] = [from];
	while (todo.length > 0) {
		const at = todo.pop();
		if (at == to) { return true; }
		if (seen.includes(at)) { continue; }
		seen.push(at);
		for (const f of files) {
			if (f.name != at + ".ms") { continue; }
			for (const target of importsOf(f.text)) { todo.push(target); }
		}
	}
	return false;
}

function declaresGlue(text: string): boolean {
	for (const line of text.split("\n")) {
		for (const head of ["export function `", "export function onDestroy(", "export function onCopy(", "export function toString(this ", "export function toItems(this ", "export function getDynamicField("]) {
			if (line.startsWith(head)) { return true; }
		}
	}
	return false;
}

test "a module that reaches a module declaring an operator or an implicit function imports it directly, because those are visible only to its direct importers" {
	let glueModules = 0;
	let direct = 0;
	for (const vector of ["fams=conv", "fams=own", "fams=seq"]) {
		for (let seed = 1; seed <= 20; seed++) {
			const files = projectOf(seed as uint64, vector + " modules=4");
			assert files.length > 0;
			for (const g of files) {
				if (g.name == "main.ms" || !declaresGlue(g.text)) { continue; }
				glueModules++;
				const gname = g.name.slice(0, g.name.length - 3);
				for (const f of files) {
					const fname = f.name.slice(0, f.name.length - 3);
					if (fname == gname || (fname != "main" && fname.slice(1, fname.length).parseInt() < gname.slice(1, gname.length).parseInt())) { continue; }
					if (!reaches(files, fname, gname)) { continue; }
					direct++;
					assert importsOf(f.text).includes(gname) || f.text.contains("\nimport \"./" + gname + "\";\n");
				}
			}
		}
	}
	assert glueModules > 0 && direct > 0;
}

test "a global lent to a Borrow parameter is declared and read in one file, because another file reads it as a plain value" {
	let lent = 0;
	for (const vector of ["fams=own", "fams=seq", "fams=conv,own,seq"]) {
		for (let seed = 1; seed <= 25; seed++) {
			const files = projectOf(seed as uint64, vector + " modules=4 modshapes=alias,ns,reexport");
			assert files.length > 0;
			for (const f of files) {
				let at = f.text.indexOf("readG");
				while (at >= 0) {
					const open = f.text.indexOf("(", at);
					const comma = f.text.indexOf(",", at);
					at = f.text.indexOf("readG", at + 5);
					if (open < 0 || comma < open) { continue; }
					const arg = f.text.slice(open + 1, comma).trim();
					const dot = arg.indexOf(".");
					assert dot < 0 || !isGlobalName(arg.slice(dot + 1, arg.length));
					if (!isGlobalName(arg)) { continue; }
					lent++;
					assert f.text.contains("let " + arg + ":");
					for (const other of files) {
						if (other.name == f.name) { continue; }
						const toks = scanTokens(other.text);
						assert toks.ok;
						for (const tok of toks.value) { assert tok.text != arg; }
					}
				}
			}
		}
	}
	assert lent > 0;
}

test "a function with a default parameter is never called through a namespace import, which drops the default on every backend" {
	let defaults = 0;
	for (let seed = 1; seed <= 30; seed++) {
		const files = projectOf(seed as uint64, "modules=4 modshapes=ns");
		assert files.length > 0;
		const names: string[] = [];
		for (const f of files) {
			for (const line of f.text.split("\n")) {
				const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
				if (!bare.startsWith("function ")) { continue; }
				const head = unitHead(bare);
				if (!head.ok) { continue; }
				head.value.text = bare;
				if (hasDefault(head.value)) { names.push(head.value.name); }
			}
		}
		defaults += names.length;
		for (const f of files) {
			for (const name of names) {
				for (const line of f.text.split("\n")) { assert !line.contains("x." + name + "(") && !line.contains("x_." + name + "("); }
			}
		}
	}
	assert defaults > 0;
}

test "a generic class is never renamed on import, because an aliased generic class cannot be instantiated" {
	let generics = 0;
	let aliased = 0;
	for (const vector of ["fams=gcls", "fams=generic", "fams=gcls,generic,cls"]) {
		for (let seed = 1; seed <= 20; seed++) {
			const files = projectOf(seed as uint64, vector + " modules=4 modshapes=alias");
			assert files.length > 0;
			const names: string[] = [];
			for (const f of files) {
				for (const line of f.text.split("\n")) {
					const bare = line.startsWith("export ") ? line.slice(7, line.length) : line;
					if (!bare.startsWith("class ")) { continue; }
					const end = bare.indexOf("<");
					if (end > 0 && end < bare.indexOf(" {")) { names.push(bare.slice(6, end)); generics++; }
				}
			}
			for (const f of files) {
				for (const line of f.text.split("\n")) {
					if (!line.startsWith("import {")) { continue; }
					for (const name of importedNames(line)) {
						if (name.contains(" as ")) { aliased++; }
						for (const g of names) { assert !name.startsWith(g + " as "); }
					}
				}
			}
		}
	}
	assert generics > 10 && aliased > 10;
}
