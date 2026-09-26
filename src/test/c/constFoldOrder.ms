import { compileToC } from "../helpers";

test "an int64-minimum constant folds at a use written before its declaration" {
	const result = compileToC("function above(v: int64): boolean { return v > MIN; }\nconst MIN: int64 = -9223372036854775808;\nconst ok = above(5);");
	assert result.ok;
	assert result.value.contains("return (v > (-9223372036854775807LL - 1LL));");
}

test "an int32-minimum constant folds at a use written before its declaration" {
	const result = compileToC("function above(v: int32): boolean { return v > MIN; }\nconst MIN: int32 = -2147483648;\nconst ok = above(5);");
	assert result.ok;
	assert result.value.contains("return (v > (-2147483647 -1));");
}
