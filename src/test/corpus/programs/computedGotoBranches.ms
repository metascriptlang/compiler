// @stdout: plain  4302
// @stdout: marked 4302
// A case of a `@computedGoto;` loop that ends in an `if` without else, an `if` with else, an `else if`
// chain or a nested `if` dispatches from every path. Each loop has an unmarked twin with the same body;
// the program prints both, so the lanes agree only if the dispatch on each path continues exactly as the
// shared tail did. The JS lane runs the marked loop as an ordinary loop.

enum Op { Add, Skip, Pick, Nest, Chain, Stop }

function plain(code: Op[]): int32 {
	let pc = 0;
	let acc: int32 = 0;
	let hits: int32 = 0;
	while (true) {
		const op = code[pc];
		pc += 1;
		switch (op) {
			case Op.Add: { acc += 3; if (acc % 2 == 0) { hits += 1; } break; }
			case Op.Skip: { if (acc > 50) { pc += 1; } break; }
			case Op.Pick: { if (acc > 20) { acc += 1; } else { acc += 10; } break; }
			case Op.Nest: { if (acc > 10) { if (acc % 3 == 0) { acc += 5; } } break; }
			case Op.Chain: { if (acc < 30) { acc *= 2; } else if (acc < 90) { acc += 7; } else { hits += 100; } break; }
			case Op.Stop: return acc * 100 + hits;
		}
	}
}

function marked(code: Op[]): int32 {
	let pc = 0;
	let acc: int32 = 0;
	let hits: int32 = 0;
	while (true) {
		@computedGoto;
		const op = code[pc];
		pc += 1;
		switch (op) {
			case Op.Add: { acc += 3; if (acc % 2 == 0) { hits += 1; } break; }
			case Op.Skip: { if (acc > 50) { pc += 1; } break; }
			case Op.Pick: { if (acc > 20) { acc += 1; } else { acc += 10; } break; }
			case Op.Nest: { if (acc > 10) { if (acc % 3 == 0) { acc += 5; } } break; }
			case Op.Chain: { if (acc < 30) { acc *= 2; } else if (acc < 90) { acc += 7; } else { hits += 100; } break; }
			case Op.Stop: return acc * 100 + hits;
		}
	}
}

const program: Op[] = [Op.Add, Op.Pick, Op.Nest, Op.Add, Op.Chain, Op.Skip, Op.Nest, Op.Pick, Op.Add, Op.Chain, Op.Nest, Op.Skip, Op.Stop, Op.Stop, Op.Stop];
console.log("plain  " + plain(program).toString());
console.log("marked " + marked(program).toString());
