// Parity program — a generic method marked @throws is instantiated per call,
// instance and static, with inferred and explicit type arguments.
//
// @skip-js: @throws is declared only in the native system prelude
// @stdout: -5 -5 x 2
// @exit: 0

class Holder {
	@throws
	keep<T>(v: T): T { return v; }
	@throws
	static skeep<T>(v: T): T { return v; }
}

const h = new Holder();
const small: int8 = -5;
const a = h.keep<int8>(small);
const b = Holder.skeep<int8>(small);
const c = h.keep("x");
const d = Holder.skeep([1, 2]);
console.log(`${a} ${b} ${c} ${d.length}`);
