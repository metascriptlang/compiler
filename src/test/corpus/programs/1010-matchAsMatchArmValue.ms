// Parity program — a match expression used as the value of another match
// arm delivers to the outer destination (return, let initializer, block
// result, or a statement whose value is discarded), at any depth and on
// every dispatch shape (enum switch, int switch, string chain).
//
// @stdout: 20 10 30|20 10 30|200 100 21 30|7 8 9|2 1 0|20|10|30
// @exit: 0

enum Side { Left, Right }

const out: string[] = [];

function viaReturn(side: Side, step: int32): int32 {
	return match (side) {
		Side.Left => match (step) {
			2 => 20,
			_ => 10,
		},
		Side.Right => 30,
	};
}

function viaLet(side: Side, step: int32): int32 {
	const r = match (side) {
		Side.Left => match (step) {
			2 => 20,
			_ => 10,
		},
		Side.Right => 30,
	};
	return r;
}

function deeper(side: Side, step: int32, deep: boolean): int32 {
	return match (side) {
		Side.Left => match (step) {
			2 => match (deep) {
				true => 200,
				false => 20,
			},
			1 => match (deep) {
				true => 100,
				false => 10,
			},
			_ => 21,
		},
		Side.Right => 30,
	};
}

function byName(name: string, step: int32): int32 {
	const r = match (name) {
		"a" => match (step) {
			1 => 7,
			_ => 8,
		},
		_ => 9,
	};
	return r;
}

function inBlock(side: Side, step: int32): int32 {
	const r = match (side) {
		Side.Left => {
			const bump = step + 1;
			return match (bump) {
				3 => 2,
				_ => 1,
			};
		},
		Side.Right => 0,
	};
	return r;
}

function say(n: int32): int32 {
	out.push(`${n}`);
	return n;
}

function asStatement(side: Side, step: int32): void {
	match (side) {
		Side.Left => match (step) {
			2 => say(20),
			_ => say(10),
		},
		Side.Right => say(30),
	};
}

out.push(`${viaReturn(Side.Left, 2)} ${viaReturn(Side.Left, 1)} ${viaReturn(Side.Right, 0)}`);
out.push(`${viaLet(Side.Left, 2)} ${viaLet(Side.Left, 1)} ${viaLet(Side.Right, 0)}`);
out.push(`${deeper(Side.Left, 2, true)} ${deeper(Side.Left, 1, true)} ${deeper(Side.Left, 5, false)} ${deeper(Side.Right, 0, true)}`);
out.push(`${byName("a", 1)} ${byName("a", 2)} ${byName("b", 1)}`);
out.push(`${inBlock(Side.Left, 2)} ${inBlock(Side.Left, 0)} ${inBlock(Side.Right, 0)}`);
asStatement(Side.Left, 2);
asStatement(Side.Left, 1);
asStatement(Side.Right, 0);
console.log(out.join("|"));
