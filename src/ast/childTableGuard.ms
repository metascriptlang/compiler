import { readFile } from "std/fs";

const NODE_SRC = "std/meta/node.ms";

const TABLE_NAMES: string[] = ["visitor", "walker", "clone", "hash", "printer", "bridge"];

// The per-kind tables. "clone" and "printer" point at fieldspec.ms since
// both moved there (rebuildNodeData + nodeFields mention every Node-typed
// field); clone.ms itself only carries the xform + meta copy, and printer.ms
// is a generic sink-driven dump.
const TABLE_PATHS: string[] = [
	"src/ast/visitor.ms",
	"src/transform/walker.ms",
	"src/ast/fieldspec.ms",
	"src/compiler/transam/hash.ms",
	"src/ast/fieldspec.ms",
	"src/compiler/meta/bridge.ms",
];

const KNOWN_GAPS: string[] = [
	"visitor:arrowDefaults", "visitor:caseGuard", "visitor:ctorDefaults",
	"visitor:decorators", "visitor:fnDefaults", "visitor:methodDefaults",
	"walker:arrowDefaults", "walker:caseGuard", "walker:ctorDefaults",
	"walker:decorators", "walker:fnDefaults", "walker:methodDefaults",
	"hash:arrowDefaults", "hash:ctorDefaults", "hash:typExprFieldDecorators",
	"bridge:arrowDefaults", "bridge:ctorDefaults",
	"bridge:fnDefaults", "bridge:forOfPattern", "bridge:methodDefaults",
	"bridge:propInitializer",
];

function endsWith(s: string, suffix: string): boolean {
	if (s.length < suffix.length) return false;
	return s.slice(s.length - suffix.length, s.length) === suffix;
}

function trim(s: string): string {
	// "\r" is load-bearing on Windows: git checkouts there use CRLF line
	// endings, and without it every field name keeps a "\r\n\t" prefix —
	// tableMentions then never matches and all 6 tables fail spuriously.
	let a = 0;
	let b = s.length;
	while (a < b && (s.slice(a, a + 1) === " " || s.slice(a, a + 1) === "\t" || s.slice(a, a + 1) === "\n" || s.slice(a, a + 1) === "\r")) a = a + 1;
	while (b > a && (s.slice(b - 1, b) === " " || s.slice(b - 1, b) === "\t" || s.slice(b - 1, b) === "\n" || s.slice(b - 1, b) === "\r")) b = b - 1;
	return s.slice(a, b);
}

function refersToNode(t: string): boolean {
	let p = 0;
	while (true) {
		const i = t.indexOf("Node", p);
		if (i < 0) return false;
		const after = i + 4;
		if (after >= t.length) return true;
		const c = t.slice(after, after + 1);
		if (c === "[" || c === " " || c === ")" || c === "," || c === "|" || c === ";") return true;
		p = after;
	}
}

function collectFieldsInto(body: string, out: string[]): void {
	for (const part of body.split(",")) {
		const colon = part.indexOf(":", 0);
		if (colon < 0) continue;
		const name = trim(part.slice(0, colon));
		const ty = part.slice(colon + 1, part.length);
		if (name.length === 0) continue;
		if (!refersToNode(ty)) continue;
		let seen = false;
		for (const n of out) { if (n === name) { seen = true; } }
		if (!seen) out.push(name);
	}
}

export function nodeFieldNames(src: string): string[] {
	const out: string[] = [];
	let pos = 0;
	while (true) {
		const i = src.indexOf("export type ", pos);
		if (i < 0) break;
		const brace = src.indexOf(" = {", i);
		if (brace < 0) break;
		const end = src.indexOf("};", brace);
		if (end < 0) break;
		const alias = trim(src.slice(i + 12, brace));
		if (endsWith(alias, "Data")) collectFieldsInto(src.slice(brace + 4, end), out);
		pos = end + 2;
	}
	return out;
}

export function tableMentions(tableSrc: string, field: string): boolean {
	return tableSrc.indexOf("." + field, 0) >= 0;
}

function readOrEmpty(path: string): string {
	const r = readFile(path);
	if (!r.ok) return "";
	return r.value;
}

function firstUnreadable(paths: string[]): string {
	for (const p of paths) { if (readOrEmpty(p).length === 0) return p; }
	return "";
}

function isKnownGap(key: string): boolean {
	for (const g of KNOWN_GAPS) { if (g === key) return true; }
	return false;
}

test "child-table guard: every source it inspects is readable" {
	const missing = firstUnreadable(TABLE_PATHS);
	assert missing === "", "cannot read " + missing + " — run from the recompiler root";
	assert readOrEmpty(NODE_SRC).length > 0, "cannot read " + NODE_SRC + " — run from the recompiler root";
}

test "child-table guard: extractor still finds the AST field set" {
	const names = nodeFieldNames(readOrEmpty(NODE_SRC));
	const found = names.length;
	assert found >= 100,
		"extractor degraded — found only " + found.toString() + " Node-typed fields; a vacuous pass would hide every gap";
}

test "child-table guard: every Node-typed field is handled by every table" {
	const names = nodeFieldNames(readOrEmpty(NODE_SRC));
	let unexpected = "";
	let count = 0;
	let ti = 0;
	while (ti < TABLE_PATHS.length) {
		const src = readOrEmpty(TABLE_PATHS[ti]);
		const table = TABLE_NAMES[ti];
		for (const f of names) {
			if (tableMentions(src, f)) continue;
			const key = table + ":" + f;
			if (isKnownGap(key)) continue;
			unexpected = unexpected + "\n  " + key;
			count = count + 1;
		}
		ti = ti + 1;
	}
	assert count === 0,
		"AST field not traversed by " + count.toString() + " table(s) — add the field or record it in KNOWN_GAPS:" + unexpected;
}

test "child-table guard: KNOWN_GAPS has no stale entry" {
	const names = nodeFieldNames(readOrEmpty(NODE_SRC));
	let stale = "";
	let count = 0;
	let ti = 0;
	while (ti < TABLE_PATHS.length) {
		const src = readOrEmpty(TABLE_PATHS[ti]);
		const table = TABLE_NAMES[ti];
		for (const f of names) {
			if (!tableMentions(src, f)) continue;
			const key = table + ":" + f;
			if (!isKnownGap(key)) continue;
			stale = stale + "\n  " + key;
			count = count + 1;
		}
		ti = ti + 1;
	}
	assert count === 0,
		"KNOWN_GAPS lists " + count.toString() + " entry(s) that are now handled — delete them so the guard keeps its teeth:" + stale;
}
