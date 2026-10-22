// Parity program — a function value adapted to a slot with more parameters is
// evaluated where it is written, so a local it reads that also lives in a
// shared closure environment is read from that environment.
// @stdout: one-param now|later
// @stdout: two-param now|later
// @stdout: named-log now|later
// @stdout: nested inner|outer|later
// @stdout: captured-value held|later|held
// @stdout: optional-extra 7:-|later

interface OneSlot {
	on: ((e: int32) => void) | null;
}

interface TwoSlot {
	on: ((a: int32, b: int32) => void) | null;
}

function note(sink: string[], what: string): () => void {
	return (): void => { sink.push(what); };
}

function noteTagged(sink: string[]): (e: int32, tag?: string) => void {
	return (e: int32, tag?: string): void => { sink.push(String(e) + ":" + (tag ?? "-")); };
}

function fireOne(p: OneSlot): void {
	if (p.on !== null) { (p.on as (e: int32) => void)(7); }
}

function fireTwo(p: TwoSlot): void {
	if (p.on !== null) { (p.on as (a: int32, b: int32) => void)(1, 2); }
}

function onePadded(): void {
	const seen: string[] = [];
	const later = (): void => { seen.push("later"); };
	fireOne({ on: note(seen, "now") });
	later();
	console.log("one-param " + seen.join("|"));
}

function twoPadded(): void {
	const seen: string[] = [];
	const later = (): void => { seen.push("later"); };
	fireTwo({ on: note(seen, "now") });
	later();
	console.log("two-param " + seen.join("|"));
}

function namedLog(): void {
	const log: string[] = [];
	const later = (): void => { log.push("later"); };
	fireOne({ on: note(log, "now") });
	later();
	console.log("named-log " + log.join("|"));
}

function nested(): void {
	const log: string[] = [];
	const later = (): void => { log.push("later"); };
	const outer = (): void => {
		const run = (): void => { fireOne({ on: note(log, "inner") }); };
		run();
		fireOne({ on: note(log, "outer") });
	};
	outer();
	later();
	console.log("nested " + log.join("|"));
}

function capturedValue(): void {
	const log: string[] = [];
	const held = (): void => { log.push("held"); };
	const later = (): void => { log.push("later"); held(); };
	fireOne({ on: held });
	later();
	console.log("captured-value " + log.join("|"));
}

function optionalExtra(): void {
	const log: string[] = [];
	const later = (): void => { log.push("later"); };
	fireOne({ on: noteTagged(log) });
	later();
	console.log("optional-extra " + log.join("|"));
}

onePadded();
twoPadded();
namedLog();
nested();
capturedValue();
optionalExtra();
