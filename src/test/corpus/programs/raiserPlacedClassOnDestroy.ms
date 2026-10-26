class Conn {
	id: int32;
	constructor(id: int32) { this.id = id; }
}

class Pool {
	first: Conn;
	second: Conn;
	constructor(first: Conn, second: Conn) {
		this.first = first;
		this.second = second;
	}
}

let log: int32 = 0;

function onDestroy(this c: Conn): void {
	log = log * 10 + c.id;
}

function run(): void {
	const a = new Conn(1);
	{
		const b = new Conn(2);
		console.log(b.id);
	}
	console.log(log);
	const pool = new Pool(new Conn(3), new Conn(4));
	const shared = pool.first;
	pool.first = new Conn(5);
	console.log(log);
	console.log(a.id + shared.id);
}

run();
console.log(log);
