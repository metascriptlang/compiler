// @stdout: class 1 2
// @stdout: struct 3 4
// @stdout: env user 1 2
// note: user types whose names mangle to one C spelling (`$A` / `dollarA_`) and a user type spelled like a compiler-made closure env (`$Env_mk_shared`) are each their own C struct.
class $A { a: number = 1; }
class dollarA_ { b: number = 2; }
struct $P { p: int32; }
struct dollarP_ { q: int32; }
class $Env_mk_shared { label: string = "user"; }

function mk(): () => number {
	let n = 0;
	const bump = (): number => { n += 1; return n; };
	return () => bump();
}

const x = new $A();
const y = new dollarA_();
console.log(`class ${x.a} ${y.b}`);
const p: $P = { p: 3 };
const q: dollarP_ = { q: 4 };
console.log(`struct ${p.p} ${q.q}`);
const u = new $Env_mk_shared();
const c = mk();
console.log(`env ${u.label} ${c()} ${c()}`);
