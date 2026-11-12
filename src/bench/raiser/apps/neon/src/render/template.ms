// Template instantiation (docs/RENDER-MODEL.md, D4). A template is the STATIC
// skeleton of a subtree — elements, static attrs, placeholder slots — built once
// and duplicated per mount. On a host that can duplicate a subtree cheaply (DOM
// cloneNode) that turns N create/append calls per mount into one native copy plus
// a pointer walk; on a host that cannot (`cloneNode: null`) instantiate falls back
// to running the builder again, which is exactly the pre-template behaviour.
//
// The emitter (src/macros/ui/element.ms) computes each dynamic spot's path through
// the skeleton at COMPILE time and emits childOf/siblingOf steps — no runtime
// search, no per-mount allocation.

import { Host, HostNode, NeonNode } from "./hostTypes";
import { place } from "./reconcile";

export type TemplateBuilder = (host: Host) => HostNode;

export interface Template {
	build: TemplateBuilder;
	proto: HostNode | null;
	protoHost: Host | null;
}

export function createTemplate(build: TemplateBuilder): Template {
	return { build, proto: null, protoHost: null };
}

// The prototype is built lazily on first use and keyed to the host that built it:
// one template reused across two different hosts (mock in a test, DOM in the app)
// must not hand out the other host's nodes.
export function instantiate(t: Template, host: Host): HostNode {
	const cloner = host.cloneNode;
	if (cloner === null) { return t.build(host); }
	const clone = cloner;
	const cached = t.proto;
	if (cached === null || t.protoHost !== host) {
		const fresh = t.build(host);
		t.proto = fresh;
		t.protoHost = host;
		return clone(fresh);
	}
	return clone(cached);
}

// The shape element.ms emits: one template per element() evaluation, reused by
// every call of the returned mount closure. `wire` receives the fresh instance
// and plants the walk + effects for that instance.
export function mountTemplate(t: Template, wire: (host: Host, root: HostNode) => void): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const root = instantiate(t, host);
		wire(host, root);
		place(host, parent, root, before);
	};
}

// Walk steps. The path is static, so a missing node means the emitter and the
// builder disagree — a framework bug, not user error: fail loud.
export function childOf(host: Host, node: HostNode): HostNode {
	const c = host.firstChild(node);
	if (c === null) { throw new Error("template walk: expected a first child but the instantiated node has none"); }
	return c;
}

export function siblingOf(host: Host, node: HostNode): HostNode {
	const s = host.nextSibling(node);
	if (s === null) { throw new Error("template walk: expected a next sibling but the instantiated node has none"); }
	return s;
}
