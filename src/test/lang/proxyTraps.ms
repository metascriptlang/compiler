interface Todo { title: string; done: boolean; }

let log = "";

class Traps {
	get<K extends keyof Todo>(target: Todo, key: K): Todo[K] { log = log + "get " + key + ","; return target[key]; }
	set<K extends keyof Todo>(target: Todo, key: K, value: Todo[K]): boolean { log = log + "set " + key + ","; target[key] = value; return true; }
}

class Counted {
	get<K extends keyof Count>(target: Count, key: K): Count[K] { log = log + "get " + key + ","; return target[key]; }
	set<K extends keyof Count>(target: Count, key: K, value: Count[K]): boolean { log = log + "set " + key + ","; target[key] = value; return true; }
}

class CountReads {
	get<K extends keyof Count>(target: Count, key: K): Count[K] { log = log + "get " + key + ","; return target[key]; }
}

interface Count { n: int32; }

class SetOnly {
	set<K extends keyof Todo>(target: Todo, key: K, value: Todo[K]): boolean { log = log + "set " + key + ","; target[key] = value; return true; }
}

class Fields<T> {
	get<K extends keyof T>(target: T, key: K): T[K] { log = log + "field " + key + ","; return target[key]; }
}

test "a read and a write reach the handler's traps with their key" {
	log = "";
	const todo: Todo = { title: "a", done: false };
	const p = new Proxy(todo, new Traps());
	p.done = true;
	assert p.title == "a" && p.done && todo.done && proxyTarget(p) === todo;
	assert log == "set done,get title,get done,", log;
}

test "a trap the handler leaves out is the plain operation on the target" {
	log = "";
	const todo: Todo = { title: "a", done: false };
	const p = new Proxy(todo, new SetOnly());
	p.title = "b";
	assert p.title == "b" && todo.title == "b";
	assert log == "set title,", log;
}

let made = 0;
function made1(p: Proxy<Todo, Traps>): Proxy<Todo, Traps> { made = made + 1; return p; }

test "a receiver with effects is evaluated once per access" {
	log = "";
	made = 0;
	const todo: Todo = { title: "a", done: false };
	const p = new Proxy(todo, new Traps());
	made1(p).title = "c";
	assert made1(p).title == "c" && made == 2;
	assert log == "set title,get title,", log;
}

test "a handler generic over its target is instantiated per key" {
	log = "";
	const p = new Proxy({ title: "a", done: true } as Todo, new Fields<Todo>());
	assert p.title == "a" && p.done;
	assert log == "field title,field done,", log;
}

test "a compound write is a read then a write, each through its trap" {
	log = "";
	const c: Count = { n: 1 };
	const p = new Proxy(c, new Counted());
	p.n += 2;
	p.n++;
	p.n--;
	assert c.n == 3, String(c.n);
	assert log == "get n,set n,get n,set n,get n,set n,", log;
}

test "a compound write without a set trap reads through get and writes the target" {
	log = "";
	const c: Count = { n: 2 };
	const p = new Proxy(c, new CountReads());
	p.n *= 5;
	assert c.n == 10 && log == "get n,", log;
}

test "a key written in brackets is the member" {
	log = "";
	const todo: Todo = { title: "a", done: false };
	const p = new Proxy(todo, new Traps());
	p["title"] = "b";
	assert p["title"] == "b" && todo.title == "b";
	assert log == "set title,get title,", log;
}
