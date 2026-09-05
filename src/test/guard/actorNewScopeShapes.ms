actor Counter {
	private n: int32 = 0;
	bump(d: int32): void { this.n += d; }
	get(): int32 { return this.n; }
}

class Factory {
	make(): Counter {
		const c = new Counter();
		return c;
	}
}

class Holder {
	c: Counter = new Counter();
}

async function fromAsyncFn(): Promise<int32> {
	const c = new Counter();
	c.bump(1);
	return await c.get();
}

function fromArrowBlock(): int32 {
	const mk = (): Counter => {
		const c = new Counter();
		return c;
	};
	const c = mk();
	c.bump(2);
	return await c.get();
}

function fromArrowExpr(): int32 {
	const mk = (): Counter => new Counter();
	const c = mk();
	c.bump(3);
	return await c.get();
}

function fromMethodBody(): int32 {
	const f = new Factory();
	const c = f.make();
	c.bump(4);
	return await c.get();
}

function fromFieldInitializer(): int32 {
	const h = new Holder();
	h.c.bump(5);
	return await h.c.get();
}

function fromNestedClosure(): int32 {
	const outer = (): int32 => {
		const inner = (): Counter => {
			const c = new Counter();
			c.bump(6);
			return c;
		};
		const cc = inner();
		return await cc.get();
	};
	return outer();
}

let bad = 0;

function expect(label: string, got: int32, want: int32): void {
	if (got !== want) {
		console.log("FAIL " + label + " got=" + got + " want=" + want);
		bad = 1;
	}
}

expect("asyncFn", await fromAsyncFn(), 1);
expect("arrowBlock", fromArrowBlock(), 2);
expect("arrowExpr", fromArrowExpr(), 3);
expect("methodBody", fromMethodBody(), 4);
expect("fieldInitializer", fromFieldInitializer(), 5);
expect("nestedClosure", fromNestedClosure(), 6);

if (bad !== 0) { process.exit(1); }
console.log("GUARD-OK");
