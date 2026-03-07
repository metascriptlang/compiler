// Raiser VM — Bytecode execution demo
// Usage: msc test src/raiser/repl.ms

import { RaiserOpcode, raiserABC, raiserABx, raiserAx } from "./bytecode";
import { raiserInt, raiserToString } from "./value";
import { makeTestModule } from "./module";
import { createContext, load, execute } from "./context";
test "2 + 2 = 4" {
	const ctx = createContext();
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(2)]
	);
	load(ctx, mod);
	execute(ctx);
	console.log("  2 + 2 = " + raiserToString(ctx.lastResult));
	assert ctx.lastResult.intVal === 4;
}

test "(2 + 3) * 4 = 20" {
	const ctx = createContext();
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
			raiserABx(RaiserOpcode.LoadConst, 3, 2),
			raiserABC(RaiserOpcode.MulI64, 4, 2, 3),
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(2), raiserInt(3), raiserInt(4)]
	);
	load(ctx, mod);
	execute(ctx);
	console.log("  (2 + 3) * 4 = " + raiserToString(ctx.lastResult));
	assert ctx.lastResult.intVal === 20;
}

test "sum 1..5 = 15 (loop)" {
	const ctx = createContext();
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABx(RaiserOpcode.LoadConst, 2, 2),
			raiserABx(RaiserOpcode.LoadConst, 3, 1),
			raiserABC(RaiserOpcode.BgtI64, 1, 2, 3),
			raiserABC(RaiserOpcode.AddI64, 0, 0, 1),
			raiserABC(RaiserOpcode.AddI64, 1, 1, 3),
			raiserAx(RaiserOpcode.Jump, -4),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(0), raiserInt(1), raiserInt(5)]
	);
	load(ctx, mod);
	execute(ctx);
	console.log("  sum 1..5 = " + raiserToString(ctx.lastResult));
	assert ctx.lastResult.intVal === 15;
}
