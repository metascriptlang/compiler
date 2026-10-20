import { checkOnly } from "../helpers";

test "a class missing a member of an interface it implements is refused at the class name" {
	const src = `
interface Named { name: string; }
interface Point { x: int32; y: int32; }
interface Aged extends Named { age: int32; }
interface Box<T> { value: T; }
class Pet implements Named { age: int32 = 3; }
class Spot implements Point { z: int32 = 1; }
class Old implements Aged { age: int32 = 9; }
class Cell<T> implements Box<T> { other: int32 = 1; }
function local(): void {
	class Inner implements Named { n: int32 = 1; }
}
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("Class 'Pet' incorrectly implements interface 'Named': property 'name' is missing in 'Pet'"), "missing field: " + text;
	assert text.contains("Class 'Spot' incorrectly implements interface 'Point': properties 'x', 'y' are missing in 'Spot'"), "every missing field is named: " + text;
	assert text.contains("Class 'Old' incorrectly implements interface 'Aged': property 'name' is missing in 'Old'"), "a member of an extended interface: " + text;
	assert text.contains("Class 'Cell' incorrectly implements interface 'Box<T>': property 'value' is missing in 'Cell'"), "a generic interface: " + text;
	assert text.contains("Class 'Inner' incorrectly implements interface 'Named'"), "a class declared in a function: " + text;
}

test "a member of the wrong type is refused at the member, an inherited one at the class" {
	const src = `
interface Named { name: string; }
interface Box<T> { value: T; }
class Pet implements Named { name: int32 = 3; }
class StrCell implements Box<int32> { value: string = "x"; }
class Animal { name: int32 = 1; }
class Dog extends Animal implements Named { age: int32 = 3; }
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("Property 'name' in class 'Pet' is not assignable to the same property in interface 'Named': type 'int32' is not assignable to type 'string'"), "own field: " + text;
	assert text.contains("Property 'value' in class 'StrCell' is not assignable to the same property in interface 'Box<int32>': type 'string' is not assignable to type 'int32'"), "instantiated generic interface: " + text;
	assert text.contains("Class 'Dog' incorrectly implements interface 'Named': property 'name' of 'Dog': type 'int32' is not assignable to type 'string'"), "inherited field: " + text;
}

test "of two implemented interfaces only the one the class does not hold is named" {
	const src = `
interface Named { name: string; }
interface Owned { owner: string; }
class Pet implements Named, Owned { name: string = "rex"; }
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 1, "one error: " + errors.join("\n");
	assert errors[0].contains("Class 'Pet' incorrectly implements interface 'Owned': property 'owner' is missing in 'Pet'"), errors[0];
}

test "an implemented type that is not an object type is refused" {
	const errors = checkOnly(`
type U = string | int32;
class Pet implements U { name: string = "rex"; }
`).errors;
	assert errors.length == 1 && errors[0].contains("Class 'Pet' can only implement an object type, and 'U' is not one"), errors.join("\n");
}

test "a class holding every member of what it implements still checks" {
	const src = `
interface Named { name: string; }
interface Profile { name: string; age: int32; }
interface Greeter { greet: () => string; }
interface Labeled { label?: string; }
interface Frozen { readonly name: string; }
interface Box<T> { value: T; }
interface Aged extends Named { age: int32; }
type Shape = { name: string };
class Base { name: string = "b"; }
class Pet implements Named, Profile { name: string = "rex"; age: int32 = 3; }
class Hello implements Greeter { greet: () => string = () => "hi"; }
class Tag implements Labeled { label: string | null = "x"; }
class Maybe implements Labeled { label?: string; }
class Ice implements Frozen { name: string = "ice"; }
class Cell<T> implements Box<T> { value: T; constructor(v: T) { this.value = v; } }
class IntCell implements Box<int32> { value: int32 = 4; }
class Animal { name: string = "a"; }
class Dog extends Animal implements Named { age: int32 = 3; }
class Old implements Aged { name: string = "o"; age: int32 = 9; }
class Shaped implements Shape { name: string = "s"; }
class Copy implements Base { name: string = "c"; }
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "every implemented member is held: " + errors.join("\n");
}
