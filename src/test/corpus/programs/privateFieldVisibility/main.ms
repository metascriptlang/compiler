// @stdout: signer=7 copy=7 box=4,1 bag=2,2 counter=2,true adopted=5 upcast=1 distinct=3
// @stdout: minted=11,12,11 declared=13
// note: private struct fields reached only through the declaring module's functions, a private class member reached only from its class body (methods, a closure in a method, a static, another instance), a generic struct and class with private members used from another module, an anonymous value adopted by a struct, the struct conversions `as` allows, and macros and a template of the declaring module building and reading a private field in this module. Same output on every backend.

import { Account, Signer, signer, address, Box, box, unbox, Bag, Counter, mint, mintTwice, declareProof, unwrapped } from "./lib/proof";

struct Base { x: int32; }
struct Derived extends Base { y: int32; }
type Tag = distinct Base;

const ok = signer({ address: 7 });
const copy = ok;
const b = box<int32>(4);
const bag = new Bag<int32>();
bag.add(1);
const c = new Counter();
c.hit();
const raw = { x: 5 };
const adopted = raw as Base;
const d: Derived = { x: 1, y: 2 };
const up = d as Base;
const t = ({ x: 3 } as Base) as Tag;
console.log(`signer=${ok.address()} copy=${copy.address()} box=${unbox(b)},${b.n} bag=${bag.add(2)},${Bag.of<int32>(9).add(8)} counter=${c.hit()},${c.same(c)} adopted=${adopted.x} upcast=${up.x} distinct=${(t as Base).x}`);
declareProof({ address: 13 });
const minted = mint({ address: 11 });
const mintedTwice = mintTwice({ address: 12 });
console.log(`minted=${minted.address()},${mintedTwice.address()},${unwrapped(minted)} declared=${proof.address()}`);
