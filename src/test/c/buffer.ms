// E2E: Buffer Operations → C output
// Tests Buffer type alias, extension methods, and C extern bindings.

import { compileToC } from "../helpers";

test "E2E C: bufferAlloc" {
	const src = "import { bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(8);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferAlloc");
}

test "E2E C: bufferFrom hex" {
	const src = "import { bufferFrom } from \"std/core/buffer\";\nconst buf = bufferFrom(\"48656c6c6f\", \"hex\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferFromHex");
}

test "E2E C: bufSet extension method" {
	const src = "import { Buffer, bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(4);\nbuf.bufSet(0, 65);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferSet");
}

test "E2E C: toHex extension method" {
	const src = "import { Buffer, bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(4);\nconst hex = buf.toHex();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferToHex");
}

test "E2E C: readUInt32LE extension method" {
	const src = "import { Buffer, bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(4);\nconst v = buf.readUInt32LE(0);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferReadUint32LE");
}

test "E2E C: writeUInt32LE extension method" {
	const src = "import { Buffer, bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(4);\nbuf.writeUInt32LE(0x12345678, 0);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferWriteUint32LE");
}

test "E2E C: indexOfBuffer BMH search" {
	const src = "import { Buffer, bufferFrom } from \"std/core/buffer\";\nconst buf = bufferFrom(\"hello\", \"utf8\");\nconst needle = bufferFrom(\"ll\", \"utf8\");\nconst idx = buf.indexOfBuffer(needle, 0);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferIndexOfBuffer");
}

test "E2E C: copyTo extension method" {
	const src = "import { Buffer, bufferAlloc, bufferFrom } from \"std/core/buffer\";\nconst src = bufferFrom(\"hi\", \"utf8\");\nconst dst = bufferAlloc(2);\nsrc.copyTo(dst, 0, 0, 2);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferCopy");
}

test "E2E C: swap16 extension method" {
	const src = "import { Buffer, bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(4);\nbuf.swap16();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msBufferSwap16");
}

test "E2E C: Buffer uses string byteAt (no msBufferGet)" {
	const src = "import { Buffer, bufferAlloc } from \"std/core/buffer\";\nconst buf = bufferAlloc(4);\nconst v = buf.byteAt(0);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringByteAt");
}

test "E2E C: Buffer uses string equals (no msBufferEquals)" {
	const src = "import { Buffer, bufferFrom } from \"std/core/buffer\";\nconst a = bufferFrom(\"abc\", \"utf8\");\nconst b = bufferFrom(\"abc\", \"utf8\");\nconst eq = a.equals(b);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringEquals");
}

test "E2E C: Buffer uses string byteSlice (no msBufferSlice)" {
	const src = "import { Buffer, bufferFrom } from \"std/core/buffer\";\nconst buf = bufferFrom(\"hello\", \"utf8\");\nconst s = buf.byteSlice(0, 3);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringByteSlice");
}

test "E2E C: Buffer uses msStringConcat (no msBufferConcat)" {
	const src = "import { bufferConcat, bufferFrom } from \"std/core/buffer\";\nconst a = bufferFrom(\"hi\", \"utf8\");\nconst b = bufferFrom(\"lo\", \"utf8\");\nconst c = bufferConcat(a, b);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringConcat");
}

test "E2E C: bufferByteLength is pure MetaScript (no C call)" {
	const src = "import { bufferByteLength } from \"std/core/buffer\";\nconst n = bufferByteLength(\"hello\", \"utf8\");";
	const c = compileToC(src);
	assert c.ok;
	// Should NOT contain msBufferByteLength — it's pure MS now
	assert !c.value.contains("msBufferByteLength");
}
