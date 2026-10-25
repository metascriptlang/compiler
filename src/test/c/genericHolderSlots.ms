// A write to one instance of a generic holder ends no view read from another instance of it: the slot
// names the instance, not the generic declaration. Holder unit tests: `src/analyzer/writeEffects.ms`.

import { compileToC } from "../helpers";

function requestBody(c: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(" request__") && line.endsWith(") {") && !line.startsWith(" ") && !line.startsWith("\t")) {
			const open = c.indexOf(line, 0);
			return c.slice(open, c.indexOf("\n}", open));
		}
	}
	return "";
}

const BAG = (write: string) => `
class Sym { name: string = ""; }
class Bag<T> { value: T | null = null; }
class Gen { names: Bag<string> = new Bag<string>(); syms: Bag<Sym> = new Bag<Sym>(); copies: Cursor<Readonly<Sym>>[] = []; out: string[] = []; }

function request(g: Gen, held: Readonly<Bag<Sym>>): void {
	const sym = held.value;
	if (sym == null) return;
	g.out.push(header(g, sym.name));
	g.copies.push(sym);
}

function header(g: Gen, n: string): string { ${write}; return n; }

const g = new Gen();
const b = new Bag<Sym>(); b.value = new Sym();
request(g, b);
console.log(g.copies.length);
`;

const MAP = `
class Sym { name: string = ""; }
class Gen { names: HashMap<string, string> = new HashMap<string, string>(); copies: Cursor<Readonly<Sym>>[] = []; out: string[] = []; }

function placedOf(m: Readonly<HashMap<Sym, Sym>>, s: Readonly<Sym>): Readonly<Sym> {
	return m.readonlyGet(s) ?? s;
}

function request(g: Gen, placed: Readonly<HashMap<Sym, Sym>>, called: Readonly<Sym>): void {
	const sym = placedOf(placed, called);
	g.out.push(header(g, sym.name));
	g.copies.push(sym);
}

function header(g: Gen, n: string): string { g.names.set(n, "x"); return n; }

const g = new Gen();
const s = new Sym();
request(g, new HashMap<Sym, Sym>(), s);
console.log(g.copies.length);
`;

test "E2E C: a view of one generic instance's field takes no rc op beside a write to another instance's field" {
	const r = compileToC(BAG("g.names.value = n"));
	assert r.ok;
	const body = requestBody(r.ok ? r.value : "");
	assert body.length > 0;
	assert !body.contains("msIncref(sym"), body;
	assert !body.contains("msDecref(sym"), body;
}

test "E2E C: a view returned from one map instance takes no rc op beside a store into a map of other arguments" {
	const r = compileToC(MAP);
	assert r.ok;
	const body = requestBody(r.ok ? r.value : "");
	assert body.length > 0;
	assert !body.contains("msIncref(sym"), body;
	assert !body.contains("msDecref(sym"), body;
}

test "E2E C: a view of a generic instance's field stays counted beside a write to the same instance's field" {
	const r = compileToC(BAG("g.syms.value = new Sym()"));
	assert r.ok;
	const body = requestBody(r.ok ? r.value : "");
	assert body.contains("msIncref(sym"), body;
}
