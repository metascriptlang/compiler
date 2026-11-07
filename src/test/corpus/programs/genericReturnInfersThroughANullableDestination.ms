// A generic call whose type parameter appears only in its return type infers it from a nullable destination,
// as from each member of that union: `T[]` into `Rule[] | null` binds T = Rule, in a declaration, a conditional branch,
// a return statement and an object field.
// @stdout: decl 0 false | cond true 0 | ret 0 | field 0 | strings 0
// @stdout: matrix 0

struct Rule { name: string; }
struct Doc { rules: Rule[] | null; }

function none<T>(): T[] { return []; }
function grid<T>(): T[][] { return []; }

function rulesOrNull(empty: boolean): Rule[] | null {
	return empty ? null : none();
}

const decl: Rule[] | null = none();
const pick = decl !== null && decl.length == 0;
const cond: Rule[] | null = pick ? null : none();
const fromReturn = rulesOrNull(false);
const doc: Doc = { rules: none() };
const strings: string[] | null = none();
const matrix: int32[][] | null = grid();
console.log(`decl ${decl?.length ?? -1} ${decl === null} | cond ${cond === null} ${cond?.length ?? 0} | ret ${fromReturn?.length ?? -1} | field ${doc.rules?.length ?? -1} | strings ${strings?.length ?? -1}`);
console.log(`matrix ${matrix?.length ?? -1}`);
