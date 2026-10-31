import {
	spawn, ChildStream, platform, ProcessErrorKind, SpawnOptions,
} from "std/process";
import { wellFormedPrefix } from "std/core/string/utf8Repair";
import { wellFormedString } from "std/core/string/bytes";

export struct ToolByteResult {
	returnCode: int64;
	output: uint8[];
	errorOutput: uint8[];
}

export struct ToolTextResult {
	returnCode: int64;
	output: string;
	errorOutput: string;
}

const POLL_MS: int32 = 20;

export function captureToolBytes(
	file: string, args: string[], options: SpawnOptions = {},
): Result<ToolByteResult, string> {
	const started = spawn(file, args, options);
	if (!started.ok) { return Result.err(started.error.message); }
	const child = started.value;
	child.closeStdin();
	const output: uint8[] = [];
	const errorOutput: uint8[] = [];
	let outEnded = false;
	let errEnded = false;
	let next = ChildStream.Stdout;
	while (!outEnded || !errEnded) {
		const stream = outEnded ? ChildStream.Stderr :
			(errEnded ? ChildStream.Stdout : next);
		next = stream == ChildStream.Stdout ?
			ChildStream.Stderr : ChildStream.Stdout;
		const got = child.readBytes(stream, POLL_MS);
		if (!got.ok) {
			if (got.error.kind == ProcessErrorKind.Timeout ||
				got.error.kind == ProcessErrorKind.OutputOverflow) {
				continue;
			}
			child.close();
			return Result.err(got.error.message);
		}
		if (stream == ChildStream.Stdout) {
			for (const byte of got.value.data) { output.push(byte); }
			outEnded = got.value.ended;
		} else {
			for (const byte of got.value.data) { errorOutput.push(byte); }
			errEnded = got.value.ended;
		}
	}
	let status = child.wait(POLL_MS);
	while (!status.ok && status.error.kind == ProcessErrorKind.Timeout) {
		status = child.wait(POLL_MS);
	}
	child.close();
	if (!status.ok) { return Result.err(status.error.message); }
	const returnCode = platform == "windows" ?
		((status.value.code as uint32) as int64) :
		(status.value.signal != 0 ? -(status.value.signal as int64) :
			(status.value.code as int64));
	return Result.ok({ returnCode, output, errorOutput });
}

function decodeUtf8(
	bytes: Readonly<Span<uint8>>, stream: string,
): Result<string, string> {
	if (wellFormedPrefix(bytes, 0, false) != bytes.length) {
		return Result.err(stream + " is not UTF-8");
	}
	const text = wellFormedString(bytes);
	return Result.ok(text.replaceAll("\r\n", "\n").replaceAll("\r", "\n"));
}

export function captureToolUtf8(
	file: string, args: string[], options: SpawnOptions = {},
): Result<ToolTextResult, string> {
	const captured = captureToolBytes(file, args, options);
	if (!captured.ok) { return Result.err(captured.error); }
	const output = decodeUtf8(captured.value.output, "stdout");
	if (!output.ok) { return Result.err(output.error); }
	const errorOutput = decodeUtf8(captured.value.errorOutput, "stderr");
	if (!errorOutput.ok) { return Result.err(errorOutput.error); }
	return Result.ok({
		returnCode: captured.value.returnCode,
		output: output.value,
		errorOutput: errorOutput.value,
	});
}
