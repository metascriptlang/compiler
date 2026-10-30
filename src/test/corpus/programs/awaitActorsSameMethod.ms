// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: 3|x|2|2|done

actor A {
	log: string = "";
	count: int32 = 2;
	read(): string { return this.log; }
	run(): int32 { return this.count; }
}

actor B {
	log: string = "";
	count: int32 = 3;
	read(): string { return this.log; }
	run(): int32 { return this.count; }
}

const a = new A();
const b = new B();
const rb = await b.run();
const ra = await a.run();
const x = await a.read();
console.log(`${String(rb)}|${x === "" ? "x" : "?"}|${String(ra)}|${String(await a.run())}|done`);
