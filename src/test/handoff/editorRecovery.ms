import { parseSourceLenient } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { sgDetectCompletionContext, SgCompletionKind } from "../../checker/suggest";

test "editor recovery: absent declaration children do not change an earlier completion context" {
	const baseline = parseSourceLenient("conv\n");
	assert baseline.ok;
	const baselineTree = baseline.value;
	assert sgDetectCompletionContext(baselineTree, 1, 5) == SgCompletionKind.Identifier;
	const declarations = [
		"let value: uin",
		"const value: uin",
		"let value: int32",
		"let value",
		"let first: uin\nlet second: string",
	];
	for (const declaration of declarations) {
		const parsed = parseSourceLenient("conv\n" + declaration + "\n");
		assert parsed.ok, declaration;
		const tree = parsed.value;
		assert sgDetectCompletionContext(tree, 1, 5) == SgCompletionKind.Identifier, declaration;
		for (let column: int32 = 1; column <= 10; column += 1) {
			const expected = sgDetectCompletionContext(baselineTree, 1, column);
			const actual = sgDetectCompletionContext(tree, 1, column);
			assert actual == expected, declaration + " at column " + column.toString();
		}
	}
}

function contextAtMarker(marked: string): SgCompletionKind {
	const offset = marked.indexOf("$");
	const source = marked.replace("$", "");
	const before = marked.slice(0, offset).split("\n");
	const parsed = parseSourceLenient(source);
	if (!parsed.ok) {
		throw new Error(`Cannot parse boundary ${marked}: ${parsed.error}`);
	}
	return sgDetectCompletionContext(parsed.value, before.length as int32,
		(before[before.length - 1].length + 1) as int32, source);
}

test "typed declarations keep initializer whitespace and same-line function bodies in value context" {
	const sources = [
		"function make(): Box { return m$kBox(); }",
		"const b: Box = m$kBox();",
		"const b: Box = $  mkBox();",
		"const b: Box = /* value */ $mkBox();",
		"const b: Box = mkBox(); $const next = 1;",
		"function make(): Box {$ return mkBox(); }",
	];
	for (const source of sources) {
		assert contextAtMarker(source) == SgCompletionKind.Identifier, source;
	}
}

test "type completion retains partial annotations, colon gaps and trailing trivia" {
	const sources = [
		"type Alias = $Box;",
		"type Alias = $ Box;",
		"const b: B$ox = mkBox();",
		"let b: Bo$",
		"const b: Box  $ = mkBox();",
		"const b: $Box = mkBox();",
		"const b: /* type */ $Bo = mkBox();",
		"function make(): B$ox { return mkBox(); }",
		"const b:\n Bo$ = mkBox();",
	];
	for (const source of sources) {
		assert contextAtMarker(source) == SgCompletionKind.TypeAnnotation, source;
	}
}
