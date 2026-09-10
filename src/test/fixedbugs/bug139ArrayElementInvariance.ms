// bug139 — container elements were covariant, so a write through the view corrupted memory
//
// Symptom:    `Dog[]` was accepted wherever `Animal[]` was expected; pushing an
//             `Animal` through that view then reading `dogs[1].breed` was an
//             ASan heap-buffer-overflow. Every site was open: argument, Span,
//             sized array, declaration, field, return, and a generic `T[]`
//             whose `T` settled on the base class from another argument.
// Root cause: the Array/Span/Ptr/SizedArray arms of isAssignable and the
//             container walk of isReinterpretUnsafe compared elements with
//             isAssignable, so any element subtyping made the containers
//             assignable although the C payload is shared by pointer.
// Fix:        elements must be the same type (empty literals, literals, and
//             generic-open elements keep their existing relaxation); the
//             fitNode walk rejects the same pairs.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

const B139 = "class Animal139 { name: string = \"\"; }\nclass Dog139 extends Animal139 { breed: string = \"\"; }\n";

test "bug139: a subclass array is rejected as an argument" {
	assert hasError(B139 + "function add139(xs: Animal139[]): void { xs.push(new Animal139()); }\nconst dogs: Dog139[] = [new Dog139()];\nadd139(dogs);\n", "Argument type mismatch in 'add139' arg 0");
}

test "bug139: a subclass array is rejected as a Span argument" {
	assert hasError(B139 + "function count139(xs: Span<Animal139>): int32 { return xs.length; }\nconst dogs: Dog139[] = [new Dog139()];\ncount139(dogs);\n", "Argument type mismatch in 'count139' arg 0");
}

test "bug139: a subclass sized array is rejected as an argument" {
	assert hasError(B139 + "function two139(xs: Animal139[2]): int32 { return 2; }\nconst dogs: Dog139[2] = [new Dog139(), new Dog139()];\ntwo139(dogs);\n", "Argument type mismatch in 'two139' arg 0");
}

test "bug139: a subclass array is rejected in a declaration" {
	assert hasError(B139 + "const dogs: Dog139[] = [new Dog139()];\nconst view: Animal139[] = dogs;\n", "is not assignable to type 'Animal139[]'");
}

test "bug139: a subclass array is rejected in an object literal field" {
	assert hasError(B139 + "interface Zoo139 { pets: Animal139[]; }\nconst dogs: Dog139[] = [new Dog139()];\nconst z: Zoo139 = { pets: dogs };\n", "is not assignable to type 'Animal139[]'");
}

test "bug139: a subclass array is rejected as a return value" {
	assert hasError(B139 + "function mk139(): Animal139[] { const dogs: Dog139[] = [new Dog139()]; return dogs; }\n", "is not assignable to type 'Animal139[]'");
}

test "bug139: a base-class element cannot widen a generic array param" {
	assert hasError(B139 + "function first139<T>(xs: T[], v: T): T { xs.push(v); return xs[0]; }\nconst dogs: Dog139[] = [new Dog139()];\nconst an = new Animal139();\nfirst139(dogs, an);\n", "Argument type mismatch in 'first139'");
}

test "bug139: a base-class scalar bound first still rejects the subclass array" {
	assert hasError(B139 + "function keep139<T>(a: T, xs: T[]): void { xs.push(a); }\nconst dogs: Dog139[] = [new Dog139()];\nconst an = new Animal139();\nkeep139(an, dogs);\n", "Argument type mismatch in 'keep139' arg 1");
}

test "bug139: a nullable-element view of a non-null array is rejected" {
	assert hasError(B139 + "const pets: Animal139[] = [new Animal139()];\nconst view: (Animal139 | null)[] = pets;\n", "is not assignable to type");
}

test "bug139: same-type, explicit cast, empty literal and settled generic stay accepted" {
	const r = compileToC(B139
		+ "function add139(xs: Animal139[]): void { xs.push(new Animal139()); }\n"
		+ "function first139<T>(xs: T[], v: T): T { xs.push(v); return xs[0]; }\n"
		+ "const dogs: Dog139[] = [new Dog139()];\n"
		+ "const pets: Animal139[] = [];\n"
		+ "add139(pets);\n"
		+ "add139(dogs as Animal139[]);\n"
		+ "const one: Animal139 = dogs[0];\n"
		+ "const d = first139(dogs, new Dog139());\n"
		+ "const names: string[] = [\"a\", \"b\"];\n"
		+ "console.log(one.name.length + d.breed.length + names.length);\n");
	assert r.ok;
}
