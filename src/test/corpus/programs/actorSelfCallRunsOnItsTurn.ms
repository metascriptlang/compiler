// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: log=begin;helper;alias;end;
// @stdout: next=6
// @stdout: later=begin;end;stored;
// note: a call through `this`, or a const bound to it, inside the actor's own method runs the method body on this turn; a stored closure still calls through the actor and runs after the turn (ULTRALOCK A9).

actor A {
	log: string = "";
	stored: (() => void) | null = null;

	note(s: string): void {
		this.log = this.log + s + ";";
	}

	value(): int32 {
		return 5;
	}

	run(): string {
		this.log = "begin;";
		this.note("helper");
		const self = this;
		self.note("alias");
		this.log = this.log + "end;";
		return this.log;
	}

	next(): int32 {
		const v = this.value();
		return v + 1;
	}

	defer(): string {
		this.log = "begin;";
		this.stored = (): void => { this.note("stored"); };
		this.stored!();
		this.log = this.log + "end;";
		return this.log;
	}

	read(): string {
		return this.log;
	}
}

const a = new A();
console.log(`log=${await a.run()}`);
console.log(`next=${await a.next()}`);
await a.defer();
console.log(`later=${await a.read()}`);
