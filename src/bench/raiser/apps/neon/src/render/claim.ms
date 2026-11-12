import { Host, HostNode } from "./hostTypes";
import { place, needsStartMarker } from "./reconcile";
import { Computation } from "../core/types";
import { getOwner, carriesId, getNextChildId } from "../core/runtime";

interface Open {
	node: HostNode;
	tag: string;
	last: HostNode | null;
	count: number;
}

interface Unsealed {
	parent: HostNode;
	anchor: HostNode;
}

interface Claim {
	host: Host;
	take: (parent: HostNode, after: HostNode | null, tag: string) => HostNode | null;
	open: Open[];
	paused: number;
	refused: string | null;
	unsealed: Unsealed[];
	createElement: (tag: string) => HostNode;
	createText: (s: string) => HostNode;
	append: (parent: HostNode, child: HostNode) => void;
	insertBefore: (parent: HostNode, node: HostNode, ref: HostNode | null) => void;
	cloneNode: ((node: HostNode) => HostNode) | null;
}

let active: Claim | null = null;

function reading(host: Host): Claim | null {
	const c = active;
	if (c === null || c.host !== host || c.paused > 0) { return null; }
	return c;
}

export function hydrating(): boolean {
	return active !== null;
}

export function claiming(host: Host): boolean {
	return reading(host) !== null;
}

export interface ClaimMark {
	depth: number;
	last: HostNode | null;
	count: number;
}

export function claimMark(host: Host): ClaimMark | null {
	const c = reading(host);
	if (c === null) { return null; }
	const top = c.open[c.open.length - 1];
	return { depth: c.open.length, last: top.last, count: top.count };
}

export function claimRewind(host: Host, mark: ClaimMark | null): void {
	const c = reading(host);
	if (c === null || mark === null) { return; }
	while (c.open.length > mark.depth) { c.open.pop(); }
	const top = c.open[c.open.length - 1];
	top.last = mark.last;
	top.count = mark.count;
}

function pathOf(c: Claim): string {
	let s = "the container";
	for (let i = 1; i < c.open.length; i += 1) { s = (i === 1 ? "" : s + " > ") + c.open[i].tag; }
	return s;
}

function refuse(c: Claim, message: string): void {
	when (debug) { throw new Error(message); } else {
		if (c.refused === null) {
			c.refused = message;
			c.paused += 1;
			for (let i = c.unsealed.length - 1; i >= 0; i -= 1) { c.append(c.unsealed[i].parent, c.unsealed[i].anchor); }
		}
	}
}

function claimNext(c: Claim, tag: string): HostNode | null {
	if (c.paused > 0) { return null; }
	const top = c.open[c.open.length - 1];
	const node = c.take(top.node, top.last, tag);
	if (node === null) {
		refuse(c, "hydrate: the page has no " + (tag === "" ? "text" : "<" + tag + ">") + " at child " + (top.count + 1).toString() + " of " + pathOf(c));
		return null;
	}
	top.last = node;
	top.count += 1;
	if (tag !== "") { c.open.push({ node: node as HostNode, tag, last: null, count: 0 }); }
	return node;
}

function leftover(c: Claim, o: Open): boolean {
	return o.count > 0 && c.host.nextSibling(o.last as HostNode) !== null;
}

function settled(c: Claim, parent: HostNode, node: HostNode): boolean {
	if (c.paused > 0) { return false; }
	let top = c.open[c.open.length - 1];
	if (top.node === node && c.open.length > 1) {
		if (leftover(c, top)) {
			refuse(c, "hydrate: the page has more children in " + pathOf(c) + " than the tree renders");
			return false;
		}
		c.open.pop();
		top = c.open[c.open.length - 1];
	}
	if (top.node !== parent) {
		refuse(c, "hydrate: a node read from " + pathOf(c) + " was placed into another parent");
		return false;
	}
	return true;
}

export function beginClaim(host: Host, container: HostNode): void {
	if (active !== null) { throw new Error("hydrate: another hydrate is still running"); }
	const take = host.claim;
	if (take === null) { throw new Error("hydrate: this host has no claim capability, so it cannot take over a page's nodes"); }
	const c: Claim = {
		host,
		take: take as (parent: HostNode, after: HostNode | null, tag: string) => HostNode | null,
		open: [{ node: container, tag: "", last: null, count: 0 }],
		paused: 0,
		refused: null,
		unsealed: [],
		createElement: host.createElement,
		createText: host.createText,
		append: host.append,
		insertBefore: host.insertBefore,
		cloneNode: host.cloneNode,
	};
	host.createElement = (tag: string): HostNode => {
		const node = claimNext(c, tag);
		return node !== null ? node as HostNode : c.createElement(tag);
	};
	host.createText = (s: string): HostNode => {
		const node = claimNext(c, "");
		return node !== null ? node as HostNode : c.createText(s);
	};
	host.append = (parent: HostNode, child: HostNode): void => {
		if (!settled(c, parent, child)) { c.append(parent, child); }
	};
	host.insertBefore = (parent: HostNode, node: HostNode, ref: HostNode | null): void => {
		if (!settled(c, parent, node)) { c.insertBefore(parent, node, ref); }
	};
	host.cloneNode = null;
	active = c;
}

export function claimRefusal(host: Host): string | null {
	const c = active;
	if (c === null || c.host !== host) { return null; }
	if (c.refused !== null) { return c.refused; }
	if (c.open.length > 1) {
		refuse(c, "hydrate: " + pathOf(c) + " was read from the page but never placed");
		return c.refused;
	}
	const root = c.open[0];
	const rest = root.last === null ? host.firstChild(root.node) : host.nextSibling(root.last as HostNode);
	if (rest !== null) { refuse(c, "hydrate: the page has more children in the container than the tree renders"); }
	return c.refused;
}

export function endClaim(host: Host): void {
	const c = active;
	if (c === null || c.host !== host) { return; }
	host.createElement = c.createElement;
	host.createText = c.createText;
	host.append = c.append;
	host.insertBefore = c.insertBefore;
	host.cloneNode = c.cloneNode;
	active = null;
}

export function unclaimed(host: Host, mount: () => void): void {
	const c = reading(host);
	if (c === null) { mount(); return; }
	c.paused += 1;
	try {
		mount();
	} finally {
		c.paused -= 1;
	}
}

export function regionAnchor(host: Host, parent: HostNode, before: HostNode | null): HostNode {
	if (needsStartMarker(parent)) { place(host, parent, host.createText(""), before); }
	const c = reading(host);
	if (c !== null) {
		const unsealed = c.createText("");
		c.unsealed.push({ parent, anchor: unsealed });
		return unsealed;
	}
	const anchor = host.createText("");
	place(host, parent, anchor, before);
	return anchor;
}

export function regionParent(host: Host, anchor: HostNode, region: string): HostNode {
	const p = host.parentOf(anchor);
	if (p === null) { throw new Error(region + ": the region's anchor has no parent at an update, so there is nowhere to put its rows"); }
	return p as HostNode;
}

export function sealRegion(host: Host, parent: HostNode, anchor: HostNode): void {
	const c = active;
	if (c === null || c.host !== host) { return; }
	const at = c.unsealed.findIndex((u: Unsealed): boolean => u.anchor === anchor);
	if (at < 0) { return; }
	const served = claimNext(c, "");
	c.unsealed.splice(at, 1);
	if (served === null) { return; }
	c.paused += 1;
	try {
		place(host, parent, anchor, served);
	} finally {
		c.paused -= 1;
	}
	host.removeChild(parent, served);
	c.open[c.open.length - 1].last = anchor;
}

// A ForList on the server writes its rows without the effect the client follows its
// list with; that effect's id slot is taken all the same, so every id after the list
// matches the client's.
export function skipRegionEffect(): void {
	const o = getOwner();
	if (carriesId(o)) { getNextChildId(o as Computation); }
}

export function serverRegionStart(host: Host, parent: HostNode, before: HostNode | null): void {
	if (needsStartMarker(parent)) { place(host, parent, host.createText(""), before); }
}

export function serverRegionEnd(host: Host, parent: HostNode, before: HostNode | null): void {
	place(host, parent, host.createText(""), before);
}
