// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): a union's onDestroy run for a class field reads no member on the Raiser; card 2026-11-11-raiser-union-hook-of-a-class-field-reads-no-member
// @stdout: plain call 2 field 6 | gen call 8 field 24
// note: a union's onDestroy also runs on the moved-from value, as a struct's does; reading that value through another
// union (here a parameter typed with the union's members) finds no member and adds nothing, instead of stopping the
// program with "member … is not accessible".
class Leaf { id: int32 = 0; }
class Twig { id: int32 = 0; }
type Plain = Leaf | Twig;
type Gen<T> = T | Twig;

let plainCloses: int32 = 0;
let genCloses: int32 = 0;

function held(x: Leaf | Twig): int32 {
	if (x instanceof Leaf) return x.id;
	if (x instanceof Twig) return x.id;
	return 0;
}

function onDestroy(this p: Plain): void { plainCloses += held(p); }
function onDestroy(this g: Gen<Leaf>): void { genCloses += held(g); }

class PlainOwner { p: Plain; constructor(p: Plain) { this.p = p; } }
class GenOwner { g: Gen<Leaf>; constructor(g: Gen<Leaf>) { this.g = g; } }

function leaf(id: int32): Leaf { const l = new Leaf(); l.id = id; return l; }
function takePlain(p: Plain): int32 { return 0; }
function takeGen(g: Gen<Leaf>): int32 { return 0; }

{ const p: Plain = leaf(2); takePlain(p); }
const plainCall = plainCloses;
{ const p: Plain = leaf(4); const o = new PlainOwner(p); }
const plainField = plainCloses;
{ const g: Gen<Leaf> = leaf(8); takeGen(g); }
const genCall = genCloses;
{ const g: Gen<Leaf> = leaf(16); const o = new GenOwner(g); }
console.log(`plain call ${plainCall} field ${plainField} | gen call ${genCall} field ${genCloses}`);
