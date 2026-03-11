import { compileToC } from "../helpers";

test "diag: if/else output" {
	const src = "function f(x: number): number {\n  if (x > 0) { return 1; } else { return 0; }\n}\nconst r = f(5);";
	const c = compileToC(src);
	assert c.ok;
	console.log("has if: " + c.value.contains("if (").toString());
	console.log("has else: " + c.value.contains("else").toString());
	console.log("=== OUTPUT ===");
	console.log(c.value);
}
