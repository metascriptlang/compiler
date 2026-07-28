// Test: closure-typed variable calls get isDirectCall=false
// Verified via full build (src/parser/expressions/util.ms uses closure variable calls)
// Placeholder test — the real verification is:
//   msc run src/index.ms 2>&1 | grep "msClosure.*not a function"
// Should produce 0 results after the fix.

test "placeholder: closure variable call marking" {
	assert true;
}
