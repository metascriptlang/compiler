// INVARIANT: ULTRALOCK V0 (a declared operator is a call to its routine).
// RED MEANS: an operator body reaching module state crosses threads unchecked.
// GUARD-JS
// GUARD-CHECK-FAIL calls the operator
// GUARD-CHECK-FAIL module state crosses threads only as a const value

let hits: int32 = 0;

class V {
	n: int32 = 0;
}

function `+`(this a: V, b: V): V {
	hits = hits + 1;
	const r = new V();
	r.n = a.n + b.n;
	return r;
}

function `/=`(this ref a: int32, b: int32): void {
	hits = hits + 1;
	a = a + b;
}

actor Adder {
	go(): int32 { const x = new V(); const y = new V(); const z = x + y; return z.n; } // GUARD-REFUSED
}

actor Divider {
	go(k: int32): int32 { let v: int32 = 10; v /= k; return v; } // GUARD-REFUSED
}

const t = spawn((): int32 => { const x = new V(); const y = new V(); return (x + y).n; }); // GUARD-REFUSED
const a = new Adder();
const d = new Divider();
console.log(`${await t} ${await a.go()} ${await d.go(3)} ${hits}`);
