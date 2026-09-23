// @stdout: free=ns arity=onetwo ext=num,str sorted=1,2,3,10|Apple,apple,fig,pear

// Every backend calls the overload the checker chose: by parameter type, by
// arity, and by the element type of an extension's `this`. Array `sort` is
// such a pair, one per element type.
function g(x: number): string { return "n"; }
function g(x: string): string { return "s"; }

function h(x: number): string { return "one"; }
function h(x: number, y: number): string { return "two"; }

function kind(this a: number[]): string { return "num"; }
function kind(this a: string[]): string { return "str"; }

const nums: number[] = [3, 1, 2, 10];
const words: string[] = ["pear", "apple", "fig", "Apple"];
const ext = nums.kind() + "," + words.kind();
nums.sort();
words.sort();
const sorted = nums[0].toString() + "," + nums[1].toString() + "," + nums[2].toString() + "," + nums[3].toString()
	+ "|" + words.join(",");
console.log("free=" + g(1) + g("a") + " arity=" + h(1) + h(1, 2) + " ext=" + ext + " sorted=" + sorted);
