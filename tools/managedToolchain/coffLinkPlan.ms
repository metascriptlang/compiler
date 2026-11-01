import { basename } from "std/fs";

export struct CoffLinkPlan {
	dll: boolean;
	machine: string;
	stack: uint64 | null;
	base: uint64;
	inputs: string[];
	notCarried: string[];
}

const IGNORED_FLAGS: string[] = [
	"-lldmingw", "-ERRORLIMIT:0", "-NOLOGO", "-DEBUG", "-BUILD-ID:NO",
	"-BREPRO", "-MLLVM:-float-abi=hard",
];
const IGNORED_PREFIXES: string[] = [
	"-PDB:", "-PDBALTPATH:", "-OUT:", "-IMPLIB:",
];
const STACK_PREFIX: string = "-STACK:";
const BASE_PREFIX: string = "-BASE:";
const MACHINE_PREFIX: string = "-MACHINE:";
const UINT64_LIMIT: uint64 = 18446744073709551615;
const RADIX: uint64 = 10;

function place(index: int64): string {
	return "tokens[" + String(index) + "]: ";
}

function decimal(text: string): boolean {
	if (text == "") { return false; }
	const bytes = text.asBytes();
	for (let i: int64 = 0; i < bytes.length; i += 1) {
		if (bytes[i] < 48 || bytes[i] > 57) { return false; }
	}
	return true;
}

function unsignedValue(text: string, flag: string): Result<uint64, string> {
	let value: uint64 = 0;
	const bytes = text.asBytes();
	for (let i: int64 = 0; i < bytes.length; i += 1) {
		const digit = (bytes[i] - 48) as uint64;
		if (value > UINT64_LIMIT / RADIX ||
			(value == UINT64_LIMIT / RADIX && digit > UINT64_LIMIT % RADIX)) {
			return Result.err(flag + " value exceeds uint64");
		}
		value = value * RADIX + digit;
	}
	return Result.ok(value);
}

function ignored(token: string): boolean {
	if (IGNORED_FLAGS.indexOf(token) >= 0) { return true; }
	for (const prefix of IGNORED_PREFIXES) {
		if (token.startsWith(prefix)) { return true; }
	}
	return false;
}

// Input tokens are not file/cache attestations; the consumer must resolve
// them against cwd and require regular files under its private cache.
export function parseCoffLinkArguments(
	tokens: Readonly<Span<string>>,
	objectName: string,
): Result<CoffLinkPlan, string> {
	if (objectName == "" || objectName.indexOf("\0") >= 0) {
		return Result.err("fixture object name is empty or contains NUL");
	}
	if (tokens.length == 0) { return Result.err("link command has no linker"); }
	for (let index: int64 = 0; index < tokens.length; index += 1) {
		if (tokens[index] == "" || tokens[index].indexOf("\0") >= 0) {
			return Result.err(place(index) + "argument is empty or contains NUL");
		}
	}
	let dll = false;
	let machine = "";
	let stack: uint64 | null = null;
	let base: uint64 | null = null;
	const inputs: string[] = [];
	const notCarried: string[] = [];
	let users: int64 = 0;
	for (let index: int64 = 1; index < tokens.length; index += 1) {
		const token = tokens[index];
		if (token == "-DLL") {
			dll = true;
		} else if (token.startsWith(STACK_PREFIX) &&
			decimal(token.substring(STACK_PREFIX.length))) {
			stack = try unsignedValue(
				token.substring(STACK_PREFIX.length),
				place(index) + "-STACK",
			);
		} else if (token.startsWith(BASE_PREFIX) &&
			decimal(token.substring(BASE_PREFIX.length))) {
			base = try unsignedValue(
				token.substring(BASE_PREFIX.length),
				place(index) + "-BASE",
			);
		} else if (token.startsWith(MACHINE_PREFIX)) {
			machine = token.substring(MACHINE_PREFIX.length);
			if (machine == "") {
				return Result.err(place(index) + "-MACHINE value is empty");
			}
		} else if (token.startsWith("-ALTERNATENAME:")) {
			notCarried.push(token);
		} else if (ignored(token)) {
			continue;
		} else if (token.startsWith("-")) {
			return Result.err(place(index) + "lld-link option " + token +
				" is not understood");
		} else if (basename(token) == objectName) {
			users += 1;
		} else if (users != 1) {
			return Result.err(place(index) + "link input " + token +
				" comes before the fixture object");
		} else {
			inputs.push(token);
		}
	}
	if (users != 1) {
		return Result.err("link line names the fixture object " + objectName +
			" " + String(users) + " times");
	}
	if (base == null) { return Result.err("link line has no -BASE"); }
	if (machine == "") { return Result.err("link line has no -MACHINE"); }
	return Result.ok({ dll, machine, stack, base, inputs, notCarried });
}
