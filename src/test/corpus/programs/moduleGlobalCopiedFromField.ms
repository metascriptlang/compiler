// @stdout: field a! b?
// @exit: 0
// note: a module-level binding copied from another global's field or element is global storage: a function reads it after the top level ran. The analyzer lowers the copy into a block; codegen still declares the binding as a C global. Reference: ccgstmts genSingleVar sends an sfGlobal variable to assignGlobalVar wherever it is nested.

struct Pet { hunger: int32; name: string; }

let own: Pet = { hunger: 1, name: "a" };
const renamed = own.name;
const tags: string[] = ["b"];
const first = tags[0];

function show(): string {
	return `${renamed}! ${first}?`;
}

console.log(`field ${show()}`);
