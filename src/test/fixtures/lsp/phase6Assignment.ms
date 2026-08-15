// Phase 6 — assignment narrowing.
//
// After `x = <rhs>`, the flow graph walking sees an Assignment node and
// returns the RHS's type (constrained to a variant of the declared type).
// `constrainToDeclared` keeps non-union declared types unchanged so
// branching reassignments don't produce noisy join unions. Union-declared
// types narrow to the specific variant.
//
// This example demonstrates the algorithm using plain strings — assignment
// narrowing is uniformly applied to every declared-type path in the flow
// graph and doesn't require union-specific machinery to exercise.

function describe(): string {
	let label = "initial";
	label = "updated";
	// After the reassignment, `label` is still typed as string — assignment
	// narrowing reports the RHS type (string), constrainToDeclared confirms
	// it matches the declared type, and returns string unchanged.
	return label + " value";
}

function appendAll(): string {
	let result = "";
	let i = 0;
	while (i < 3) {
		result = result + i.toString();
		i = i + 1;
	}
	// Assignment narrowing in a loop body must converge with the declared
	// type at the loop back-edge. The fixed-point loop in flow.ms handles
	// this: the back-edge type unioned with the pre-loop type stabilizes.
	return result;
}

function main(): int32 {
	console.log(describe());
	console.log(appendAll());
	return 0;
}

main();
