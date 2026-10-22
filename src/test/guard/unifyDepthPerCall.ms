// nim-guard: concurrent unifications keep their recursion depth to themselves
//
// INVARIANT: the depth bound of one unification lives in that call's own
//   state, as a type comparison carries its recursion counter in the closure
//   it is passed, so two threads unifying at once never see each other's depth.
//
// WHAT IT CATCHES: a module-level depth counter read-modify-written by every
//   emit worker. The pair nests 18 deep, two levels under the bound of 20, so
//   one other thread's descent counted into a shared counter pushes this one
//   past the bound and it returns before it binds anything.
//
// RED MEANS: unifyType keeps its depth outside the bindings it is given.

import { Type, TypeKind } from "../../../std/meta/node";
import {
	createArray, createGenericParam, createUnifyBindings, numberType, setConcurrentTypeQueries,
	unifyType,
} from "../../checker/types";

function nested(leaf: Type, depth: int32): Type {
	let t = leaf;
	for (let i = 0; i < depth; i += 1) t = createArray(t);
	return t;
}

const formal = nested(createGenericParam("T"), 18);
const concrete = nested(numberType(), 18);

function unifyRounds(rounds: int32): int32 {
	let bound = 0;
	for (let i = 0; i < rounds; i += 1) {
		const b = createUnifyBindings();
		unifyType(formal, concrete, b);
		if (b.names.length == 1 && b.types[0].kind == TypeKind.Number) bound += 1;
	}
	return bound;
}

function main(): void {
	setConcurrentTypeQueries(true);
	const futures: Promise<int32>[] = [];
	for (let i = 0; i < 8; i += 1) futures.push(spawn(() => unifyRounds(20000)));
	const results = await Promise.all(futures);
	let bound = 0;
	for (const r of results) bound += r;
	setConcurrentTypeQueries(false);
	if (bound != 160000) throw "unifications that bound nothing: " + (160000 - bound);
	if (unifyRounds(1) != 1) throw "a later unification binds nothing";
	console.log("GUARD-OK");
}

main();
