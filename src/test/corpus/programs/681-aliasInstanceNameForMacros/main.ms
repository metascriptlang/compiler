// @xfail(raiser): a method call made inside a function loses its result on the Raiser VM (`c.bump()` in main stops with 'attempt to access a nil address'), inbox 2026-10-03-raiser-method-call-inside-a-function-loses-its-result
// @stdout: heads object=generic:Brand int=generic:Brand annotated=generic:Brand class=generic:Brand struct=generic:Brand wrapped=generic:Ref
// @xfail(raiser): output differs from c: heads object=generic:Ref int=ident:int32, then raiser runtime error: attempt to access a nil address in Cell_bump
// note: a macro reads the type of its argument through `node.nodeType`. An instance of `type Brand<T> = T` is the name `Brand` over its body: typing reads through it, and the macro still sees the alias head, as Nim keeps the wrapper `getTypeInst` shows. The head must survive for an object, a number, a written annotation, a class and a value struct. The values below run through the same instances (member read and write, method call, parameter, field, array element, destructuring), so C and JS agree on the body while the head stays. A struct-literal body (`Wrapped<T>`) has never carried its name to a macro and prints the same either side.

import { head, brand, wrapped, Brand } from "./brand";

class Cell { n: int32 = 3; bump(): int32 { this.n = this.n + 1; return this.n; } }
class Holder { cell: Brand<Cell>; constructor() { this.cell = new Cell(); } }
struct Pt { x: int32; y: int32; }

function mkPt(): Pt { return { x: 2, y: 3 }; }
function peek(c: Brand<Cell>): int32 { return c.n; }

function main(): void {
	const o = brand({ x: 1 });
	const n = brand(5);
	const a: Brand<int32> = 4;
	const c = brand(new Cell());
	const p = brand(mkPt());
	const w = wrapped(7);
	console.log(`heads object=${head(o)} int=${head(n)} annotated=${head(a)} class=${head(c)} struct=${head(p)} wrapped=${head(w)}`);
	console.log(`values ${o.x + n + a + c.bump() + p.x + p.y + w.v}`);

	o.x = 6;
	const h = new Holder();
	h.cell.n = 9;
	const cells: Brand<Cell>[] = [new Cell(), brand(new Cell())];
	cells.push(new Cell());
	let total = 0;
	for (const k of cells) total += k.n;
	const { x } = brand({ x: 3 });
	console.log(`flows ${o.x + peek(h.cell) + peek(brand(new Cell())) + total + cells[1].n + x}`);
}

main();
