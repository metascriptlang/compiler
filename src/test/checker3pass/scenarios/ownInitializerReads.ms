import { checkOnly } from "../helpers";

const BOX = `
interface Box { read: () => int32; value: int32; }
function run(f: () => int32): int32 { return f(); }
`;

function errorsOf(body: string): string {
	return checkOnly(BOX + body).errors.join("\n");
}

test "a function held by the literal reads the annotated binding it initializes" {
	const local = errorsOf(`function make(): Box { const box: Box = { read: (): int32 => box.value, value: 7 }; return box; }`);
	assert local == "", "a local object literal must check: " + local;
	const list = errorsOf(`function make(): int32 { const fs: (() => int32)[] = [(): int32 => fs.length]; return fs[0](); }`);
	assert list == "", "a local array literal must check: " + list;
	const nested = errorsOf(`function make(): Box { let box: Box = { read: (): int32 => { const g = (): int32 => box.value; return g(); }, value: 7 }; return box; }`);
	assert nested == "", "a closure nested in a held closure must check: " + nested;
}

test "a read that runs while the binding is initialized stays refused" {
	const direct = errorsOf(`function make(): int32 { const box: Box = { read: (): int32 => 1, value: box.value }; return box.value; }`);
	assert direct.contains("Block-scoped variable 'box' used before its declaration"), "a direct read must be refused: " + direct;
	const iife = errorsOf(`function make(): int32 { const box: Box = { read: (): int32 => 1, value: ((): int32 => box.value)() }; return box.value; }`);
	assert iife.contains("Block-scoped variable 'box' used before its declaration"), "a read in an invoked closure must be refused: " + iife;
	const called = errorsOf(`function make(): int32 { const box: Box = { read: (): int32 => box.value, value: run((): int32 => box.value) }; return box.value; }`);
	assert called.contains("'box' is read by a function that can run while 'box' is still being initialized"), "a closure passed to a call must be refused: " + called;
}

test "an unannotated binding read by its literal's function asks for its type" {
	const text = errorsOf(`function make(): int32 { const box = { read: (): int32 => box.value, value: 7 }; return box.read(); }`);
	assert text.contains("cannot infer the type of 'box': its own initializer reads it; annotate the type of 'box'"), "an unannotated binding must be refused with its rule: " + text;
}
