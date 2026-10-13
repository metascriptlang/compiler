function count(n: int32): int32 {
	return n;
}

const none = new Array<uint64>(count(0));
const some = new Array<uint64>(count(3));
const names = new Array<string>(count(2));
some[2] = 7;
names[1] = "ab";
console.log(`${none.length} ${some.length} ${some[0]} ${some[2]} ${names.length} ${names[1]}`);
