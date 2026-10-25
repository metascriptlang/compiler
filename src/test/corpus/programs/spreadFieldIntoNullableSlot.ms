// @stdout: handler yes x | call yes t2 no t5 3 | nested moved 4 moved 8 | named yes | class x 1.5 | member x
interface Handlers { onStart: (n: int32) => boolean; tag: string; }
interface Props { onStart?: ((n: int32) => boolean) | null; tag?: string | null; label?: string | null; }
interface Movers { onMove: (n: int32) => void; }
interface MoveProps { onMove?: ((n: int32) => void) | null; }
interface Tester { test: (n: int32) => boolean; }
interface TestProps { test: ((n: int32) => boolean) | null; }
interface Labeled { label: string; n: int32; }
class Row { label: string | null = null; n: number = 0; }
type Item = { kind: "a"; label: string | null } | { kind: "b"; n: int32 };

let made = 0;
let seen = 0;
function handlers(limit: int32): Handlers { made = made + 1; return { onStart: (n: int32): boolean => n > limit, tag: `t${limit}` }; }
function above(n: int32): boolean { return n > 1; }

function start(p: Props): string {
	const f = p.onStart;
	const t = p.tag;
	if (f === null || t === null) { return "none"; }
	return ((f as (n: int32) => boolean)(3) ? "yes " : "no ") + (t as string);
}
function label(p: Props): string { const l = p.label; return l === null ? "none" : l as string; }
function moveBy(p: MoveProps): string {
	const f = p.onMove;
	if (f === null) { return "none"; }
	(f as (n: int32) => void)(4);
	return `moved ${seen}`;
}
function show(i: Item): string { return i.kind === "a" ? (i.label === null ? "none" : i.label as string) : `${i.n}`; }

const h = handlers(2);
const direct: Props = { ...h, label: "x" };
const handlerOut = "handler " + (start(direct) == "yes t2" ? "yes" : "no") + " " + label(direct);
const callOut = "call " + start({ ...handlers(2) }) + " " + start({ ...handlers(5) }) + " " + made;
const m: Movers = { onMove: (n: int32): void => { seen = seen + n; } };
const nestedOut = "nested " + moveBy({ ...{ ...m } }) + " " + moveBy({ ...m });
const t: Tester = { test: above };
const tp: TestProps = { ...t };
const tf = tp.test;
const namedOut = "named " + (tf === null ? "none" : ((tf as (n: int32) => boolean)(2) ? "yes" : "no"));
const src: Labeled = { label: "x", n: 3 };
const r: Row = { ...src };
const rl = r.label;
const classOut = "class " + (rl === null ? "none" : rl as string) + " " + (r.n / 2);
const memberOut = "member " + show({ kind: "a", ...src });
console.log(handlerOut + " | " + callOut + " | " + nestedOut + " | " + namedOut + " | " + classOut + " | " + memberOut);
