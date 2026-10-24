import { lspParseContentLength } from "./protocol";
import { readLine, readBytes, writeStdout, stdinHasData } from "std/io";

export interface LspTransport {
	readLine: () => string;
	readBytes: (count: int32) => string;
	hasBufferedData: () => boolean;
	write: (frames: string) => void;
}

export function stdioTransport(): LspTransport {
	return {
		readLine: () => readLine(),
		readBytes: (count: int32) => readBytes(count as number),
		hasBufferedData: () => stdinHasData(),
		write: (frames: string) => writeStdout(frames),
	};
}

export enum FrameEnd {
	Closed,
	Truncated,
}

export function lspReadFrame(io: LspTransport): Result<string, FrameEnd> {
	let contentLength = -1;
	while (contentLength < 0) {
		const line = io.readLine();
		if (line.byteLength == 0) return Result.err(FrameEnd.Closed);
		contentLength = lspParseContentLength(line);
	}
	let separator = io.readLine();
	while (separator.byteLength > 0) separator = io.readLine();
	const body = contentLength == 0 ? "" : io.readBytes(contentLength);
	if (body.byteLength == 0) return Result.err(FrameEnd.Closed);
	if (body.byteLength < contentLength) return Result.err(FrameEnd.Truncated);
	return Result.ok(body);
}

export function lspSplitFrames(output: string): string[] {
	const bodies: string[] = [];
	let pos: int32 = 0;
	while (pos < output.byteLength) {
		const headerEnd = output.byteIndexOf("\r\n\r\n", pos);
		if (headerEnd < 0) throw new Error("frame without header end at byte " + pos);
		const size = lspParseContentLength(output.byteSlice(pos, headerEnd));
		const bodyStart = headerEnd + 4;
		if (size < 0 || bodyStart + size > output.byteLength) {
			throw new Error("frame length " + size + " overruns output at byte " + pos);
		}
		bodies.push(output.byteSlice(bodyStart, bodyStart + size));
		pos = bodyStart + size;
	}
	return bodies;
}

// ===== In-memory pipe =====

export class MemoryWire {
	chunks: string[];
	nextChunk: int32;
	input: string;
	pos: int32;
	output: string;
	lateChunk: string;
	lateAfterChunks: int32;
	lateAtEmptyProbe: int32;
	emptyProbes: int32;
}

export function createMemoryWire(chunks: string[]): MemoryWire {
	return { chunks, nextChunk: 0, input: "", pos: 0, output: "", lateChunk: "", lateAfterChunks: 0, lateAtEmptyProbe: 0, emptyProbes: 0 };
}

// Input that appears while the server works: once afterChunks chunks have been read, the
// atEmptyProbe-th hasBufferedData call that finds nothing buffered finds lateChunk.
export function createLateInputWire(chunks: string[], lateChunk: string, afterChunks: int32, atEmptyProbe: int32): MemoryWire {
	const wire = createMemoryWire(chunks);
	wire.lateChunk = lateChunk;
	wire.lateAfterChunks = afterChunks;
	wire.lateAtEmptyProbe = atEmptyProbe;
	return wire;
}

function wireHasBufferedData(wire: MemoryWire): boolean {
	if (wire.pos < wire.input.byteLength) return true;
	if (wire.nextChunk < wire.lateAfterChunks) return false;
	wire.emptyProbes++;
	if (wire.emptyProbes != wire.lateAtEmptyProbe) return false;
	wire.input = wire.lateChunk;
	wire.pos = 0;
	return true;
}

function deliverChunk(wire: MemoryWire): boolean {
	if (wire.nextChunk >= wire.chunks.length) return false;
	wire.input = wire.input.byteSlice(wire.pos, wire.input.byteLength) + wire.chunks[wire.nextChunk];
	wire.pos = 0;
	wire.nextChunk++;
	return true;
}

function wireReadLine(wire: MemoryWire): string {
	let newline = wire.input.byteIndexOf("\n", wire.pos);
	while (newline < 0) {
		if (!deliverChunk(wire)) {
			const rest = wire.input.byteSlice(wire.pos, wire.input.byteLength);
			wire.pos = wire.input.byteLength;
			return rest;
		}
		newline = wire.input.byteIndexOf("\n", wire.pos);
	}
	let end = newline;
	if (end > wire.pos && wire.input.byteAt(end - 1) == 13) end--;
	const line = wire.input.byteSlice(wire.pos, end);
	wire.pos = newline + 1;
	return line;
}

function wireReadBytes(wire: MemoryWire, count: int32): string {
	while (wire.input.byteLength - wire.pos < count && deliverChunk(wire)) {}
	const end = wire.pos + count < wire.input.byteLength ? wire.pos + count : wire.input.byteLength;
	const bytes = wire.input.byteSlice(wire.pos, end);
	wire.pos = end;
	return bytes;
}

export function memoryTransport(wire: MemoryWire): LspTransport {
	return {
		readLine: () => wireReadLine(wire),
		readBytes: (count: int32) => wireReadBytes(wire, count),
		hasBufferedData: () => wireHasBufferedData(wire),
		write: (frames: string) => { wire.output += frames; },
	};
}

// ===== Tests =====

function frame(body: string): string {
	return "Content-Length: " + body.byteLength + "\r\n\r\n" + body;
}

test "frame read counts body bytes, not UTF-16 units" {
	const first = "{\"text\":\"é😀\"}";
	const wire = createMemoryWire([frame(first) + frame("{}")]);
	const io = memoryTransport(wire);
	const a = lspReadFrame(io);
	assert a.ok;
	if (a.ok) assert a.value == first;
	assert io.hasBufferedData();
	const b = lspReadFrame(io);
	assert b.ok;
	if (b.ok) assert b.value == "{}";
	assert !io.hasBufferedData();
	const end = lspReadFrame(io);
	assert !end.ok;
	if (!end.ok) assert end.error == FrameEnd.Closed;
}

test "late input appears at the chosen empty probe once enough chunks were read" {
	const wire = createLateInputWire([frame("{\"a\":1}")], frame("{\"b\":2}"), 1, 2);
	const io = memoryTransport(wire);
	assert !io.hasBufferedData();
	const a = lspReadFrame(io);
	assert a.ok;
	assert !io.hasBufferedData();
	assert io.hasBufferedData();
	const b = lspReadFrame(io);
	assert b.ok;
	if (b.ok) assert b.value == "{\"b\":2}";
	assert !io.hasBufferedData();
}

test "frame read skips other headers and blocks across chunks" {
	const body = "{\"a\":1}";
	const wire = createMemoryWire([
		"Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Len",
		"gth: " + body.byteLength + "\r\n\r\n{\"a\"",
		":1}",
	]);
	const io = memoryTransport(wire);
	const r = lspReadFrame(io);
	assert r.ok;
	if (r.ok) assert r.value == body;
}

test "frame read reports a body cut short by EOF as truncated" {
	const io = memoryTransport(createMemoryWire(["Content-Length: 40\r\n\r\n{\"id\":1}"]));
	const r = lspReadFrame(io);
	assert !r.ok;
	if (!r.ok) assert r.error == FrameEnd.Truncated;
}

test "split frames uses byte lengths for multibyte bodies" {
	const bodies = lspSplitFrames(frame("{\"id\":\"é\"}") + frame("{\"id\":\"😀\"}"));
	assert bodies.length == 2;
	assert bodies[0] == "{\"id\":\"é\"}";
	assert bodies[1] == "{\"id\":\"😀\"}";
}
