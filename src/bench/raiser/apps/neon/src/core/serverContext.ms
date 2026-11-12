import { Computation } from "./types";

export class SafeError extends Error {}

export function sanitized(error: Error): Error {
	let wire = error;
	when (debug) {} else { if (!(error instanceof SafeError)) { wire = new Error("Internal Server Error"); } }
	return wire;
}

async function noWait(): Promise<void> {}

export class ServerSlot {
	wait: Promise<void> = noWait();
	settled: boolean = false;
	json: string = "";
	cell: unknown;
	failure: Error | null = null;
}

// A text spot whose read was not ready: the writer keeps a marker where its text goes and the
// spot's own thunk is run again, under the owner it was made in, once its source has settled.
export class Hole {
	id: string;
	get: () => string;
	owner: Computation | null;
	source: Computation;
	value: string | null = null;
	marked: boolean = true;
	lead: int32 = 0;
	after: Hole | null = null;

	constructor(id: string, get: () => string, owner: Computation | null, source: Computation) {
		this.id = id;
		this.get = get;
		this.owner = owner;
		this.source = source;
	}
}

// The style rules a mount registered while its markup was held back: they travel with that markup, not with the shell.
export class Rules {
	ids: string[] = [];
	css: string[] = [];
}

export interface ServerMarks {
	open: (id: string) => unknown;
	close: (id: string) => unknown;
	holder: (beside: unknown) => unknown;
	html: (holder: unknown) => string;
	within: (id: string, run: () => boolean) => boolean;
	rules: (hold: Rules | null) => Rules | null;
	replay: (hold: Rules) => void;
	pend: (node: unknown, hole: Hole) => void;
	take: (first: unknown) => string;
	kept: (markup: string, holes: Hole[]) => Hole[];
	fill: (markup: string, holes: Hole[]) => string;
}

export class Fragments {
	markup: Map<string, string> = new Map<string, string>();
	settled: ((id: string) => void) | null = null;

	set(id: string, html: string): void {
		this.markup.set(id, html);
		if (this.settled !== null) { (this.settled as (id: string) => void)(id); }
	}

	get(id: string): string | null {
		return this.markup.get(id);
	}
}

export class ServerContext {
	slots: Map<string, ServerSlot> = new Map<string, ServerSlot>();
	modules: Map<string, string> = new Map<string, string>();
	started: string[] = [];
	loops: Promise<void>[] = [];
	fragments: Fragments = new Fragments();
	failure: Error | null = null;
	marks: ServerMarks | null = null;
	holes: Hole[] | null = null;
	holeCount: int32 = 0;
}

export function pendingWaits(ctx: ServerContext, sources: Computation[]): Promise<void>[] {
	const waits: Promise<void>[] = [];
	for (const source of sources) {
		const id = source.id;
		const slot = id === null ? null : ctx.slots.get(id);
		if (slot === null) { throw new Error("[SERVER_WAIT_WITHOUT_SLOT] a pending read names an async memo that has no server slot: create the memo inside the render that reads it, not before renderToStream starts"); }
		waits.push(slot.wait);
	}
	return waits;
}

let current: ServerContext | null = null;

export function serverContext(): ServerContext | null {
	return current;
}

export function withServerContext<T>(ctx: ServerContext, run: () => T): T {
	const prev = current;
	current = ctx;
	try {
		return run();
	} finally {
		current = prev;
	}
}

export const MAX_PASSES = 10000;

export function unconverged(where: string): Error {
	return new Error("SSR: " + where + " did not converge after " + MAX_PASSES.toString() + " passes; an async memo is created under a new owner id on every pass, so no settled answer is ever found again");
}
