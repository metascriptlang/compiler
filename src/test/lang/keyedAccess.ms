interface Todo { title: string; done: boolean; n: int32; }

function pick<K extends keyof Todo>(t: Todo, key: K): Todo[K] { return t[key]; }
function put<K extends keyof Todo>(t: Todo, key: K, v: Todo[K]): void { t[key] = v; }

class Point { x: int32 = 1; y: int32 = 2; }

class Fields<T> {
	read<K extends keyof T>(t: T, key: K): T[K] { return t[key]; }
	put<K extends keyof T>(t: T, key: K, v: T[K]): void { t[key] = v; }
}

class Reader {
	read<K extends keyof Point>(p: Point, key: K): Point[K] { return p[key]; }
}

test "a routine generic over a key reads and writes the property the key names" {
	const t: Todo = { title: "a", done: false, n: 1 };
	put(t, "title", "b");
	put(t, "done", true);
	put(t, "n", 5);
	assert t.title == "b" && t.done && t.n == 5;
	assert pick(t, "title") == "b" && pick(t, "n") + 1 == 6;
}

test "a method generic over a key reads a class instance's field" {
	const p = new Point();
	assert new Reader().read(p, "x") + new Reader().read(p, "y") == 3;
}

test "keyof a type parameter is bound per instance of the class" {
	const t: Todo = { title: "a", done: false, n: 1 };
	const f = new Fields<Todo>();
	f.put(t, "n", 7);
	f.put(t, "done", true);
	assert f.read(t, "n") + 1 == 8 && f.read(t, "title") == "a" && f.read(t, "done");
}

test "a literal key in brackets is the property" {
	const t: Todo = { title: "a", done: false, n: 1 };
	t["n"] = 7;
	assert t["n"] == 7 && t["title"] == "a";
}
