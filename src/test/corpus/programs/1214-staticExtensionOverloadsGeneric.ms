// @stdout: 2 first 3 9
class Pick {}
function choose<T>(this typeof Pick, a: T, b: T): T {
	return b;
}
function choose<T>(this typeof Pick, items: T[]): T {
	return items[0];
}
class Other {}
function choose<T>(this typeof Other, a: T, b: T, c: T): T {
	return c;
}
console.log(Pick.choose(1, 2), Pick.choose(["first", "second"]), Other.choose(1, 2, 3), Other.choose("a", "b", "c").length * 9);
