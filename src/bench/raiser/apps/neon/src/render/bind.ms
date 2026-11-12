import { createRenderEffect } from "../core/effect";
import { Cleanup } from "../core/types";
import { untrack } from "../core/signal";
import { getOwner, isServer, asServer } from "../core/runtime";
import { runWithOwner } from "../core/owner";
import { NotReadyError } from "../core/types";
import { Hole, ServerContext, ServerMarks, serverContext, withServerContext } from "../core/serverContext";
import { Style, StyleValue, setStyleField, emptyStyle } from "./style";
import { Host, HostNode } from "./hostTypes";

// A dynamic spot re-runs whenever a source signal changes, but a derived expression
// often maps several source values onto the SAME output ("big"/"small", a formatted
// count). Writing it again is a host touch that changes nothing, so the last written
// value is kept and an identical one is dropped.
export function bindText(host: Host, node: HostNode, get: () => string): void {
	if (isServer()) { serverText(host, node, get); return; }
	followText(host, node, get);
}

// A pending read in a text spot leaves a hole when a window is open (a Loading's content or the root pass):
// the writer keeps a marker and the thunk runs again once its source settles. With no window open the read
// throws to the boundary above, which mounts its content again.
function serverText(host: Host, node: HostNode, get: () => string): void {
	let value = "";
	try {
		value = untrack(get);
	} catch (e) {
		const ctx = serverContext();
		if (ctx === null || ctx.holes === null || ctx.marks === null || !(e instanceof NotReadyError)) { throw e; }
		const hole = new Hole(ctx.holeCount.toString(), get, getOwner(), (e as NotReadyError).source);
		ctx.holeCount += 1;
		(ctx.marks as ServerMarks).pend(node, hole);
		(ctx.holes as Hole[]).push(hole);
		return;
	}
	host.setText(node, value);
}

export const HOLES_DONE = 0;
export const HOLES_WAIT = 1;
export const HOLES_FAILED = 2;

// Runs the holes that have no text yet under the owner each spot was made in. A hole that throws anything
// but a pending read gives up the hole channel, so the content is mounted again and the boundary above it catches the error.
export function runHoles(ctx: ServerContext, holes: Hole[]): int32 {
	return asServer((): int32 => withServerContext(ctx, (): int32 => {
		let state = HOLES_DONE;
		for (const h of holes) {
			if (h.value !== null) { continue; }
			try {
				h.value = runWithOwner(h.owner, (): string => untrack(h.get));
			} catch (e) {
				if (!(e instanceof NotReadyError)) { return HOLES_FAILED; }
				h.source = (e as NotReadyError).source;
				state = HOLES_WAIT;
			}
		}
		return state;
	}));
}

function followText(host: Host, node: HostNode, get: () => string): void {
	let prev = "";
	let bound = false;
	createRenderEffect<string>(
		(last: string | null): string => get(),
		(v: string, before: string | null): Cleanup | null => {
			if (bound && v === prev) { return null; }
			bound = true;
			prev = v;
			host.setText(node, v);
			return null;
		},
		{ transparent: true },
	);
}

export function writeAttr(host: Host, node: HostNode, name: string, value: string | null): void {
	if (value === null) {
		host.removeAttr(node, name);
	} else {
		host.setAttr(node, name, value);
	}
}

export function bindAttr(host: Host, node: HostNode, name: string, get: () => string | null): void {
	if (isServer()) { writeAttr(host, node, name, untrack(get)); return; }
	followAttr(host, node, name, get);
}

function followAttr(host: Host, node: HostNode, name: string, get: () => string | null): void {
	let prev: string | null = null;
	let bound = false;
	createRenderEffect<string | null>(
		(last: string | null): string | null => get(),
		(v: string | null, before: string | null): Cleanup | null => {
			if (bound && v === prev) { return null; }
			bound = true;
			prev = v;
			writeAttr(host, node, name, v);
			return null;
		},
		{ transparent: true },
	);
}

function writeStyleProp(host: Host, node: HostNode, own: Style, name: string, v: StyleValue): void {
	const setProp = host.setStyleProp;
	if (setProp !== null) { setProp(node, name, v); return; }
	setStyleField(own, name, v);
	host.setStyle(node, own);
}

export function bindStyleProp(host: Host, node: HostNode, own: Style, name: string, get: () => StyleValue): void {
	if (isServer()) { writeStyleProp(host, node, own, name, untrack(get)); return; }
	followStyleProp(host, node, own, name, get);
}

function followStyleProp(host: Host, node: HostNode, own: Style, name: string, get: () => StyleValue): void {
	let prev: StyleValue = null;
	let bound = false;
	createRenderEffect<StyleValue>(
		(last: StyleValue): StyleValue => get(),
		(v: StyleValue, before: StyleValue): Cleanup | null => {
			if (bound && v === prev) { return null; }
			bound = true;
			prev = v;
			writeStyleProp(host, node, own, name, v);
			return null;
		},
		{ transparent: true },
	);
}

function noBreakpointTable(s: Style): Style {
	throw new Error("a style carries media blocks but no breakpoint table was loaded: build the table with createBreakpoints from src/render/breakpoints");
}

let mediaResolve: (s: Style) => Style = noBreakpointTable;
let mediaFollow: (host: Host, node: HostNode, s: Style) => void = (host: Host, node: HostNode, s: Style): void => {
	host.setStyle(node, mediaResolve(s));
};

export function installMediaBinding(follow: (host: Host, node: HostNode, s: Style) => void, resolve: (s: Style) => Style): void {
	mediaFollow = follow;
	mediaResolve = resolve;
}

export function applyStaticStyle(host: Host, node: HostNode, s: Style): void {
	const setCls = host.setStyleClass;
	const id = s.cssId;
	if (id !== null && setCls !== null) {
		setCls(node, id as string, s.css === null ? "" : s.css as string);
	} else if (s.media === null) {
		host.setStyle(node, s);
	} else if (isServer()) {
		host.setStyle(node, mediaResolve(s));
	} else { mediaFollow(host, node, s); }
}

// One effect re-applying the whole style (reactive variant selection, layered
// calls — any style EXPRESSION that reads a signal). Per-property precision is
// impossible here: which fields the result carries is only known per run, and
// a field can fall back to an earlier layer when deselected, so the effect
// hands the fresh merge to setStyle each time. A sheet entry on a host with a
// stylesheet goes through its class instead, so a rule the inline style would
// outrank (a breakpoint's) still applies; switching between the two channels
// clears the one left behind.
export function bindStyleAll(host: Host, node: HostNode, get: () => Style): void {
	if (isServer()) { applyStaticStyle(host, node, untrack(get)); return; }
	followStyleAll(host, node, get);
}

function followStyleAll(host: Host, node: HostNode, get: () => Style): void {
	const setCls = host.setStyleClass;
	let classed = false;
	let inlined = false;
	createRenderEffect<Style>(
		(last: Style | null): Style => {
			const s = get();
			if (s.media === null || (s.cssId !== null && setCls !== null)) { return s; }
			return mediaResolve(s);
		},
		(s: Style, before: Style | null): Cleanup | null => {
			const id = s.cssId;
			if (id !== null && setCls !== null) {
				if (inlined) { host.setStyle(node, emptyStyle()); inlined = false; }
				setCls(node, id as string, s.css === null ? "" : s.css as string);
				classed = true;
				return null;
			}
			if (classed && setCls !== null) { setCls(node, "", ""); classed = false; }
			host.setStyle(node, s);
			inlined = true;
			return null;
		},
		{ transparent: true },
	);
}

export function setupRef<T>(setup: () => T): T {
	if (getOwner() === null) {
		throw new Error("a ref directive factory ran with no owner, so its onCleanup and effects would never be disposed: mount the element inside render() or a component");
	}
	return untrack(setup);
}

export function applyRef<T>(target: T, fn: (target: T) => void): void {
	if (isServer()) { return; }
	untrack((): void => { fn(target); });
}

export function composeRefs<T>(fns: (((target: T) => void) | null)[]): (target: T) => void {
	return (target: T): void => {
		for (const fn of fns) {
			if (fn !== null) { (fn as (target: T) => void)(target); }
		}
	};
}
