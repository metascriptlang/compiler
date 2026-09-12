// Route 15g: Checker — a literal meeting a union formal is typed from the union's sole member of its kind

import { strictErrorCount } from "./helpers";

const SETTER = "type Setter<T> = (v: T | ((prev: T) => T)) => void;\n";

test "an unannotated arrow is typed from the sole function member of a union formal" {
	assert strictErrorCount("function take(v: int32 | ((prev: int32) => int32)): int32 { return 1; }\ntake(c => c + 1);") == 0;
}

test "an array literal is typed from the sole array member of a union formal" {
	assert strictErrorCount("function take(v: number[] | ((prev: number[]) => number[])): int32 { return 1; }\ntake([1, 2]);\ntake([]);") == 0;
}

test "an object literal is typed from the sole struct member of a union formal" {
	assert strictErrorCount("interface Point { x: int32; }\nfunction take(v: Point | ((prev: Point) => Point)): int32 { return 1; }\ntake({ x: 1 });") == 0;
}

test "the value-or-updater setter alias accepts literals of both shapes" {
	assert strictErrorCount(SETTER + "const s: Setter<number[]> = (v) => {};\ns([1, 2]);\ns(p => [p.length]);") == 0;
	assert strictErrorCount(SETTER + "const s: Setter<int32> = (v) => {};\ns(4);\ns(c => c * 2);") == 0;
}

test "a union with two function members gives an unannotated arrow no contextual type" {
	assert strictErrorCount("function take(v: (() => int32) | ((p: int32) => int32)): int32 { return 1; }\ntake(c => c + 1);") == 1;
}

test "a nullable array formal still types the literal from the array member" {
	assert strictErrorCount("function take(v: number[] | null): int32 { return 1; }\ntake([1, 2]);\ntake([]);") == 0;
}
