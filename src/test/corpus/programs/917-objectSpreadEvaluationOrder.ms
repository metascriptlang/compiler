// @stdout: ternary:  0 0
// @xfail(raiser): Raiser keeps the eager spread lowering (no conditional-expression pass), so a spread operand runs first
let log = "";
function one(): int32 { log = log + "o"; return 9; }
interface P { x: int32; y: int32; }
function pt(): P { log = log + "P"; return { x: 1, y: 2 }; }
function run(): void {
	log = "";
	const q: P = { y: one(), ...pt() };
	console.log("after property: " + log + " " + q.x.toString() + q.y.toString());
	log = "";
	const q2: P = { ...pt(), y: one() };
	console.log("before property: " + log + " " + q2.x.toString() + q2.y.toString());
	log = "";
	const flag = false;
	const q3: P = flag ? { ...pt(), y: 5 } : { x: 0, y: 0 };
	console.log("ternary: " + log + " " + q3.x.toString() + " " + q3.y.toString());
}
run();
