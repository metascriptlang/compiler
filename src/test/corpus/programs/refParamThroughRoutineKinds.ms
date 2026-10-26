// @stdout: 2 3
// @stdout: 4 5
// @stdout: 6
// @stdout: 8
// @stdout: 10 9

function bump(ref x: int32): void { x += 1; }
function bumped(ref x: int32): int32 { x += 1; return x; }

const arrow = (n: int32): int32 => { bump(n); return n; };
const expr = function (n: int32): int32 { bump(n); bump(n); return n; };
console.log(arrow(1), expr(1));

class C {
	at(n: int32): int32 { bump(n); return n; }
}
const short = (n: int32): int32 => bumped(n);
console.log(new C().at(3), short(4));

function outer(n: int32): int32 {
	const inner = (n: int32): int32 => { bump(n); return n; };
	return inner(n + 1);
}
console.log(outer(4));

function captured(n: int32): int32 {
	const twice = (): void => { bump(n); bump(n); };
	twice();
	return n;
}
console.log(captured(6));

function both(n: int32): void {
	const g = (m: int32): int32 => { bump(m); return m; };
	bump(n);
	console.log(g(n), n);
}
both(8);
