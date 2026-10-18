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

class Logged<T> {
	get<K extends keyof T>(target: T, key: K): T[K] { log = log + "g" + key + ","; return Reflect.get(target, key); }
	set<K extends keyof T>(target: T, key: K, value: T[K]): boolean { log = log + "s" + key + ","; return Reflect.set(target, key, value); }
	has<K extends keyof T>(target: T, key: K): boolean { log = log + "h" + key + ","; return Reflect.has(target, key); }
	deleteProperty<K extends keyof T>(target: T, key: K): boolean { log = log + "d" + key + ","; return Reflect.deleteProperty(target, key); }
}

class NoTraps {}

class Refuses<T> {
	set<K extends keyof T>(target: T, key: K, value: T[K]): boolean { return false; }
}

class PushTwice<E> {
	push(target: E[], item: E): void { log = log + "push,"; target.push(item); target.push(item); }
}

test "an index and length on a Proxy of an array reach get and set" {
	log = "";
	const xs: int32[] = [1, 2, 3];
	const p = new Proxy(xs, new Logged<int32[]>());
	p[1] = 20;
	p[0] += 5;
	p[2]++;
	assert p[0] + p[1] + p[2] == 30 && p.length == 3 && xs[0] == 6;
	assert log == "s1,g0,s0,g2,s2,g0,g1,g2,glength,", log;
}

let reads = 0;
function readOnce(p: Proxy<int32[], NoTraps>): Proxy<int32[], NoTraps> { reads = reads + 1; return p; }
function firstIndex(): int32 { reads = reads + 10; return 0; }

test "a receiver and an index with effects are evaluated once per write" {
	reads = 0;
	const xs: int32[] = [1];
	readOnce(new Proxy(xs, new NoTraps()))[firstIndex()] += 4;
	assert reads == 11 && xs[0] == 5, String(reads);
}

test "an array method runs its specification steps through the traps" {
	const xs: string[] = ["a", "b", "c"];
	const p = new Proxy(xs, new Logged<string[]>());
	log = "";
	p.push("d");
	assert log == "glength,s3,slength,", log;
	log = "";
	assert p.pop() == "d";
	assert log == "glength,g3,d3,slength,", log;
	log = "";
	assert p.shift() == "a" && xs.join("") == "bc";
	assert log == "glength,g0,h1,g1,s0,h2,g2,s1,d2,slength,", log;
	log = "";
	assert p.indexOf("c") == 1 && p.join("-") == "b-c";
	assert log == "glength,h0,g0,h1,g1,glength,g0,g1,", log;
}

test "a handler without traps writes an array as Reflect does, appending at its length" {
	const xs: int32[] = [1, 2];
	const p = new Proxy(xs, new NoTraps());
	p[2] = 3;
	p.push(4);
	p.length = 3;
	p.splice(0, 1);
	p.reverse();
	assert xs.join(",") == "3,2" && p.length == 2, xs.join(",");
}

test "Reflect on an array appends at its length, shrinks it, and refuses a hole" {
	const xs: int32[] = [1, 2];
	assert Reflect.set(xs, 2, 3) && Reflect.set(xs, "length", 1) && xs.join(",") == "1";
	assert Reflect.get(xs, 0) == 1 && Reflect.get(xs, "length") == 1 && Reflect.has(xs, 0) && !Reflect.has(xs, 1);
	let message = "";
	try { Reflect.set(xs, 5, 9); } catch (e) { message = (e as Error).message; }
	assert message == "a write at index 5 would leave a hole in an array of length 1", message;
}

test "a set trap that returns false fails the write" {
	const todo: Todo = { title: "a", done: false };
	let message = "";
	try { new Proxy(todo, new Refuses<Todo>()).title = "b"; } catch (e) { message = (e as Error).message; }
	assert message == "'set' on a Proxy returned false for the key 'title'" && todo.title == "a", message;
	const xs: int32[] = [1];
	try { new Proxy(xs, new Refuses<int32[]>()).push(2); } catch (e) { message = (e as Error).message; }
	assert message == "'set' on a Proxy returned false for the key '1'" && xs.length == 1, message;
}

test "a handler method named as an array method overrides its steps" {
	log = "";
	const xs: int32[] = [1];
	new Proxy(xs, new PushTwice<int32>()).push(7);
	assert xs.join(",") == "1,7,7" && log == "push,", log;
}

test "for-of over a Proxy of an array reads length and each index through get" {
	const xs: int32[] = [4, 5];
	const p = new Proxy(xs, new Logged<int32[]>());
	log = "";
	let sum = 0;
	for (const x of p) sum = sum + x;
	assert sum == 9 && log == "glength,g0,glength,g1,glength,", log;
}
