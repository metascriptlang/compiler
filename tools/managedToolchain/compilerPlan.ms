export struct CompilePlan {
	target: string;
	cpu: string;
	pic: string[];
	defines: string[];
	features: string[];
	isystem: string[];
}

const TARGET = "-target";
const ISYSTEM = "-isystem";
const XCLANG = "-Xclang";
const TARGET_CPU = "-target-cpu";
const TARGET_FEATURE = "-target-feature";
const NDEBUG = "-DNDEBUG";
const DEFINE_PREFIX = "-D";
const PIC_FLAGS: string[] = [
	"-fno-PIE",
	"-fPIE",
	"-fno-PIC",
	"-fPIC",
	"-fno-pie",
	"-fpie",
	"-fno-pic",
	"-fpic",
];

function place(index: int32): string {
	return "tokens[" + String(index) + "]: ";
}

function operand(
	tokens: Readonly<Span<string>>,
	index: int32,
): Result<string, string> {
	const flag = tokens[index];
	if (index + 1 >= tokens.length) {
		return Result.err(place(index) + flag + " has no value");
	}
	const value = tokens[index + 1];
	if (value == "") {
		return Result.err(place(index) + flag + " value is empty");
	}
	return Result.ok(value);
}

function startsCodegenGroup(
	tokens: Readonly<Span<string>>,
	index: int32,
): boolean {
	if (tokens[index] != XCLANG || index + 1 >= tokens.length) { return false; }
	return tokens[index + 1] == TARGET_CPU ||
		tokens[index + 1] == TARGET_FEATURE;
}

function codegenOperand(
	tokens: Readonly<Span<string>>,
	index: int32,
): Result<string, string> {
	const flag = XCLANG + " " + tokens[index + 1];
	if (index + 3 >= tokens.length || tokens[index + 2] != XCLANG) {
		return Result.err(
			place(index) + flag + " is not followed by " + XCLANG +
				" and a value",
		);
	}
	const value = tokens[index + 3];
	if (value == "") {
		return Result.err(place(index) + flag + " value is empty");
	}
	return Result.ok(value);
}

export function parseCompileArguments(
	tokens: Readonly<Span<string>>,
): Result<CompilePlan, string> {
	let target = "";
	let cpu = "";
	const pic: string[] = [];
	const defines: string[] = [];
	const features: string[] = [];
	const isystem: string[] = [];
	let index: int32 = 0;
	while (index < tokens.length) {
		const token = tokens[index];
		if (token == TARGET) {
			target = try operand(tokens, index);
			index += 2;
		} else if (token == ISYSTEM) {
			const directory = try operand(tokens, index);
			isystem.push(directory);
			index += 2;
		} else if (startsCodegenGroup(tokens, index)) {
			const value = try codegenOperand(tokens, index);
			if (tokens[index + 1] == TARGET_CPU) {
				cpu = value;
			} else {
				features.push(value);
			}
			index += 4;
		} else {
			if (PIC_FLAGS.indexOf(token) >= 0) {
				pic.push(token);
			} else if (token.startsWith(DEFINE_PREFIX) && token != NDEBUG) {
				defines.push(token);
			}
			index += 1;
		}
	}
	if (target == "") {
		return Result.err("compile arguments have no " + TARGET);
	}
	if (cpu == "") {
		return Result.err("compile arguments have no " + TARGET_CPU);
	}
	if (isystem.length == 0) {
		return Result.err("compile arguments have no " + ISYSTEM);
	}
	return Result.ok({ target, cpu, pic, defines, features, isystem });
}
