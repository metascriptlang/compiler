const SPACE: uint8 = 32;
const TAB: uint8 = 9;
const QUOTE: uint8 = 34;
const DOT: uint8 = 46;
const BACKSLASH: uint8 = 92;

function needsQuotes(bytes: Readonly<Span<uint8>>): boolean {
	if (bytes.length == 0) return true;
	for (const b of bytes) {
		if (b == SPACE || b == TAB || b == QUOTE) return true;
	}
	return false;
}

// One argument as the Microsoft C runtime parses it back: quoted when it holds a space, tab or
// quote or is empty; a quote becomes \" and the backslashes before a quote or the closing quote double.
export function windowsArg(arg: string): string {
	const bytes = arg.asBytes();
	if (!needsQuotes(bytes)) return arg;
	const n = bytes.length;
	let out = "\"";
	let i = 0;
	while (i < n) {
		let slashes = 0;
		while (i < n && bytes[i] == BACKSLASH) {
			slashes += 1;
			i += 1;
		}
		if (i == n) {
			out += "\\".repeat(slashes * 2);
			break;
		}
		if (bytes[i] == QUOTE) {
			out += "\\".repeat(slashes * 2 + 1) + "\"";
			i += 1;
			continue;
		}
		out += "\\".repeat(slashes);
		const start = i;
		while (i < n && bytes[i] != BACKSLASH && bytes[i] != QUOTE) i += 1;
		out += arg.byteSlice(start, i);
	}
	return out + "\"";
}

export function quotedCommandLine(first: string, args: Readonly<string[]>): string {
	let line = windowsArg(first);
	for (const arg of args) line += " " + windowsArg(arg);
	return line;
}

// CreateProcessW resolves the first token without normalizing slashes, so the program's turn to backslashes.
export function windowsCommandLine(path: string, args: Readonly<string[]>): string {
	return quotedCommandLine(path.replaceAll("/", "\\"), args);
}

// A .bat or .cmd runs through cmd.exe, which re-parses its arguments: refused rather than quoted.
// Trailing spaces and dots are dropped first, as Windows drops them when it opens the file.
export function runsThroughCmd(path: string): boolean {
	const bytes = path.asBytes();
	let n = bytes.length;
	while (n > 0 && (bytes[n - 1] == SPACE || bytes[n - 1] == DOT)) n -= 1;
	if (n < 4 || bytes[n - 4] != DOT) return false;
	const ext = path.byteSlice(n - 3, n).toLowerCase();
	return ext == "bat" || ext == "cmd";
}

test "an argument without space, tab or quote passes verbatim" {
	assert windowsArg("out/debug/hello.exe") == "out/debug/hello.exe";
}

test "quotes, backslashes before a quote and trailing backslashes follow the CRT rules" {
	const cases = [
		["", "\"\""],
		["a b", "\"a b\""],
		["say \"hi\"", "\"say \\\"hi\\\"\""],
		["C:\\dir with space\\", "\"C:\\dir with space\\\\\""],
		["a\\\\\"b c", "\"a\\\\\\\\\\\"b c\""],
		["a\\b c", "\"a\\b c\""],
	];
	for (const c of cases) assert windowsArg(c[0]) == c[1];
}

test "the program token turns slashes to backslashes" {
	assert windowsCommandLine("C:/tools/zig.exe", ["cc", "-o", "a b.exe"]) == "C:\\tools\\zig.exe cc -o \"a b.exe\"";
}

test "a batch file is recognised through case, trailing dots and spaces" {
	assert runsThroughCmd("C:\\x.bat");
	assert runsThroughCmd("C:\\Y.CMD. ");
	assert !runsThroughCmd("C:\\x.exe");
	assert !runsThroughCmd("bat");
}
