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
