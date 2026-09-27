// bug563 — a deeply nested type was refused as not assignable to itself
//
// Symptom:    an array nested 32 deep passed to a slot of the same type reported "Type 'int32[]…' is not
//             assignable to type 'int32[]…' — memory layout differs"; the guard genericInstantiationAtLimit
//             (50 nested instantiations, one array layer each) stopped building.
// Root cause: the relations answer "no" at RELATION_MAX_DEPTH frames, and an array layer costs two frames,
//             so 64 frames refused any array deeper than 31 layers.
// Fix:        the depth covers the 50 nested instantiations the checker admits (256 frames).

import { errorCount } from "../handoff/helpers";

function nested(depth: int32): string {
	let t = "int32";
	for (let i = 0; i < depth; i += 1) t = t + "[]";
	return t;
}

function sameTypeRoundTrip(depth: int32): string {
	const t = nested(depth);
	return "function id(x: " + t + "): " + t + " { return x; }\nfunction g(y: " + t + "): " + t + " { const z: " + t + " = id(y); return z; }\n";
}

test "bug563: an array nested 50 deep is comparable to itself" {
	assert errorCount(sameTypeRoundTrip(50)) == 0;
}

test "bug563: an array nested 100 deep is comparable to itself" {
	assert errorCount(sameTypeRoundTrip(100)) == 0;
}

test "bug563: arrays of different depth stay refused" {
	assert errorCount("function f(x: " + nested(40) + "): " + nested(41) + " { return x; }\n") == 1;
}
