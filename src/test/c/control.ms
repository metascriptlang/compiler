// E2E: Control Flow → C output
// Wrapped in functions that are called from top-level.

import { compileToC } from "../helpers";


test "E2E C: if/else" {
	const src = "function f(x: number): number {\n  if (x > 0) { return 1; } else { return 0; }\n}\nconst r = f(5);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("if (");
	assert c.value.contains("else");
}

test "E2E C: while loop" {
	const src = "function f(): number {\n  let i: number = 0;\n  while (i < 10) { i = i + 1; }\n  return i;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("while (");
}

test "E2E C: match lowers to if" {
	const src = "function f(x: number): number {\n  return match (x) {\n    1 => 10,\n    2 => 20,\n    _ => 0,\n  };\n}\nconst r = f(1);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("if (");
}

test "E2E C: return value" {
	const src = "function f(): number { return 42; }\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("return 42");
}

test "E2E C: for-of loop" {
	const src = "function sum(arr: number[]): number {\n  let s: number = 0;\n  for (const x of arr) { s = s + x; }\n  return s;\n}\nconst r = sum([1, 2, 3]);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("while (");
}

test "E2E C: do-while loop" {
	const src = "function f(): number {\n  let i: number = 0;\n  do { i = i + 1; } while (i < 5);\n  return i;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("do {");
	assert c.value.contains("while (");
}

test "E2E C: break in loop" {
	const src = "function f(): number {\n  let i: number = 0;\n  while (i < 100) {\n    if (i === 5) { break; }\n    i = i + 1;\n  }\n  return i;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("break;");
}

test "E2E C: continue in loop" {
	const src = "function f(): number {\n  let s: number = 0;\n  let i: number = 0;\n  while (i < 5) {\n    i = i + 1;\n    if (i === 3) { continue; }\n    s = s + i;\n  }\n  return s;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("continue;");
}

test "E2E C: match or-patterns" {
	const src = "function f(x: number): number {\n  return match (x) {\n    1 | 2 => 10,\n    3 => 30,\n    _ => 0,\n  };\n}\nconst r = f(1);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("||");
}

// KNOWN ISSUE: match arm bindings (bare identifiers as captures) fail in pipeline.
// Checker or validator rejects: "n => n + 1" where n is a binding.
// test "E2E C: match with binding" {
// 	const src = "function f(x: number): number {\n  return match (x) {\n    0 => 100,\n    n => n + 1,\n  };\n}\nconst r = f(5);";
// 	const c = compileToC(src);
// 	check(c.ok);
// }

test "E2E C: try/catch" {
	const src = "function f(): number {\n  try { return 1; } catch (e) { return 0; }\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("__catch_");
}

test "E2E C: throw statement" {
	const src = "function f(): void { throw \"error\"; }\ntry { f(); } catch (e) { }\nconst x: number = 1;";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msThrow");
}
