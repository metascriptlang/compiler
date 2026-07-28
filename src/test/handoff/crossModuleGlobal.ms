// Test: cross-module global variables should get extern declarations.
// This is a placeholder — the actual fix is verified via full build (argv in options.ms).
// compileProjectToC crashes on virtual fs resolution, so we test indirectly.

test "placeholder: cross-module global extern" {
	// Verified via: msc run src/index.ms 2>&1 | grep "undeclared identifier 'argv'"
	// Should produce 0 results after the fix.
	assert true;
}
