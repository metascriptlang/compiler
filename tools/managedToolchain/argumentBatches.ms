import { utf8StepAt } from "std/core/string/utf8Repair";

export const WINDOWS_COMMAND_LINE_UNITS: int32 = 32767;

const TAB: int32 = 9;
const SPACE: int32 = 32;
const QUOTE: int32 = 34;
const SLASH: int32 = 47;
const BACKSLASH: int32 = 92;

// Must track direct-argv CRT quoting in runtime/process.h.
function tokenUnits(
	text: string,
	isExecutable: boolean,
): Result<int64, string> {
	const data = text.asBytes();
	let plain: int64 = 0;
	let quoted: int64 = 0;
	let backslashes: int64 = 0;
	let special = data.length == 0;
	let at: int64 = 0;
	while (at < data.length) {
		const length = utf8StepAt(data, at, false);
		if (length < 0) { return Result.err("is not well-formed text"); }
		let code = data[at] as int32;
		if (code == 0) { return Result.err("contains NUL"); }
		if (isExecutable && code == SLASH) { code = BACKSLASH; }
		const units: int64 = length == 4 ? 2 : 1;
		plain += units;
		if (code == BACKSLASH) {
			backslashes += 1;
		} else if (code == QUOTE) {
			quoted += backslashes * 2 + 2;
			backslashes = 0;
			special = true;
		} else {
			quoted += backslashes + units;
			backslashes = 0;
			if (code == SPACE || code == TAB) { special = true; }
		}
		at += length;
	}
	quoted += backslashes * 2;
	return Result.ok(special ? quoted + 2 : plain);
}

export function batchArguments(
	executable: string,
	prefix: string[],
	members: string[],
	limit: int32 = WINDOWS_COMMAND_LINE_UNITS,
): Result<string[][], string> {
	if (limit < 1 || limit > WINDOWS_COMMAND_LINE_UNITS) {
		return Result.err(
			"limit must be between 1 and " +
				String(WINDOWS_COMMAND_LINE_UNITS) + ": " + String(limit),
		);
	}
	if (executable == "") { return Result.err("executable is empty"); }
	const executableUnits = tokenUnits(executable, true);
	if (!executableUnits.ok) {
		return Result.err("executable " + executableUnits.error);
	}
	let fixed: int64 = executableUnits.value + 1;
	for (let i: int32 = 0; i < prefix.length; i += 1) {
		const units = tokenUnits(prefix[i], false);
		if (!units.ok) {
			return Result.err("prefix[" + String(i) + "] " + units.error);
		}
		fixed += 1 + units.value;
	}
	if (fixed > limit) {
		return Result.err(
			"fixed command line needs " + String(fixed) +
				" units, limit is " + String(limit),
		);
	}
	const costs: int64[] = [];
	for (let i: int32 = 0; i < members.length; i += 1) {
		const units = tokenUnits(members[i], false);
		if (!units.ok) {
			return Result.err("members[" + String(i) + "] " + units.error);
		}
		if (fixed + 1 + units.value > limit) {
			return Result.err(
				"members[" + String(i) + "] does not fit: needs " +
					String(fixed + 1 + units.value) +
					" units, limit is " + String(limit),
			);
		}
		costs.push(1 + units.value);
	}
	const batches: string[][] = [];
	let current: string[] = [];
	let used = fixed;
	for (let i: int32 = 0; i < members.length; i += 1) {
		if (used + costs[i] > limit) {
			batches.push(current);
			current = [];
			used = fixed;
		}
		current.push(members[i]);
		used += costs[i];
	}
	if (current.length > 0) { batches.push(current); }
	return Result.ok(batches);
}
