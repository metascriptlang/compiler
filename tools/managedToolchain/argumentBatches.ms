// Splits the member arguments of one native tool call (llvm-strip, llvm-ar)
// into ordered batches whose Windows command line fits CreateProcessW.
//
// The command line is the one `msProcessSpawnSyncArgv` builds: the executable
// token with every `/` turned into `\`, then each argument, each token quoted
// by `_msAppendWinArg` (quote only when it holds a space, tab or `"`, or is
// empty), separated by one space, converted from UTF-8 to UTF-16. The
// converted text plus its terminating NUL must not exceed 32767 UTF-16 units.
// The count here is exact for that builder; the OS limit itself is the
// documented CreateProcessW one, not measured here.

export const WINDOWS_COMMAND_LINE_UNITS: int32 = 32767;

const TAB: int32 = 9;
const SPACE: int32 = 32;
const QUOTE: int32 = 34;
const SLASH: int32 = 47;
const BACKSLASH: int32 = 92;

function isContinuation(text: string, at: int32): boolean {
	const code = text.byteAt(at);
	return code >= 0x80 && code <= 0xBF;
}

// Byte length of the well-formed UTF-8 sequence at `at`, or 0 when it is
// ill-formed. Encoded surrogates are ill-formed: the Windows conversion would
// replace them, so their UTF-16 count would not match the string's.
function sequenceLength(text: string, at: int32): int32 {
	const lead = text.byteAt(at);
	if (lead >= 0 && lead < 0x80) { return 1; }
	let low: int32 = 0x80;
	let high: int32 = 0xBF;
	let length: int32 = 0;
	if (lead >= 0xC2 && lead <= 0xDF) {
		length = 2;
	} else if (lead >= 0xE0 && lead <= 0xEF) {
		length = 3;
		if (lead == 0xE0) { low = 0xA0; }
		if (lead == 0xED) { high = 0x9F; }
	} else if (lead >= 0xF0 && lead <= 0xF4) {
		length = 4;
		if (lead == 0xF0) { low = 0x90; }
		if (lead == 0xF4) { high = 0x8F; }
	} else {
		return 0;
	}
	const second = text.byteAt(at + 1);
	if (second < low || second > high) { return 0; }
	for (let i: int32 = 2; i < length; i += 1) {
		if (!isContinuation(text, at + i)) { return 0; }
	}
	return length;
}

// UTF-16 units of one token as `_msAppendWinArg` writes it. Inside quotes a
// backslash run is doubled before a `"` (which also gains its own `\`) and at
// the end of the token, and is kept as is before anything else.
function tokenUnits(
	text: string,
	isExecutable: boolean,
): Result<int64, string> {
	const size = text.byteLength();
	let plain: int64 = 0;
	let quoted: int64 = 0;
	let backslashes: int64 = 0;
	let special = size == 0;
	let at: int32 = 0;
	while (at < size) {
		const length = sequenceLength(text, at);
		if (length == 0) { return Result.err("is not well-formed text"); }
		let code = text.byteAt(at);
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

// Batches of `members`, in order, each member in exactly one batch and never
// split. A caller runs `[...prefix, ...batch]` once per batch with
// `executable`. Every batch is filled while it fits `limit` (units including
// the NUL), so the batch count is the minimum for that order. Nothing is
// returned when the limit is out of range, the executable is empty, any
// argument is not well-formed text or holds NUL, the executable and prefix
// alone exceed `limit`, or one member alone with them does. An empty `members`
// gives no batch, which means no call.
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
