// @skip-js: a JS object is a reference, so the arm and the object it came from are one value; C copies the fields (card 2026-10-16-match-union-copies-on-c-and-aliases-on-js)
// @skip-raiser: same value/reference difference as JS
// @stdout: true false 24
// @stdout: e3 changed
// @stdout: bad kept
// @stdout: pv kept
// note: the arm built from an object owns its own copy of every stored field, and the object stays alive: writing the object's string after the conversion leaves the arm's string alone, and both are released once under the DRC ledger. The unions are the by-value `match` shapes and `Result`; the conversion into each reads the object through a copy of its field, never a shared pointer.

type Flag = match (ok: boolean) { true => {}, false => { error: string } };
type Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };

function mk(g: boolean): Flag { return g ? { ok: true } : { ok: false, error: "no" }; }
function errorOf(r: Result<int32, string>): string { return r.ok ? "none" : r.error; }
function valueOf(p: Pair): string { return p.ok ? p.value : p.error; }

const o: { ok: true } = { ok: true };
const f: Flag = o;
const g = mk(false);
console.log(f.ok, g.ok, sizeof(Flag));

const n = 3;
const ob: { ok: false; error: string } = { ok: false, error: "e" + `${n}` };
const h: Flag = ob;
ob.error = "changed";
if (!h.ok) console.log(h.error, ob.error);

function failing(): Result<int32, string> {
	const e: { ok: false; error: string } = { ok: false, error: "b" + "ad" };
	const r: Result<int32, string> = e;
	e.error = "overwritten";
	return r;
}
const r = failing();
console.log(errorOf(r), "kept");

const pv: { ok: true; value: string } = { ok: true, value: "p" + "v" };
const p: Pair = pv;
pv.value = "overwritten";
console.log(valueOf(p), "kept");
