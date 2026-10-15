// Checker — a static field or static block of a generic class cannot name the class's type parameter

import { strictErrorCount, hasError } from "./helpers";

const NO_STATIC_T = "a static member cannot reference the class type parameter 'T'";

test "a static field type, initializer or block naming T is refused" {
	assert hasError("class Box<T> { static seed: T; }", NO_STATIC_T);
	assert hasError("class Box<T> { static seeds: T[] = []; }", NO_STATIC_T);
	assert hasError("class Box<T> { static seed = (null as T | null); }", NO_STATIC_T);
	assert hasError("class Box<T> { static { const x: T[] = []; } }", NO_STATIC_T);
	assert hasError("class Box<K, T> { static seed: Map<K, T> | null = null; }", NO_STATIC_T);
}

test "statics that do not name T, and static methods, stay accepted" {
	assert strictErrorCount("class Box<T> { static hits: int32 = 0; v: T; constructor(v: T) { this.v = v; } }") == 0;
	assert strictErrorCount("class Box<T> { v: T; constructor(v: T) { this.v = v; } static make(v: T): Box<T> { return new Box<T>(v); } }") == 0;
}
