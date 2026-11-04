class Node {
	id: int32;
	constructor(id: int32) { this.id = id; }
}

struct Tagged {
	name: string;
	n: int32;
}

let trail = "";

function mark<T>(tag: string, value: T): T {
	trail += tag;
	return value;
}

test "spread of number[] copies the elements and leaves the source alone" {
	const nums: number[] = [1.5, 2.5, 3.5];
	const copy: number[] = [...nums];
	copy[0] = 9;
	assert copy.length == 3 && copy[0] == 9 && copy[1] == 2.5 && copy[2] == 3.5;
	assert nums[0] == 1.5;
}

test "spread of int32[] and string[] with plain elements around the sources" {
	const a: int32[] = [1, 2];
	const b: int32[] = [5, 6, 7];
	const joined: int32[] = [0, ...a, 3, 4, ...b, 8];
	assert joined.length == 9;
	for (let i = 0; i < 9; i++) assert joined[i] == i;
	const words: string[] = ["x", "y"];
	const more: string[] = ["z"];
	const all: string[] = [...words, "mid", ...more, ...words];
	assert all.join(",") == "x,y,mid,z,x,y";
	words[0] = "changed";
	assert all[0] == "x";
}

test "spread of an empty source" {
	const none: number[] = [];
	const some: number[] = [4];
	const a: number[] = [...none];
	const b: number[] = [...none, ...some, ...none];
	const c: number[] = [...none, 7, ...none];
	assert a.length == 0;
	assert b.length == 1 && b[0] == 4;
	assert c.length == 1 && c[0] == 7;
}

test "spread of class references shares the objects" {
	const first = new Node(1);
	const second = new Node(2);
	const src: Node[] = [first, second];
	const copy: Node[] = [...src, first];
	assert copy.length == 3;
	copy[1].id = 20;
	assert second.id == 20 && copy[2] === first;
}

test "spread of structs with hooks copies each element" {
	const src: Tagged[] = [{ name: "a", n: 1 }, { name: "b", n: 2 }];
	const copy: Tagged[] = [...src, { name: "c", n: 3 }, ...src];
	assert copy.length == 5;
	copy[0].name = "changed";
	assert src[0].name == "a";
	assert copy[3].name == "a" && copy[4].n == 2 && copy[2].name == "c";
}

test "sources and plain elements evaluate left to right once" {
	trail = "";
	const result: number[] = [mark("a", 1), ...mark("b", [2, 3]), mark("c", 4), ...mark("d", [5]), mark("e", 6)];
	assert trail == "abcde";
	assert result.join(",") == "1,2,3,4,5,6";
}

test "spread of a Set keeps its own path" {
	const s = new Set<number>();
	s.add(3);
	s.add(4);
	const out: number[] = [1, ...s, 2];
	assert out.join(",") == "1,3,4,2";
}
