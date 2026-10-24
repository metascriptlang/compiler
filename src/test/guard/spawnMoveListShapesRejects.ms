// The spawn { move } list refuses every shape it cannot turn into a sole-owner move
//
// INVARIANT (ULTRALOCK V2): spawn options are an object literal whose `move` is an array of
//   local names in scope, and a moved name is declared in the function that spawns, so that
//   function can prove it owns the only reference.
//
// WHAT IT CATCHES: the move-list refusals that paralockSpawnMoveRejects does not name: options
//   that are not a literal, a `move` that is not an array, a name with no binding, and a binding
//   declared in an enclosing function (PARALOCK E148).
//
// RED MEANS: one of the four refusals stopped firing, or was retagged.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn options must be an object literal
// GUARD-CHECK-FAIL spawn { move } takes an array of local names
// GUARD-CHECK-FAIL cannot move 'ghost': no such binding in scope
// GUARD-CHECK-FAIL cannot move 'outerCounter': it is declared outside the enclosing function

interface Counter { n: int32; }

function optionsNotLiteral(): int32 {
	const o = { timeout: 5 };
	const f = spawn(() => 1, o); // GUARD-REFUSED
	return await f;
}

function moveNotArray(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => c.n, { move: c }); // GUARD-REFUSED
	return await f;
}

function moveUnknownName(): int32 {
	const f = spawn(() => 1, { move: [ghost] }); // GUARD-REFUSED
	return await f;
}

function movedFromOuter(): int32 {
	const outerCounter: Counter = { n: 0 };
	function inner(): int32 {
		const f = spawn(() => outerCounter.n, { move: [outerCounter] }); // GUARD-REFUSED
		return await f;
	}
	return inner();
}

console.log(await optionsNotLiteral());
console.log(await moveNotArray());
console.log(await moveUnknownName());
console.log(movedFromOuter());
