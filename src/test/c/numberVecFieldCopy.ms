import { compileToC } from "../helpers";

test "a vector of numbers in a struct copies into the destination's payload" {
	const result = compileToC(`
struct Nums { xs: Vec<int32> }
let a: Nums = { xs: [1, 2, 3] };
let b: Nums = { xs: [4, 5, 6, 7] };
b = a;
console.log(b.xs.length);
`);
	assert result.ok, result.ok ? "" : result.error;
	assert result.value.contains("msArraySetLen((*dest_p0).xs, (*src_p1).xs);"), "reuses the destination payload";
	assert result.value.contains("msArrayCopyPayload((*dest_p0).xs, (*src_p1).xs);"), "bulk copy";
}
