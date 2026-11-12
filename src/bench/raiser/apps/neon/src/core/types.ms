export type Cleanup = () => void;
export type Dispose = () => void;

export interface ContextEntry {
	key: unknown;
	value: unknown;
	next: ContextEntry | null;
}

export const REACTIVE_CHECK: int32 = 1 << 0;
export const REACTIVE_DIRTY: int32 = 1 << 1;
export const REACTIVE_RECOMPUTING_DEPS: int32 = 1 << 2;
export const REACTIVE_IN_HEAP: int32 = 1 << 3;
export const REACTIVE_IN_HEAP_HEIGHT: int32 = 1 << 4;
export const REACTIVE_DISPOSED: int32 = 1 << 6;
export const REACTIVE_SNAPSHOT_STALE: int32 = 1 << 8;
export const REACTIVE_LAZY: int32 = 1 << 9;
export const REACTIVE_MISSED_WAKE: int32 = 1 << 12;
export const REACTIVE_REASK: int32 = 1 << 13;
export const REACTIVE_PROBED: int32 = 1 << 14;

export const STATUS_PENDING: int32 = 1 << 0;
export const STATUS_ERROR: int32 = 1 << 1;
export const STATUS_UNINITIALIZED: int32 = 1 << 2;

export const CONFIG_OWNED_WRITE: int32 = 1 << 0;
export const CONFIG_TRANSPARENT: int32 = 1 << 2;
export const CONFIG_IN_SNAPSHOT_SCOPE: int32 = 1 << 3;
export const CONFIG_AUTO_DISPOSE: int32 = 1 << 5;
export const CONFIG_STAGED: int32 = 1 << 7;
export const CONFIG_HAS_SNAPSHOT: int32 = 1 << 9;
export const CONFIG_NO_SNAPSHOT: int32 = 1 << 10;
export const CONFIG_SNAPSHOT_SCOPE: int32 = 1 << 11;
export const CONFIG_PROMOTED: int32 = 1 << 22;
export const CONFIG_ROOT: int32 = 1 << 23;
export const CONFIG_MODIFIED: int32 = 1 << 24;
export const CONFIG_DORMANT_QUEUED: int32 = 1 << 25;
export const CONFIG_VERDICT: int32 = 1 << 26;
export const CONFIG_REDERIVE: int32 = 1 << 27;

export const EFFECT_PURE: int32 = 0;
export const EFFECT_RENDER: int32 = 1;
export const EFFECT_USER: int32 = 2;

export const RUN_UNCHANGED: int32 = 0;
export const RUN_PUBLISHED: int32 = 1;
export const RUN_STAGED: int32 = 2;

export const READ_VALUE: int32 = 0;
export const READ_STAGED: int32 = 1;
export const READ_SNAPSHOT: int32 = 2;

export interface Link {
	dep: Source;
	sub: Computation;
	nextDep: Link | null;
	prevSub: Link | null;
	nextSub: Link | null;
	gen: int32;
}

// `commit` and `run` close over the typed Cell only, never their own node: --gc=drc has
// no cycle collector, so a node that reaches itself through its closure leaks.
export class Source {
	subs: Link | null = null;
	subsTail: Link | null = null;
	config: int32;
	computed: boolean;
	commit: (() => void) | null = null;

	constructor(config: int32, computed: boolean) {
		this.config = config;
		this.computed = computed;
	}
}

export class Computation extends Source {
	deps: Link | null = null;
	depsTail: Link | null = null;
	depGen: int32 = 0;
	flags: int32;
	height: int32 = 0;
	nextHeap: Computation | null = null;
	prevHeap: Computation | null = null;
	run: ((self: Computation, create: boolean) => int32) | null;
	apply: ((self: Computation) => void) | null = null;
	cleanup: Cleanup | null = null;
	type: int32;
	unobserved: (() => void) | null = null;

	parent: Computation | null;
	parentComputed: Computation | null = null;
	firstChild: Computation | null = null;
	nextSibling: Computation | null = null;
	prevSibling: Computation | null = null;
	disposal: Cleanup[] | null = null;
	context: ContextEntry | null;
	id: string | null = null;
	childCount: int32 = 0;

	status: int32;
	error: Error | null = null;
	flight: int32 = 0;
	pendingSources: Computation[] | null = null;
	blocked: boolean = false;
	reask: boolean = false;
	visitedAt: int32 = 0;
	time: int32;

	constructor(config: int32, flags: int32, computed: boolean, run: ((self: Computation, create: boolean) => int32) | null, type: int32, parent: Computation | null, time: int32) {
		super(config, computed);
		this.flags = flags;
		this.run = run;
		this.type = type;
		this.parent = parent;
		this.context = parent !== null ? parent.context : null;
		this.status = computed ? STATUS_UNINITIALIZED : 0;
		this.time = time;
	}
}

export class NotReadyError extends Error {
	source: Computation;

	constructor(source: Computation) {
		super("[NOT_READY] a read of an async value that has not settled yet");
		this.source = source;
	}
}
