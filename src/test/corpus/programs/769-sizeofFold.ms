// Parity program — sizeof folds to the real width at compile time, and the
// folded literal is built through the number-literal constructor rather than
// reinterpreted onto the union variant (which read the four trailing fields
// from stack garbage and printed an address).
//
// @stdout: 4|1|8|8|8|4|16|4|8|16|16|8|32
// @exit: 0

type MyId = distinct int32;
enum E { A, B, C }
struct P { x: int32; y: int32 }

type R =
	| { ok: true, value: int32 }
	| { ok: false, error: string };

type Shape =
	| { kind: "circle", r: float64 }
	| { kind: "rect", w: float64, h: float64 };

const parts: string[] = [
	sizeof(int32).toString(),
	sizeof(uint8).toString(),
	sizeof(int64).toString(),
	sizeof(float64).toString(),
	sizeof(P).toString(),
	sizeof(E).toString(),
	sizeof(string).toString(),
	sizeof(MyId).toString(),
	sizeof(bigint).toString(),
	sizeof(R).toString(),
	sizeof(Shape).toString(),
	sizeof(Promise<int32>).toString(),
	sizeof(Result<int32, string>).toString(),
];
console.log(parts.join("|"));
