// Host abstraction — the renderer is platform-neutral; each platform supplies a
// Host adapter (DOM, native widgets, terminal, ...). A NeonNode performs the host
// ops itself, so rendering one is calling it.

import { VAttr, VEvent, attr } from "./node";
import { Style, StyleValue, emptyStyle, setStyleField } from "./style";
import { Host, HostNode, NeonNode, VoidArea, TextMeasure } from "./hostTypes";
import { NeonEvent, neonEvent, eventType } from "./event";
import { createRoot } from "../core/owner";
import { flush, resetErrorHalt } from "../core/runtime";
import { Dispose } from "../core/types";
import { AreaHub, createAreaHub } from "./voidAreaHandle";

export { Host, HostNode, NeonNode, VoidArea, TextMeasure } from "./hostTypes";
export { bindText, writeAttr, bindAttr, bindStyleProp, applyStaticStyle, bindStyleAll, applyRef, setupRef, composeRefs } from "./bind";

// @solidjs/web client.ts:395: a fresh mount in a debug build revives scheduling after an earlier uncaught error; a release build stays halted
export function render(node: NeonNode, host: Host, parent: HostNode, id: string | null = null): Dispose {
	when (debug) { resetErrorHalt(); }
	const dispose = createRoot((dispose) => {
		try {
			node(host, parent, null);
			return dispose;
		} catch (error) {
			dispose();
			throw error;
		}
	}, id);
	try {
		flush();
	} catch (error) {
		dispose();
		throw error;
	}
	return dispose;
}

// ---- Mock host: in-memory tree for tests/SSR (no browser needed) ----

export class MockNode {
	tag: string;
	text: string = "";
	children: MockNode[] = [];
	attrs: VAttr[] = [];
	events: VEvent[] = [];
	style: Style | null = null;
	className: string = "";
	parent: MockNode | null = null;
	scrollX: number = 0;
	scrollY: number = 0;
	scrollAnimated: boolean = false;
	holdsResponder: boolean = false;
	blocksNative: boolean = false;

	constructor(tag: string) {
		this.tag = tag;
	}
}

export function mockNode(tag: string): MockNode {
	return new MockNode(tag);
}

function childIndex(parent: MockNode, node: MockNode): number {
	for (let i = 0; i < parent.children.length; i += 1) {
		if (parent.children[i] === node) { return i; }
	}
	return -1;
}

function lastChildIndex(parent: MockNode, node: MockNode): number {
	for (let i = parent.children.length - 1; i >= 0; i -= 1) {
		if (parent.children[i] === node) { return i; }
	}
	return -1;
}

// Mirror DOM move semantics: inserting a node already in the tree first detaches it.
function detach(n: MockNode): void {
	const p = n.parent;
	if (p === null) { return; }
	const idx = childIndex(p, n);
	if (idx >= 0) { p.children.splice(idx, 1); }
	n.parent = null;
}

// Template instantiation copies structure + attrs + style, never event
// listeners — DOM cloneNode(true) has the same rule, and the mock is the
// differential oracle for it.
function cloneMock(n: MockNode): MockNode {
	const c = mockNode(n.tag);
	c.text = n.text;
	c.className = n.className;
	c.style = n.style;
	for (const a of n.attrs) { c.attrs.push(attr(a.name, a.value)); }
	for (const k of n.children) {
		const kc = cloneMock(k);
		kc.parent = c;
		c.children.push(kc);
	}
	return c;
}

let mockResponder: MockNode | null = null;

interface MockHub {
	outer: MockNode;
	hub: AreaHub;
}

const mockHubs: MockHub[] = [];

export function mockAreaHub(outer: MockNode): AreaHub {
	for (const m of mockHubs) {
		if (m.outer === outer) { return m.hub; }
	}
	throw new Error("mockAreaHub: this node opened no void area");
}

const MOCK_FONT_SIZE = 16;

export function mockHost(): Host {
	const overlay = mockNode("overlay");
	const head = mockNode("head");
	return {
		createElement: (tag: string): HostNode => mockNode(tag) as unknown as HostNode,
		createText: (s: string): HostNode => {
			const n = mockNode("");
			n.text = s;
			return n as unknown as HostNode;
		},
		setText: (node: HostNode, s: string): void => {
			(node as unknown as MockNode).text = s;
		},
		setAttr: (node: HostNode, name: string, value: string): void => {
			const n = node as unknown as MockNode;
			for (let i = 0; i < n.attrs.length; i += 1) {
				if (n.attrs[i].name === name) { n.attrs[i].value = value; return; }
			}
			n.attrs.push(attr(name, value));
		},
		removeAttr: (node: HostNode, name: string): void => {
			const n = node as unknown as MockNode;
			for (let i = 0; i < n.attrs.length; i += 1) {
				if (n.attrs[i].name === name) { n.attrs.splice(i, 1); return; }
			}
		},
		setStyle: (node: HostNode, style: Style): void => {
			(node as unknown as MockNode).style = style;
		},
		setStyleProp: (node: HostNode, name: string, value: StyleValue): void => {
			const n = node as unknown as MockNode;
			if (n.style === null) { n.style = emptyStyle(); }
			setStyleField(n.style as Style, name, value);
		},
		// The default mock stands in for a native host: no stylesheet, so a
		// sheet entry lands through setStyle exactly as it does on void or
		// terminal. A test that wants the browser's routing supplies its own.
		setStyleClass: null,
		addEvent: (node: HostNode, name: string, handler: (e: NeonEvent) => void): void => {
			(node as unknown as MockNode).events.push({ name, handler });
		},
		append: (parent: HostNode, child: HostNode): void => {
			const p = parent as unknown as MockNode;
			const c = child as unknown as MockNode;
			detach(c);
			c.parent = p;
			p.children.push(c);
		},
		insertBefore: (parent: HostNode, node: HostNode, ref: HostNode | null): void => {
			const p = parent as unknown as MockNode;
			const n = node as unknown as MockNode;
			let target: number = p.children.length;
			if (ref !== null) {
				target = lastChildIndex(p, ref as unknown as MockNode);
				if (target < 0) { throw new Error("insertBefore: the reference node is not a child of the parent"); }
			}
			const curIdx = n.parent === p ? childIndex(p, n) : -1;
			if (curIdx >= 0) {
				p.children.splice(curIdx, 1);
				if (curIdx < target) { target -= 1; }
			} else {
				detach(n);
			}
			n.parent = p;
			p.children.splice(target, 0, n);
		},
		removeChild: (parent: HostNode, node: HostNode): void => {
			const p = parent as unknown as MockNode;
			const n = node as unknown as MockNode;
			const idx = childIndex(p, n);
			if (idx < 0) { throw new Error("removeChild: the node is not a child of the parent"); }
			p.children.splice(idx, 1);
			n.parent = null;
		},
		parentOf: (node: HostNode): HostNode | null => {
			const p = (node as unknown as MockNode).parent;
			if (p === null) { return null; }
			return p as unknown as HostNode;
		},
		release: (node: HostNode): void => {
			if ((node as unknown as MockNode).parent !== null) { throw new Error("release: the node still has a parent; remove it first"); }
		},
		nextSibling: (node: HostNode): HostNode | null => {
			const n = node as unknown as MockNode;
			const p = n.parent;
			if (p === null) { return null; }
			const idx = childIndex(p, n);
			if (idx < 0 || idx + 1 >= p.children.length) { return null; }
			return p.children[idx + 1] as unknown as HostNode;
		},
		firstChild: (node: HostNode): HostNode | null => {
			const n = node as unknown as MockNode;
			if (n.children.length === 0) { return null; }
			return n.children[0] as unknown as HostNode;
		},
		cloneNode: (node: HostNode): HostNode => {
			return cloneMock(node as unknown as MockNode) as unknown as HostNode;
		},
		voidArea: (node: HostNode): VoidArea => {
			const outer = node as unknown as MockNode;
			const root = mockNode("voidroot");
			root.parent = outer;
			outer.children.push(root);
			const hub = createAreaHub({
				initialPixelWidth: 0,
				initialPixelHeight: 0,
				requestFrame: (): void => { outer.attrs.push(attr("frameRequested", "true")); },
				setImeRect: (pixelX: int32, pixelY: int32, pixelW: int32, pixelH: int32): void => {
					outer.attrs.push(attr("imeRect", pixelX.toString() + "," + pixelY.toString() + "," + pixelW.toString() + "," + pixelH.toString()));
				},
			});
			mockHubs.push({ outer, hub });
			return {
				host: mockHost(),
				root: root as unknown as HostNode,
				hub: hub,
				release: (): void => { outer.attrs.push(attr("released", "true")); },
			};
		},
		scrollTo: (node: HostNode, x: number, y: number, animated: boolean): void => {
			const n = node as unknown as MockNode;
			n.scrollX = x;
			n.scrollY = y;
			n.scrollAnimated = animated;
		},
		measureText: (text: string, style: Style): TextMeasure => {
			const size = style.fontSize !== null ? style.fontSize as number : MOCK_FONT_SIZE;
			return { width: text.length * size / 2, height: size * 5 / 4, ascender: size, descender: size / 4 };
		},
		focus: (node: HostNode, focused: boolean): void => {
			const n = node as unknown as MockNode;
			fireEvent(n, focused ? "onFocus" : "onBlur");
		},
		overlayRoot: (node: HostNode): HostNode => overlay as unknown as HostNode,
		headRoot: (node: HostNode): HostNode => head as unknown as HostNode,
		claim: (parent: HostNode, after: HostNode | null, tag: string): HostNode | null => {
			const p = parent as unknown as MockNode;
			const i = after === null ? 0 : childIndex(p, after as unknown as MockNode) + 1;
			if (i >= p.children.length || p.children[i].tag !== tag) { return null; }
			return p.children[i] as unknown as HostNode;
		},
		setResponder: (node: HostNode | null, blockNativeResponder: boolean): void => {
			const holder = mockResponder;
			if (holder !== null) {
				(holder as MockNode).holdsResponder = false;
				(holder as MockNode).blocksNative = false;
			}
			mockResponder = node === null ? null : node as unknown as MockNode;
			if (node === null) { return; }
			const n = node as unknown as MockNode;
			n.holdsResponder = true;
			n.blocksNative = blockNativeResponder;
		},
	};
}


// A native touch as the hosts deliver it: the touch event on the touched node
// and then on every ancestor, the same event each time.
export function fireTouch(node: MockNode, name: string, x: number, y: number, timeStamp: number): void {
	let at: MockNode | null = node;
	while (at !== null) {
		const e = neonEvent(eventType(name));
		e.x = x;
		e.y = y;
		e.timeStamp = timeStamp;
		fireEventWith(at as MockNode, name, e);
		at = (at as MockNode).parent;
	}
}

// Fire a recorded event by name (test helper — simulates a user interaction).
export function fireEvent(node: MockNode, name: string): void {
	fireEventWith(node, name, neonEvent(eventType(name)));
}

// The same dispatch, but the test supplies the event — how a handler reading
// `e.value` or `e.x` is pinned without a real browser.
export function fireEventWith(node: MockNode, name: string, e: NeonEvent): void {
	for (const h of node.events) {
		if (h.name === name) { h.handler(e); }
	}
}

export function mockToString(n: MockNode): string {
	if (n.tag === "") { return n.text; }
	let open = "<" + n.tag;
	for (const a of n.attrs) { open = open + " " + a.name + "=\"" + (a.value ?? "") + "\""; }
	let s = open + ">";
	for (const k of n.children) { s = s + mockToString(k); }
	return s + "</" + n.tag + ">";
}
