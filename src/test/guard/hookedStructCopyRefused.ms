// nim-guard: a value that declares onDestroy and no onCopy is never copied implicitly.
//
// Nim: injectdestructors.nim:289-294, :413-421 and :549-555 report checkForErrorPragma
// where an analyzer copy needs a '=copy' marked {.error.}; liftdestructors.nim:417 and :446
// carry that mark from a field's '=copy' to its container's. A struct with onDestroy and no
// onCopy has its copy marked so by default (a forced divergence: a field-wise copy would
// run onDestroy once per copy, so a handle would be closed twice).
//
// RED MEANS a copy of such a struct or distinct type, of a struct or tuple holding one, or into
// a sink position (push, a literal field) compiles again; on the parent this program closes 1,
// 2 and 4 twice, 6 three times and releases 9 twice. An array assignment shares the array and
// copies no element.
//
// GUARD-CHECK-FAIL cannot copy 'a'
// GUARD-CHECK-FAIL cannot copy 'o'
// GUARD-CHECK-FAIL cannot copy 'pair'
// GUARD-CHECK-FAIL cannot copy 'kept'
// GUARD-CHECK-FAIL 'Fd' declares onDestroy and no onCopy
// GUARD-CHECK-FAIL cannot copy 'h'

struct Fd { n: int32; }
function onDestroy(this f: Fd): void { console.log(`close ${f.n}`); }

type Handle = distinct int32;
function onDestroy(this h: Handle): void { console.log(`release ${h as int32}`); }
function grab(n: int32): Handle { return n as Handle; }

struct Owner { fd: Fd; tag: int32; }

function run(): void {
	const a: Fd = { n: 1 };
	const b = a;
	console.log(`${a.n} ${b.n}`);

	const o: Owner = { fd: { n: 2 }, tag: 7 };
	const p = o;
	console.log(`${o.tag} ${p.tag}`);

	const pair: [Fd, int32] = [{ n: 4 }, 5];
	const twin = pair;
	console.log(`${pair[1]} ${twin[1]}`);

	const kept: Fd = { n: 6 };
	const held: Fd[] = [];
	held.push(kept);
	const boxed: Owner = { fd: kept, tag: 8 };
	console.log(`${held.length} ${boxed.tag} ${kept.n}`);

	const h = grab(9);
	const g = h;
	console.log(`${h as int32} ${g as int32}`);
}

run();
