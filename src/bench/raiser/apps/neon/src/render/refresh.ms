import { setTextContent } from "./paragraph";
import { Host, HostNode, NeonNode } from "./hostTypes";
import { Row, place } from "./reconcile";
import { RowHome, regionNode, builtRow } from "./node";
import { Computation, NotReadyError } from "../core/types";
import { disposeChildren, flush, getOwner, isDisposed } from "../core/runtime";
import { runWithOwner } from "../core/owner";
import { createMemo } from "../core/memo";
import { Accessor, Setter, Signal, untrack } from "../core/signal";
import { refreshTypeKey } from "../macros/refresh";
import { onCleanup } from "../core/cleanup";
import { Listeners, Unsubscribe, listeners } from "./voidAreaHandle";

export type SigFn = () => string;

type RowList = () => Row[];

export interface RefreshSummary {
	kept: int32;
	rebuilt: int32;
	remounted: int32;
}

export interface RefreshDone {
	scope: string;
	name: string;
	summary: RefreshSummary;
	ms: number;
}

export interface RefreshFailure {
	component: string;
	message: string;
}

export interface KeptValue {
	key: string;
	value: string;
}

export interface MountedComponent {
	name: string;
	module: string;
	broken: boolean;
	state: KeptValue[];
}

class ComponentSlot<P> {
	body: (props: P) => NeonNode;
	sigFn: SigFn;

	constructor(body: (props: P) => NeonNode, sigFn: SigFn) {
		this.body = body;
		this.sigFn = sigFn;
	}
}

class TemplateSlot<E> {
	fn: (env: E) => NeonNode;
	sigFn: SigFn;

	constructor(fn: (env: E) => NeonNode, sigFn: SigFn) {
		this.fn = fn;
		this.sigFn = sigFn;
	}
}

class StateCell<T> {
	read: () => T;
	value: T;

	constructor(read: () => T, value: T) {
		this.read = read;
		this.value = value;
	}
}

interface SavedState {
	key: string;
	type: string;
	cell: unknown;
	show: () => string;
}

interface Instance {
	render: () => NeonNode;
	sigFn: SigFn;
	type: string;
	saved: SavedState[];
	live: SavedState[];
	captures: (() => void)[];
	broken: boolean;
	key: string;
	keyFile: string;
	host: Host;
	parent: HostNode;
	anchor: HostNode;
	owner: Computation;
	sig: string;
	nextSig: string | null;
	revision: Signal<number>;
}

const compSlots = new Map<string, unknown>();
const tmplSlots = new Map<string, unknown>();
const compInstances = new Map<string, Instance[]>();
const tmplInstances = new Map<string, Instance[]>();
const slotTypes = new Map<string, string>();
const pending = new Map<string, SavedState[][]>();
const moduleSigs = new Map<string, string>();
let mounting: Instance | null = null;
const importers = new Map<string, string[]>();

function keyOf(moduleFile: string, id: string): string {
	return moduleFile + "#" + id;
}

function track(instances: Map<string, Instance[]>, inst: Instance): void {
	const list = instances.get(inst.key);
	if (list === undefined) { instances.set(inst.key, [inst]); } else { list.push(inst); }
	runWithOwner(inst.owner, (): number => {
		onCleanup((): void => { untrackInstance(instances, inst); });
		return 0;
	});
}

function untrackInstance(instances: Map<string, Instance[]>, inst: Instance): void {
	const list = instances.get(inst.key);
	if (list === undefined) { return; }
	const at = list.indexOf(inst);
	if (at < 0) { return; }
	list.splice(at, 1);
	if (list.length === 0) { instances.delete(inst.key); }
}

function capture(inst: Instance): void {
	if (inst.broken) { return; }
	for (const read of inst.captures) { read(); }
	inst.saved = inst.live;
	inst.live = [];
	inst.captures = [];
}

function within(owner: Computation, ancestor: Computation): boolean {
	let up = owner.parent;
	while (up !== null) {
		if (up === ancestor) { return true; }
		up = up.parent;
	}
	return false;
}

function documentOrder(inst: Instance, below: Instance[]): Instance[] {
	if (below.length < 2) { return below; }
	const ordered: Instance[] = [];
	const open: HostNode[] = [];
	let node = inst.host.firstChild(inst.parent);
	while (node !== null) {
		for (const other of below) {
			if (other.anchor === node) { ordered.push(other); }
		}
		const child = inst.host.firstChild(node);
		if (child !== null) {
			open.push(node);
			node = child;
			continue;
		}
		let next = inst.host.nextSibling(node);
		while (next === null && open.length > 0) { next = inst.host.nextSibling(open.pop() as HostNode); }
		node = next;
	}
	for (const other of below) {
		if (ordered.indexOf(other) < 0) { ordered.push(other); }
	}
	return ordered;
}

function stash(inst: Instance): void {
	capture(inst);
	const below: Instance[] = [];
	for (const instances of [compInstances, tmplInstances]) {
		for (const list of instances.values()) {
			for (const other of list) {
				if (other !== inst && within(other.owner, inst.owner)) { below.push(other); }
			}
		}
	}
	for (const other of documentOrder(inst, below)) {
		capture(other);
		let queue = pending.get(other.key);
		if (queue === undefined) {
			queue = [];
			pending.set(other.key, queue);
		}
		queue.push(other.saved);
	}
}

function stashed(key: string): SavedState[] {
	const queue = pending.get(key);
	if (queue === undefined || queue.length === 0) { return []; }
	return queue.shift() as SavedState[];
}

function failure(message: string): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const box = host.createElement("holder");
		host.setStyle(box, { backgroundColor: "#900000", padding: 8 });
		const label = host.createElement("text");
		host.setStyle(label, { color: "#ffff00" });
		setTextContent(host, label, message);
		host.append(box, label);
		place(host, parent, box, before);
	};
}

function rebuild(inst: Instance, sig: string): void {
	stash(inst);
	inst.nextSig = sig;
	flush((): number => { inst.revision.set(inst.revision.peek() + 1); return 0; });
	pending.clear();
}

function instanceView(inst: Instance): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const outer = mounting;
		mounting = inst;
		inst.render()(host, parent, before);
		mounting = outer;
		inst.saved = [];
	};
}

// The row is built here, in the compute, so a pending read in the new view is this memo's pending status
// and the Loading keeps what it showed (Solid refresh createProxy, packages/solid/src/refresh/index.ts).
function instanceRows(instances: Map<string, Instance[]>, h: Host, home: RowHome, inst: Instance): Row[] {
	inst.revision.get();
	inst.owner = getOwner() as Computation;
	track(instances, inst);
	const rebuilding = inst.nextSig !== null;
	const kept = inst.saved;
	const outer = mounting;
	inst.live = [];
	inst.captures = [];
	try {
		const row = builtRow(h, home, instanceView(inst));
		if (rebuilding) {
			inst.broken = false;
			inst.sig = inst.nextSig as string;
			inst.nextSig = null;
		}
		return [row];
	} catch (e) {
		mounting = outer;
		if (!rebuilding || e instanceof NotReadyError) { throw e; }
		console.log("refresh: " + inst.key + " did not mount: " + e.message);
		const failureList = failures;
		if (failureList !== null) { failureList.emit({ component: inst.key, message: e.message }); }
		disposeChildren(inst.owner, false);
		track(instances, inst);
		const name = inst.key.substring(inst.key.lastIndexOf("/") + 1).split("|")[0];
		const failed = builtRow(h, home, failure(name + " did not mount: " + e.message));
		inst.saved = kept;
		inst.live = [];
		inst.captures = [];
		inst.broken = true;
		inst.sig = "";
		inst.nextSig = null;
		return [failed];
	}
}

function instanceNode(
	instances: Map<string, Instance[]>,
	moduleFile: string,
	key: string,
	type: string,
	render: () => NeonNode,
	sigFn: SigFn,
): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		regionNode((h: Host, home: RowHome): RowList => {
			const inst: Instance = {
				render: render,
				sigFn: sigFn,
				type: type,
				saved: stashed(key),
				live: [],
				captures: [],
				broken: false,
				key: key,
				keyFile: moduleFile,
				host: host,
				parent: parent,
				anchor: home.before as HostNode,
				owner: getOwner() as Computation,
				sig: sigFn(),
				nextSig: null,
				revision: new Signal<number>(0),
			};
			return createMemo<Row[]>((): Row[] => instanceRows(instances, h, home, inst));
		})(host, parent, before);
	};
}

function collect(instances: Map<string, Instance[]>, moduleFile: string): Instance[] {
	const found: Instance[] = [];
	for (const list of instances.values()) {
		for (const inst of list) {
			if (inst.keyFile === moduleFile) { found.push(inst); }
		}
	}
	return found;
}

function patch(instances: Map<string, Instance[]>, found: Instance[], forced: string[]): int32[] {
	let kept = 0 as int32;
	let changed = 0 as int32;
	for (const inst of found) {
		if (isDisposed(inst.owner)) { continue; }
		const sig = inst.sigFn();
		if (sig === inst.sig && forced.indexOf(inst.key) < 0) { kept += 1; continue; }
		rebuild(inst, sig);
		changed += 1;
	}
	return [kept, changed];
}

function enclosing(owner: Computation): Instance | null {
	let up = owner.parent;
	while (up !== null) {
		for (const list of compInstances.values()) {
			for (const inst of list) {
				if (inst.owner === up) { return inst; }
			}
		}
		up = up.parent;
	}
	return null;
}

function patchModule(moduleFile: string, changed: string[]): RefreshSummary {
	const comps = collect(compInstances, moduleFile);
	const tmpls = collect(tmplInstances, moduleFile);
	const forced: string[] = [];
	for (const key of changed) { forced.push(key); }
	for (const region of tmpls) {
		const type = slotTypes.get(region.key);
		if (type === undefined || type === region.type) { continue; }
		const component = enclosing(region.owner);
		if (component !== null && forced.indexOf(component.key) < 0) { forced.push(component.key); }
	}
	const boundaries = patch(compInstances, comps, forced);
	const regions = patch(tmplInstances, tmpls, forced);
	return { kept: boundaries[0] + regions[0], rebuilt: regions[1], remounted: boundaries[1] };
}

function componentSlot<P>(
	key: string,
	type: string,
	body: (props: P) => NeonNode,
	sigFn: SigFn,
): ComponentSlot<P> {
	const typed = key + "@" + type;
	const found = compSlots.get(typed);
	if (found !== null) { return found as ComponentSlot<P>; }
	const slot = new ComponentSlot<P>(body, sigFn);
	compSlots.set(typed, slot);
	return slot;
}

function templateSlot<E>(
	key: string,
	type: string,
	fn: (env: E) => NeonNode,
	sigFn: SigFn,
): TemplateSlot<E> {
	const typed = key + "@" + type;
	const found = tmplSlots.get(typed);
	if (found !== null) { return found as TemplateSlot<E>; }
	const slot = new TemplateSlot<E>(fn, sigFn);
	tmplSlots.set(typed, slot);
	return slot;
}

export function refreshComponent<P>(
	moduleFile: string,
	id: string,
	body: (props: P) => NeonNode,
	sigFn: SigFn,
): void {
	const key = keyOf(moduleFile, id);
	const type = refreshTypeKey(body);
	slotTypes.set(key, type);
	const slot = componentSlot<P>(key, type, body, sigFn);
	slot.body = body;
	slot.sigFn = sigFn;
}

export function refreshComponent0(
	moduleFile: string,
	id: string,
	body: () => NeonNode,
	sigFn: SigFn,
): void {
	refreshComponent<boolean>(moduleFile, id, (unused: boolean): NeonNode => body(), sigFn);
}

export function refreshBoundary<P>(
	moduleFile: string,
	id: string,
	body: (props: P) => NeonNode,
	sigFn: SigFn,
	props: P,
): NeonNode {
	const key = keyOf(moduleFile, id);
	const type = refreshTypeKey(body);
	const slot = componentSlot<P>(key, type, body, sigFn);
	const render = (): NeonNode => slot.body(props);
	return instanceNode(compInstances, moduleFile, key, type, render, (): string => slot.sigFn());
}

export function refreshBoundary0(
	moduleFile: string,
	id: string,
	body: () => NeonNode,
	sigFn: SigFn,
): NeonNode {
	return refreshBoundary<boolean>(
		moduleFile,
		id,
		(unused: boolean): NeonNode => body(),
		sigFn,
		false,
	);
}

export function refreshTemplate<P, E>(
	moduleFile: string,
	id: string,
	fn: (env: E) => NeonNode,
	sigFn: SigFn,
	setup: (props: P) => E,
): void {
	const key = keyOf(moduleFile, id);
	const type = refreshTypeKey(fn);
	slotTypes.set(key, type);
	const slot = templateSlot<E>(key, type, fn, sigFn);
	slot.fn = fn;
	slot.sigFn = sigFn;
}

export function refreshTemplate0<E>(
	moduleFile: string,
	id: string,
	fn: (env: E) => NeonNode,
	sigFn: SigFn,
	setup: () => E,
): void {
	const key = keyOf(moduleFile, id);
	const type = refreshTypeKey(fn);
	slotTypes.set(key, type);
	const slot = templateSlot<E>(key, type, fn, sigFn);
	slot.fn = fn;
	slot.sigFn = sigFn;
}

export function refreshRegion<E>(
	moduleFile: string,
	id: string,
	fn: (env: E) => NeonNode,
	sigFn: SigFn,
	env: E,
): NeonNode {
	const key = keyOf(moduleFile, id);
	const type = refreshTypeKey(fn);
	const slot = templateSlot<E>(key, type, fn, sigFn);
	const render = (): NeonNode => slot.fn(env);
	return instanceNode(tmplInstances, moduleFile, key, type, render, (): string => slot.sigFn());
}

export function refreshKeep<T>(key: string, read: () => T, write: (value: T) => void): void {
	const inst = mounting;
	if (inst === null) { return; }
	const type = refreshTypeKey(read);
	let nth = 0;
	for (const earlier of inst.live) {
		if (earlier.key === key) { nth += 1; }
	}
	let seen = 0;
	for (const kept of inst.saved) {
		if (kept.key !== key) { continue; }
		if (seen === nth && kept.type === type) {
			runWithOwner(null, (): number => { write((kept.cell as StateCell<T>).value); return 0; });
		}
		seen += 1;
	}
	const cell = new StateCell<T>(read, untrack(read));
	inst.live.push({ key: key, type: type, cell: cell, show: (): string => `${untrack(cell.read)}` });
	inst.captures.push((): void => { cell.value = untrack(cell.read); });
}

export function refreshState<T>(key: string, get: Accessor<T>, set: Setter<T>): void {
	refreshKeep<T>(key, (): T => get(), (value: T): void => { set(value); });
}

let done: Listeners<RefreshDone> | null = null;
let failures: Listeners<RefreshFailure> | null = null;

export function onRefreshDone(fn: (r: RefreshDone) => void): Unsubscribe {
	const list = done ?? listeners<RefreshDone>();
	done = list;
	return list.add(fn);
}

export function onRefreshFailed(fn: (f: RefreshFailure) => void): Unsubscribe {
	const list = failures ?? listeners<RefreshFailure>();
	failures = list;
	return list.add(fn);
}

function reported(scope: string, name: string, started: number, summary: RefreshSummary): RefreshSummary {
	const list = done;
	if (list !== null && summary.rebuilt + summary.remounted > 0) { list.emit({ scope, name, summary, ms: performance.now() - started }); }
	return summary;
}

export function refreshModule(moduleFile: string): RefreshSummary {
	return reported("module", moduleFile, performance.now(), patchModule(moduleFile, []));
}

export function refreshModuleEval(
	moduleFile: string,
	moduleSig: string,
	dependents: string[],
): RefreshSummary {
	const started = performance.now();
	const previous = moduleSigs.get(moduleFile);
	moduleSigs.set(moduleFile, moduleSig);
	if (previous === undefined || previous !== moduleSig) { return reported("module", moduleFile, started, patchModule(moduleFile, [])); }
	const forced: string[] = [];
	for (const id of dependents) { forced.push(keyOf(moduleFile, id)); }
	return reported("module", moduleFile, started, patchModule(moduleFile, forced));
}

export function refreshImports(moduleFile: string, imported: string, ids: string[]): void {
	let keys = importers.get(imported);
	if (keys === undefined) {
		keys = [];
		importers.set(imported, keys);
	}
	for (const id of ids) {
		const key = keyOf(moduleFile, id);
		if (keys.indexOf(key) < 0) { keys.push(key); }
	}
}

export function refreshDependency(moduleKey: string): RefreshSummary {
	const started = performance.now();
	const keys = importers.get(moduleKey);
	if (keys === undefined) { return { kept: 0, rebuilt: 0, remounted: 0 }; }
	const comps: Instance[] = [];
	const tmpls: Instance[] = [];
	for (const key of keys) {
		const c = compInstances.get(key);
		if (c !== null) { for (const inst of c) { comps.push(inst); } }
		const t = tmplInstances.get(key);
		if (t !== null) { for (const inst of t) { tmpls.push(inst); } }
	}
	const boundaries = patch(compInstances, comps, keys);
	const regions = patch(tmplInstances, tmpls, keys);
	return reported("dependency", moduleKey, started, { kept: boundaries[0] + regions[0], rebuilt: regions[1], remounted: boundaries[1] });
}

function sourceName(id: string): string {
	const bar = id.indexOf("|");
	return bar < 0 ? id : id.substring(0, bar);
}

export function refreshMounted(): MountedComponent[] {
	const out: MountedComponent[] = [];
	for (const list of compInstances.values()) {
		for (const inst of list) {
			if (isDisposed(inst.owner)) { continue; }
			const state: KeptValue[] = [];
			for (const kept of inst.live) {
				const name = sourceName(kept.key);
				let key = name;
				for (let n = 2; state.some((k: KeptValue): boolean => k.key === key); n += 1) { key = `${name}#${n}`; }
				state.push({ key, value: kept.show() });
			}
			out.push({ name: sourceName(inst.key.substring(inst.keyFile.length + 1)), module: inst.keyFile, broken: inst.broken, state });
		}
	}
	return out;
}

export function refreshReset(): void {
	compSlots.clear();
	tmplSlots.clear();
	compInstances.clear();
	tmplInstances.clear();
	slotTypes.clear();
	pending.clear();
	moduleSigs.clear();
	importers.clear();
}
