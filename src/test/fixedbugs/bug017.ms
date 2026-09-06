// bug017 — ArrowFunction / FunctionExpr stored to const failed when called
//
// Symptom:    A function literal assigned to a `const` (without a type
//             annotation on the LHS and without a contextual callback
//             type from a callee param) couldn't be called — the C
//             backend emitted a direct call against the value's
//             `msClosure` struct and rejected it:
//                 "called object type 'msClosure' is not a function or
//                  function pointer"
//             Both syntactic forms hit it:
//                 const f = function(): string { return "x"; };
//                 const f = () => "x";
//             Two existing escape valves did keep working — they cover
//             the cases where downstream contextual conversion gave the
//             value a CcClosure type along the way:
//                 const f: () => string = () => "x";   // LHS annotation
//                 takeCb(() => "x");                    // callback arg
//
// Root cause: `checkAnonymousFunction` (src/checker/checkExprPass.ms)
//             handles both ArrowFunction and FunctionExpr expression
//             forms and built the result with `createFunction(...)` —
//             which leaves `callConv = CcDefault`. That convention is
//             correct only for *named* function declarations whose call
//             sites resolve to a raw C function pointer. Inline,
//             expression-form function literals are *value-form*
//             functions: at runtime they are closure pairs `{fn, env}`
//             and call sites must dispatch through the closure ABI.
//             The checker's "this is a closure call" decision (~line
//             1971) keys off `callConv === CcClosure`; without that
//             flag, `isDirectCall` stayed true and codegen emitted a
//             raw call against the msClosure struct.
//
// Fix:        Switch all four return paths in `checkAnonymousFunction`
//             from `createFunction` to `createClosureType`. The latter
//             is the helper that already exists exactly for this case
//             (see types.ms:197 — same Function shape, callConv flipped
//             to CcClosure). Sibling fix to Bug 5b which extended
//             closureCallMarker for ArrayAccess callees: both align
//             with "dispatch by callee TYPE, not syntax" — the type now
//             carries the right convention from the moment the
//             expression is checked, no downstream patching needed.

test "bug017: const = function(): T { ... } can be called" {
	const myFn = function(): string {
		return "fn-expr";
	};
	const got = myFn();
	assert got == "fn-expr";
}

test "bug017: const = () => T can be called (no annotation)" {
	const myFn = () => "arrow";
	const got = myFn();
	assert got == "arrow";
}

test "bug017: const arrow with multiple params" {
	const add = (a: int32, b: int32): int32 => (a + b) as int32;
	assert add(3, 4) == 7;
}

test "bug017: const arrow capturing outer let" {
	let counter: int32 = 0;
	const bump = () => { counter = counter + 1; };
	bump();
	bump();
	bump();
	assert counter == 3;
}

// Regression guards — pre-existing forms that already worked must stay working.

test "bug017: LHS-annotated const arrow still works" {
	const myFn: () => string = () => "lhs";
	assert myFn() == "lhs";
}

function takeCb(cb: () => string): string {
	return cb();
}

test "bug017: arrow as callback arg still works" {
	assert takeCb(() => "callback") == "callback";
}
