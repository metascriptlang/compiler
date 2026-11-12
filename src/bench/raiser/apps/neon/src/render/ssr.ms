import { Accessor, accessor } from "../core/signal";
import { sanitized } from "../core/serverContext";

export { SafeError } from "../core/serverContext";

// server/signals.ts:3535 ssrSanitizeError: a build without `debug` hands the fallback one generic Error per caught error
export function serverCaught(error: Error): Accessor<Error> {
	const wire = sanitized(error);
	return accessor((): Error => wire);
}

export struct SsrMarkup {
	html: string;
	css: string;
	head: string;
	records: string;
}

export interface StreamSink {
	write: (chunk: string) => void;
	end: () => void;
}

when (server) {
	import { Host, HostNode, NeonNode } from "./hostTypes";
	import { render } from "./host";
	import { NeonEvent } from "./event";
	import { collectCss, cssIds, registerCss } from "./sheet";
	import { styleToCss } from "./css";
	import { Style, StyleValue, emptyStyle, setStyleField } from "./style";
	import {
		CONTROL_CSS,
		CONTROL_RULES_ID,
		ControlAttr,
		LINES_CLASS,
		SERVED_HEAD,
		controlAttr,
		webFixedAttrs,
		ScrollLook,
		TEXT_CSS,
		TEXT_RULES_ID,
		clampedLines,
		linesClass,
		linesRule,
		scrollLook,
		scrollLookCss,
		webBaseClass,
		webControlClass,
		webHtmlTag,
		webRules,
		WebRule,
		CAMERA_MIRROR_CLASS,
		VIDEO_CLASS,
		VIDEO_COVER_CLASS,
		VIDEO_STRETCH_CLASS,
		frameDocument,
		domAttrName,
		BLUR_PREFIX,
		IMAGE_CLASS,
		IMAGE_TAG,
		TILE_PREFIX,
		blurRule,
		svgPrefix,
		tileRule,
		domAttrValue,
		ariaGroupNames,
		ariaGroupValues,
		ariaStateRole,
	} from "./web";
	import { svgMarkup } from "../components/svg/markup";
	import { parseVisibleContent } from "./visibleContent";
	import { asServer } from "../core/runtime";
	import { Computation, Dispose, NotReadyError } from "../core/types";
	import { ServerContext, Fragments, Hole, Rules, ServerMarks, MAX_PASSES, withServerContext, pendingWaits, unconverged } from "../core/serverContext";
	import { scriptLiteral } from "./hydrationRecords";
	import { HOLES_FAILED, runHoles } from "./bind";

	function joinClass(className: string, id: string): string {
		return className === "" ? id : className + " " + id;
	}

	function baseClassOf(tag: string): string {
		if (tag === "image") { return IMAGE_CLASS; }
		const base = webBaseClass(tag);
		const control = webControlClass(tag);
		return base === "" || control === "" ? base + control : base + " " + control;
	}

	function entityOf(c: int32, quoted: boolean): string {
		return match (c) {
			38 => "&amp;",
			60 => "&lt;",
			62 => "&gt;",
			34 => quoted ? "&quot;" : "",
			39 => quoted ? "&#39;" : "",
			_ => "",
		};
	}

	function escaped(value: string, quoted: boolean): string {
		let out = "";
		let last = 0;
		const n = value.length;
		for (let i = 0; i < n; i += 1) {
			const c = value.charCodeAt(i);
			if (c > 62 || c < 34) { continue; }
			const e = entityOf(c, quoted);
			if (e === "") { continue; }
			out = out + value.slice(last, i) + e;
			last = i + 1;
		}
		if (last === 0) { return value; }
		return out + value.slice(last);
	}

	function escapeText(value: string): string {
		return escaped(value, false);
	}

	function escapeAttribute(value: string): string {
		return escaped(value, true);
	}

	function scriptOrStyle(tag: string): string {
		const name = tag.toLowerCase();
		return name === "script" || name === "style" ? name : "";
	}

	// The parser decodes no entity inside <script> or <style>, so their text is written
	// as is; a "<script" or "<style" in it, which could end the element, gets its first
	// letter escaped the way the script or the style reads it back.
	function rawText(name: string, text: string): string {
		let out = "";
		let last = 0;
		let at = text.indexOf("<");
		while (at >= 0) {
			const from = at + 1 < text.length && text.charCodeAt(at + 1) === 47 ? at + 2 : at + 1;
			if (namedAt(text, from, name)) {
				const upper = text.charCodeAt(from) === 83;
				const letter = name === "style" ? (upper ? "\\53 " : "\\73 ") : (upper ? "\\u0053" : "\\u0073");
				out = out + text.slice(last, from) + letter;
				last = from + 1;
			}
			at = text.indexOf("<", at + 1);
		}
		if (last === 0) { return text; }
		return out + text.slice(last);
	}

	function startsAt(text: string, at: int32, prefix: string): boolean {
		return text.slice(at, at + prefix.length) === prefix;
	}

	function withoutPlaceholder(name: string, text: string): string {
		if (text.indexOf("pl-") < 0) { return text; }
		const lt = name === "style" ? "\\3c " : "\\u003c";
		let out = "";
		let last = 0;
		let at = text.indexOf("<");
		while (at >= 0) {
			if (startsAt(text, at, PLACEHOLDER_OPEN) || startsAt(text, at, PLACEHOLDER_END)) {
				out = out + text.slice(last, at) + lt;
				last = at + 1;
			}
			at = text.indexOf("<", at + 1);
		}
		if (last === 0) { return text; }
		return out + text.slice(last);
	}

	function namedAt(text: string, at: int32, name: string): boolean {
		if (at + name.length > text.length) { return false; }
		for (let i = 0; i < name.length; i += 1) {
			if ((text.charCodeAt(at + i) | 32) !== name.charCodeAt(i)) { return false; }
		}
		return true;
	}

	function voidTag(tag: string): boolean {
		return match (tag.toLowerCase()) {
			"area" | "base" | "br" | "col" | "embed" | "hr" | "img" | "input" |
			"link" | "meta" | "param" | "source" | "track" | "wbr" => true,
			_ => false,
		};
	}

	function rawTextTag(tag: string): boolean {
		return match (tag.toLowerCase()) {
			"script" | "style" | "textarea" | "title" => true,
			_ => false,
		};
	}

	function attrValue(names: string[], values: string[], name: string): string | null {
		const at = names.indexOf(name);
		return at < 0 ? null : values[at];
	}

	function flagOr(names: string[], values: string[], name: string, absent: boolean): boolean {
		const v = attrValue(names, values, name);
		if (v === null) { return absent; }
		return v === "" || v === "true";
	}

	function scrollOf(names: string[], values: string[]): ScrollLook {
		const keeps = attrValue(names, values, "maintainVisibleContentPosition");
		return scrollLook(
			attrValue(names, values, "horizontal") === "true",
			flagOr(names, values, "scrollEnabled", true),
			flagOr(names, values, "showsHorizontalScrollIndicator", true),
			flagOr(names, values, "showsVerticalScrollIndicator", true),
			attrValue(names, values, "refreshEnabled") === "true",
			keeps !== null && parseVisibleContent(keeps as string) !== null,
		);
	}

	function putAttribute(names: string[], values: string[], name: string, value: string | null): void {
		const at = names.indexOf(name);
		if (value === null) {
			if (at >= 0) { names.splice(at, 1); values.splice(at, 1); }
			return;
		}
		if (at >= 0) { values[at] = value as string; return; }
		names.push(name);
		values.push(value as string);
	}

	function upsertAttr(names: string[], values: string[], name: string, value: string): void {
		const at = names.indexOf(name);
		if (at >= 0) { values[at] = value; return; }
		names.push(name);
		values.push(value);
	}

	function removeAttr(names: string[], values: string[], name: string): void {
		const at = names.indexOf(name);
		if (at < 0) { return; }
		names.splice(at, 1);
		values.splice(at, 1);
	}

	function textareaBody(names: string[], values: string[]): string {
		const value = attrValue(names, values, "value");
		const initial = attrValue(names, values, "defaultValue");
		const text = value !== null && value !== "" ? value as string : initial === null ? "" : initial as string;
		return text.startsWith("\n") ? "\n" + escapeText(text) : escapeText(text);
	}

	function elementMarkup(
		wire: string,
		info: TagInfo,
		names: string[],
		values: string[],
		className: string,
		style: Style | null,
		inner: string,
		childCount: int32,
	): string {
		const tag = info.html;
		let cls = className;
		let scroll = "";
		if (wire === "scrollview") {
			const look = scrollOf(names, values);
			scroll = scrollLookCss(look);
			if (look.hideHorizontal) { cls = cls + " neon-hide-horizontal"; }
			if (look.hideVertical) { cls = cls + " neon-hide-vertical"; }
		}
		let open = "<" + tag;
		if (names.length > 0) {
			const outNames: string[] = [];
			const outValues: string[] = [];
			let role = "";
			for (let i = 0; i < names.length; i += 1) {
				if (names[i] === "role" || names[i] === "accessibilityRole") { role = values[i]; }
			}
			role = ariaStateRole(role, tag);
			for (let i = 0; i < names.length; i += 1) {
				const raw = values[i];
				const group = ariaGroupNames(names[i]);
				if (group.length > 0) {
					const grouped = ariaGroupValues(names[i], raw, role);
					for (let k = 0; k < group.length; k += 1) {
						putAttribute(outNames, outValues, group[k], grouped[k]);
					}
					continue;
				}
				const control = controlAttr(wire, names[i], raw);
				if (control !== null) {
					const written = control as ControlAttr;
					if (written.name !== "") {
						putAttribute(outNames, outValues, written.name, written.value === null ? null : escapeAttribute(written.value as string));
					}
					continue;
				}
				const mapped = domAttrValue(names[i], raw);
				let v = mapped === null ? "" : escapeAttribute(mapped as string);
				if (mapped !== null && names[i] === "class" && cls !== "") { v = v === "" ? cls : v + " " + cls; cls = ""; }
				putAttribute(outNames, outValues, domAttrName(names[i]), mapped === null ? null : v);
			}
			for (let i = 0; i < outNames.length; i += 1) {
				open = open + " " + outNames[i] + "=\"" + outValues[i] + "\"";
			}
		}
		if (cls !== "") { open = open + " class=\"" + cls + "\""; }
		const inline = (style === null ? "" : styleToCss(style as Style)) + scroll;
		if (inline !== "") { open = open + " style=\"" + escapeAttribute(inline) + "\""; }
		if (info.empty) {
			if (childCount > 0) {
				throw new Error("SSR void element '" + tag + "' cannot have children");
			}
			return open + ">";
		}
		if (wire === "multilinetextinput") { return open + ">" + textareaBody(names, values) + "</" + tag + ">"; }
		return open + ">" + inner + "</" + tag + ">";
	}

	// What the markup needs from a wire tag, worked out once per tag.
	class TagInfo {
		html: string;
		baseClass: string;
		rules: WebRule[];
		fixedNames: string[] = [];
		fixedValues: string[] = [];
		empty: boolean;
		marked: boolean;
		raw: string;

		constructor(tag: string) {
			this.html = tag === "image" ? IMAGE_TAG : webHtmlTag(tag);
			this.baseClass = escapeAttribute(baseClassOf(tag));
			this.rules = webRules(tag);
			if (tag === "image") { this.rules.push({ id: CONTROL_RULES_ID, css: CONTROL_CSS }); }
			for (const fixed of webFixedAttrs(tag)) {
				this.fixedNames.push(fixed.name);
				this.fixedValues.push(fixed.value as string);
			}
			this.empty = voidTag(this.html);
			this.marked = !rawTextTag(this.html);
			this.raw = scriptOrStyle(this.html);
		}
	}

	const TAGS = new Map<string, TagInfo>();

	function tagInfo(tag: string): TagInfo {
		const known = TAGS.get(tag);
		if (known !== null) { return known; }
		const info = new TagInfo(tag);
		TAGS.set(tag, info);
		return info;
	}

	const PLACEHOLDER_OPEN = "<template id=\"pl-";
	const PLACEHOLDER_END = "<!--pl-";
	const EMPTY_TEXT = "<!---->";
	const TEXT_BREAK = "<!--!-->";

	function holeMark(h: Hole): string {
		return "<!--pl-#" + h.id + "-->";
	}

	function holeBreak(h: Hole): string {
		return "<!--pl-^" + h.id + "-->";
	}

	function headKey(tag: string, names: string[], values: string[]): string {
		if (tag === "title") { return "title"; }
		if (tag !== "meta") { return ""; }
		let named = attrValue(names, values, "name");
		const httpEquiv = attrValue(names, values, "http-equiv");
		const charset = attrValue(names, values, "charset");
		if (named === null) { named = attrValue(names, values, "property"); }
		if (named === null && httpEquiv === null && charset === null) { return ""; }
		return keyPart(named) + keyPart(httpEquiv) + keyPart(attrValue(names, values, "content")) +
			keyPart(charset) + keyPart(attrValue(names, values, "media"));
	}

	function keyPart(value: string | null): string {
		return value === null ? "\n-" : "\n+" + value;
	}

	// ---- The writer: each element becomes markup the moment it is placed ----
	//
	// A NeonNode on the server performs its host calls in document order: an element
	// gets its attributes, then its children, then is placed into its parent. The
	// writer keeps one record per node and, at placement, appends the node's markup to
	// its parent's body; nothing of the tree outlives that call. The two places that
	// put a node somewhere other than at the end of an open element get their own
	// node: the head root collects its children for the head block, and the overlay
	// root drops what a Portal mounts there.

	class SsrNode {
		tag: string;
		text: string = "";
		names: string[] = [];
		values: string[] = [];
		className: string = "";
		style: Style | null = null;
		body: string = "";
		count: int32 = 0;
		info: TagInfo;
		afterText: boolean = false;
		hole: Hole | null = null;
		held: Hole | null = null;
		parent: SsrNode | null = null;
		prev: SsrNode | null = null;
		next: SsrNode | null = null;
		last: SsrNode | null = null;
		at: int32 = 0;
		index: int32 = 0;
		textBefore: boolean = false;
		owed: int32 = 0;
		collects: boolean = false;
		drops: boolean = false;
		raw: string = "";

		constructor(tag: string, info: TagInfo) {
			this.tag = tag;
			this.info = info;
		}
	}

	const PLAIN = new TagInfo("");

	class SsrWrite {
		register: (id: string, css: string) => void;
		head: SsrNode = new SsrNode("head", PLAIN);
		overlay: SsrNode = new SsrNode("overlay", PLAIN);
		headKids: SsrNode[] = [];
		done: boolean = false;
		stitched: boolean = false;
		headFront: SsrNode | null = null;
		held: Rules | null = null;
		svgs: int32 = 0;

		constructor(register: (id: string, css: string) => void) {
			this.register = register;
			this.head.collects = true;
			this.overlay.drops = true;
		}

		note(id: string, css: string): void {
			const hold = this.held;
			if (hold === null) { this.register(id, css); return; }
			hold.ids.push(id);
			hold.css.push(css);
		}
	}

	function writable(n: SsrNode): SsrNode {
		if (n.parent !== null) {
			throw new Error("SSR writer: <" + n.tag + "> changed after it was written; the server writes each node once, in document order");
		}
		return n;
	}

	function collect(w: SsrWrite, p: SsrNode, n: SsrNode, ref: HostNode | null): void {
		n.parent = p;
		const kids = w.headKids;
		const at = ref === null ? -1 : kids.indexOf(ref as unknown as SsrNode);
		if (at < 0) { kids.push(n); } else { kids.splice(at, 0, n); }
		if (ref !== null && w.headFront === (ref as unknown as SsrNode)) { w.headFront = n; }
	}

	function writeInto(w: SsrWrite, p: SsrNode, n: SsrNode, ref: HostNode | null): void {
		if (n.held !== null && (p.drops || p.collects || p.info.raw !== "")) { throw new NotReadyError((n.held as Hole).source); }
		if (p.drops) { return; }
		if (p.collects) { collect(w, p, n, ref); return; }
		if (ref !== null) {
			throw new Error("SSR writer: <" + p.tag + "> got a child in front of another; the server writes in document order");
		}
		if (p.parent !== null) {
			throw new Error("SSR writer: <" + p.tag + "> got a child after it was written; the server writes each node once, in document order");
		}
		if (p.owed > 0) {
			throw new Error("SSR writer: a child of <" + p.tag + "> was removed from the middle; the server can only take back its last nodes");
		}
		if (n.parent !== null) {
			throw new Error("SSR writer: a node was placed into <" + p.tag + "> while it still stood elsewhere");
		}
		n.parent = p;
		n.at = p.body.length;
		n.index = p.count;
		n.textBefore = p.afterText;
		n.prev = p.last;
		n.next = null;
		if (p.last !== null) { (p.last as SsrNode).next = n; }
		p.last = n;
		p.count += 1;
		if (n.raw !== "") {
			p.body += n.raw;
			p.afterText = false;
			return;
		}
		if (n.hole !== null) {
			const h = n.hole as Hole;
			h.marked = p.info.marked;
			if (p.info.marked && p.afterText) {
				const before = n.prev;
				if (before !== null && (before as SsrNode).hole !== null) {
					h.lead = 2;
					h.after = (before as SsrNode).hole;
				} else {
					h.lead = 1;
				}
			}
			p.body += holeMark(h);
			p.afterText = true;
			if (p.held === null) { p.held = h; }
			return;
		}
		if (n.tag === "") {
			if (p.info.marked) {
				if (n.text === "") { p.body += EMPTY_TEXT; p.afterText = false; return; }
				if (p.afterText) {
					const before = n.prev;
					p.body += before !== null && (before as SsrNode).hole !== null ? holeBreak((before as SsrNode).hole as Hole) : TEXT_BREAK;
				}
			}
			p.body += p.info.raw === "" ? escapeText(n.text) : rawText(p.info.raw, w.stitched ? withoutPlaceholder(p.info.raw, n.text) : n.text);
			p.afterText = true;
			return;
		}
		p.body += elementMarkup(n.tag, n.info, n.names, n.values, n.className, n.style, n.body, n.count);
		n.body = "";
		p.afterText = false;
		if (n.held !== null && p.held === null) { p.held = n.held; }
	}

	// A region that re-renders on the server takes back the rows it just wrote, which
	// are the last children of their parent: removing one drops it and everything
	// written after it, and those later nodes are owed removals that must follow before
	// anything else is written there.
	function takeBack(p: SsrNode, n: SsrNode): void {
		if (n.parent !== p) {
			throw new Error("SSR writer: a node removed from <" + p.tag + "> is not its child");
		}
		n.parent = null;
		if (n.index >= p.count) {
			p.owed -= 1;
			return;
		}
		p.owed += p.count - n.index - 1;
		p.body = p.body.slice(0, n.at);
		p.count = n.index;
		p.afterText = n.textBefore;
		if (p.held !== null && p.body.indexOf("<!--pl-#") < 0) { p.held = null; }
		p.last = n.prev;
		if (n.prev !== null) { (n.prev as SsrNode).next = null; }
	}

	function withoutClassPrefix(className: string, prefix: string): string {
		const kept: string[] = [];
		for (const c of className.split(" ")) {
			if (!c.startsWith(prefix)) { kept.push(c); }
		}
		return kept.join(" ");
	}

	function retile(w: SsrWrite, n: SsrNode): void {
		n.className = withoutClassPrefix(n.className, TILE_PREFIX);
		const resize = attrValue(n.names, n.values, "data-resize");
		const src = attrValue(n.names, n.values, "src");
		if (resize !== "repeat" || src === null || src === "") { return; }
		const rule = tileRule(src as string);
		w.note(rule.id, rule.css);
		n.className = joinClass(n.className, rule.id);
	}

	function writeImageAttr(w: SsrWrite, n: SsrNode, name: string, value: string): boolean {
		if (name === "source") {
			upsertAttr(n.names, n.values, "src", value);
			retile(w, n);
			return true;
		}
		if (name === "resizeMode") {
			upsertAttr(n.names, n.values, "data-resize", value);
			retile(w, n);
			return true;
		}
		if (name === "blurRadius") {
			n.className = withoutClassPrefix(n.className, BLUR_PREFIX);
			const rule = blurRule(value);
			if (rule !== null) {
				const blur = rule as WebRule;
				w.note(blur.id, blur.css);
				n.className = joinClass(n.className, blur.id);
			}
			return true;
		}
		if (name === "accessibilityLabel") { upsertAttr(n.names, n.values, "alt", value); }
		return false;
	}

	function writeSvgList(n: SsrNode, list: string): void {
		const prefix = attrValue(n.names, n.values, "data-neon-svg");
		const m = svgMarkup(list, prefix === null ? "neon-svg" : prefix as string);
		putAttribute(n.names, n.values, "viewBox", m.viewBox === "" ? null : m.viewBox);
		putAttribute(n.names, n.values, "preserveAspectRatio", m.preserveAspectRatio === "" ? null : m.preserveAspectRatio);
		n.body = m.body;
	}

	function writeFrameSource(n: SsrNode, value: string): void {
		const fields = value.split("\x1f");
		if (fields[0] === "html") {
			const html = fields.length > 1 ? fields[1] : "";
			const base = fields.length > 2 ? fields[2] : "";
			upsertAttr(n.names, n.values, "srcdoc", frameDocument(html, base, attrValue(n.names, n.values, "interceptLoads") === "true"));
			return;
		}
		removeAttr(n.names, n.values, "srcdoc");
		upsertAttr(n.names, n.values, "src", fields.length > 1 ? fields[1] : "");
	}

	function placeMirror(n: SsrNode): void {
		n.className = withoutClassPrefix(n.className, CAMERA_MIRROR_CLASS);
		if (attrValue(n.names, n.values, "facing") === "front" || attrValue(n.names, n.values, "mirror") === "true") {
			n.className = joinClass(n.className, CAMERA_MIRROR_CLASS);
		}
	}

	function writerHost(w: SsrWrite): Host {
		return {
			createElement: (tag: string): HostNode => {
				const info = tagInfo(tag);
				const n = new SsrNode(tag, info);
				for (const rule of info.rules) { w.note(rule.id, rule.css); }
				n.className = info.baseClass;
				for (let i = 0; i < info.fixedNames.length; i += 1) {
					n.names.push(info.fixedNames[i]);
					n.values.push(info.fixedValues[i]);
				}
				if (tag === "svg") {
					w.svgs += 1;
					n.names.push("data-neon-svg");
					n.values.push(svgPrefix(w.svgs));
				}
				return n as unknown as HostNode;
			},
			createText: (s: string): HostNode => {
				const n = new SsrNode("", PLAIN);
				n.text = s;
				return n as unknown as HostNode;
			},
			setText: (node: HostNode, s: string): void => {
				writable(node as unknown as SsrNode).text = s;
			},
			setAttr: (node: HostNode, name: string, value: string): void => {
				const n = writable(node as unknown as SsrNode);
				if (n.tag === "image" && writeImageAttr(w, n, name, value)) { return; }
				if (n.tag === "svg" && name === "displayList") { writeSvgList(n, value); return; }
				if (n.tag === "webview" && name === "source") { writeFrameSource(n, value); return; }
				if (n.tag === "video" && name === "resizeMode") {
					n.className = withoutClassPrefix(n.className, VIDEO_CLASS + "-");
					if (value === "cover") { n.className = joinClass(n.className, VIDEO_COVER_CLASS); }
					if (value === "stretch") { n.className = joinClass(n.className, VIDEO_STRETCH_CLASS); }
					return;
				}
				if (name !== "numberOfLines") {
					upsertAttr(n.names, n.values, name, value);
					if (n.tag === "camera" && (name === "facing" || name === "mirror")) { placeMirror(n); }
					return;
				}
				w.note(TEXT_RULES_ID, TEXT_CSS);
				if (!clampedLines(value)) { return; }
				const rule = linesRule(value);
				w.note(rule.id, rule.css);
				n.className = joinClass(joinClass(n.className, LINES_CLASS), escapeAttribute(linesClass(value)));
			},
			removeAttr: (node: HostNode, name: string): void => {
				const n = writable(node as unknown as SsrNode);
				removeAttr(n.names, n.values, name);
			},
			setStyle: (node: HostNode, style: Style): void => {
				writable(node as unknown as SsrNode).style = style;
			},
			setStyleProp: (node: HostNode, name: string, value: StyleValue): void => {
				const n = writable(node as unknown as SsrNode);
				if (n.style === null) { n.style = emptyStyle(); }
				setStyleField(n.style as Style, name, value);
			},
			setStyleClass: (node: HostNode, id: string, css: string): void => {
				if (id === "") { return; }
				w.note(id, css);
				const n = writable(node as unknown as SsrNode);
				n.className = joinClass(n.className, escapeAttribute(id));
			},
			addEvent: (node: HostNode, name: string, handler: (e: NeonEvent) => void): void => {},
			append: (parent: HostNode, child: HostNode): void => {
				writeInto(w, parent as unknown as SsrNode, child as unknown as SsrNode, null);
			},
			insertBefore: (parent: HostNode, node: HostNode, ref: HostNode | null): void => {
				writeInto(w, parent as unknown as SsrNode, node as unknown as SsrNode, ref);
			},
			removeChild: (parent: HostNode, node: HostNode): void => {
				const p = parent as unknown as SsrNode;
				const n = node as unknown as SsrNode;
				if (p.drops) { return; }
				if (p.collects) {
					const at = w.headKids.indexOf(n);
					if (at >= 0) { w.headKids.splice(at, 1); }
					n.parent = null;
					return;
				}
				if (w.done) { return; }
				takeBack(p, n);
			},
			parentOf: (node: HostNode): HostNode | null => {
				const p = (node as unknown as SsrNode).parent;
				if (p === null) { return null; }
				return p as unknown as HostNode;
			},
			release: (node: HostNode): void => {
				if ((node as unknown as SsrNode).parent !== null) { throw "release: the node still has a parent; remove it first"; }
			},
			nextSibling: (node: HostNode): HostNode | null => {
				const n = node as unknown as SsrNode;
				const p = n.parent;
				if (p !== null && (p as SsrNode).collects) {
					const kids = w.headKids;
					const at = kids.indexOf(n);
					return at >= 0 && at + 1 < kids.length ? kids[at + 1] as unknown as HostNode : null;
				}
				return n.next === null ? null : n.next as unknown as HostNode;
			},
			firstChild: (node: HostNode): HostNode | null => {
				const n = node as unknown as SsrNode;
				if (n.drops) { return null; }
				if (!n.collects) {
					throw new Error("SSR writer: <" + n.tag + "> was read back as a tree; only the head root keeps its children");
				}
				if (w.headFront !== null) { return w.headFront as unknown as HostNode; }
				return w.headKids.length === 0 ? null : w.headKids[0] as unknown as HostNode;
			},
			cloneNode: null,
			voidArea: null,
			scrollTo: null,
			measureText: null,
			overlayRoot: (node: HostNode): HostNode => w.overlay as unknown as HostNode,
			headRoot: (node: HostNode): HostNode => w.head as unknown as HostNode,
		};
	}

	function writtenHead(kids: SsrNode[]): string {
		const seen = new Map<string, boolean>();
		let s = "";
		for (const k of kids) {
			if (k.tag === "") { continue; }
			const key = headKey(k.tag, k.names, k.values);
			if (key !== "") {
				if (seen.has(key)) { continue; }
				seen.set(key, true);
			}
			const names = k.names.slice(0, k.names.length);
			const values = k.values.slice(0, k.values.length);
			names.push(SERVED_HEAD);
			values.push("");
			s = s + elementMarkup(k.tag, k.info, names, values, k.className, k.style, k.body, k.count);
		}
		return s;
	}

	function writeRender(n: NeonNode, w: SsrWrite): SsrMarkup {
		const root = new SsrNode("ssr-root", PLAIN);
		const dispose = asServer((): Dispose => render(n, writerHost(w), root as unknown as HostNode, ""));
		try {
			return { html: root.body, css: "", head: writtenHead(w.headKids) };
		}
		finally {
			w.done = true;
			dispose();
		}
	}

	export function renderToString(n: NeonNode): string {
		return writeRender(n, new SsrWrite(registerCss)).html;
	}

	function registered(): Map<string, boolean> {
		const seen = new Map<string, boolean>();
		for (const id of cssIds()) { seen.set(id, true); }
		return seen;
	}

	function markupOf(n: NeonNode): SsrMarkup {
		const seen = registered();
		let css = collectCss();
		const w = new SsrWrite((id: string, rule: string): void => {
			if (seen.has(id)) { return; }
			seen.set(id, true);
			css = css + rule;
		});
		const markup = writeRender(n, w);
		return { html: markup.html, css: css, head: markup.head, records: "" };
	}

	export function renderToMarkup(n: NeonNode): SsrMarkup {
		return markupOf(n);
	}

	function recordScript(table: string, id: string, text: string): string {
		return "<script>(self._$HY||(self._$HY={r:{},e:{},m:{}}))." + table + "[\"" + scriptLiteral(id) + "\"]=\"" + scriptLiteral(text) + "\"</script>";
	}

	function recordScripts(ctx: ServerContext, written: Map<string, boolean> | null, listed: Map<string, boolean> | null): string {
		let out = "";
		for (const id of recordIds(ctx)) {
			const slot = ctx.slots.get(id);
			if (slot === null) { continue; }
			if (written !== null) {
				if (!slot.settled || written.has(id)) { continue; }
				written.set(id, true);
			}
			out += slot.failure === null ? recordScript("r", id, slot.json) : recordScript("e", id, (slot.failure as Error).message);
		}
		for (const [id, key] of ctx.modules) {
			if (listed !== null) {
				if (listed.has(id)) { continue; }
				listed.set(id, true);
			}
			out += recordScript("m", id, key);
		}
		return out;
	}

	function rawNode(markup: string): HostNode {
		const n = new SsrNode("", PLAIN);
		n.raw = markup;
		return n as unknown as HostNode;
	}

	export function rawHtml(markup: string): NeonNode {
		return (host: Host, parent: HostNode, before: HostNode | null): void => {
			if (markup !== "") { host.insertBefore(parent, rawNode(markup), before); }
		};
	}

	function textOf(h: Hole): string {
		if (h.value === null) { throw new Error("SSR writer: a hole was filled before its text was known"); }
		return h.value as string;
	}

	function holeText(h: Hole): string {
		const v = textOf(h);
		if (!h.marked) { return escapeText(v); }
		if (v === "") { return EMPTY_TEXT; }
		const breaks = h.lead === 1 || (h.lead === 2 && textOf(h.after as Hole) !== "");
		return (breaks ? TEXT_BREAK : "") + escapeText(v);
	}

	function swapped(markup: string, marker: string, text: string): string {
		const at = markup.indexOf(marker);
		if (at < 0) { return markup; }
		return markup.slice(0, at) + text + markup.slice(at + marker.length);
	}

	function stitchMarks(w: SsrWrite): ServerMarks {
		const fronts = new Map<string, SsrNode>();
		return {
			open: (id: string): unknown => {
				const front = new SsrNode("", PLAIN);
				const at = w.headFront === null ? 0 : w.headKids.indexOf(w.headFront as SsrNode);
				w.headKids.splice(at < 0 ? 0 : at, 0, front);
				fronts.set(id, front);
				return rawNode(PLACEHOLDER_OPEN + id + "\"></template>");
			},
			close: (id: string): unknown => rawNode(PLACEHOLDER_END + id + "-->"),
			holder: (beside: unknown): unknown => {
				const like = beside as SsrNode;
				if (like.last !== null && (like.last as SsrNode).hole !== null) { throw new NotReadyError(((like.last as SsrNode).hole as Hole).source); }
				const holder = new SsrNode(like.tag, like.info);
				holder.afterText = like.afterText;
				return holder;
			},
			html: (holder: unknown): string => (holder as SsrNode).body,
			rules: (hold: Rules | null): Rules | null => {
				const prev = w.held;
				w.held = hold;
				return prev;
			},
			replay: (hold: Rules): void => {
				for (let i = 0; i < hold.ids.length; i += 1) { w.note(hold.ids[i], hold.css[i]); }
			},
			pend: (node: unknown, hole: Hole): void => {
				const n = node as SsrNode;
				n.hole = hole;
				n.held = hole;
			},
			take: (first: unknown): string => {
				const n = first as SsrNode;
				return n.parent === null ? "" : (n.parent as SsrNode).body.slice(n.at);
			},
			kept: (markup: string, holes: Hole[]): Hole[] => {
				const live: Hole[] = [];
				for (const h of holes) { if (markup.indexOf(holeMark(h)) >= 0) { live.push(h); } }
				return live;
			},
			fill: (markup: string, holes: Hole[]): string => {
				let out = markup;
				for (const h of holes) {
					out = swapped(out, holeMark(h), holeText(h));
					out = swapped(out, holeBreak(h), h.marked && textOf(h) !== "" ? TEXT_BREAK : "");
				}
				return out;
			},
			within: (id: string, run: () => boolean): boolean => {
				const outer = w.headFront;
				w.headFront = fronts.get(id);
				try {
					return run();
				} finally {
					w.headFront = outer;
				}
			},
		};
	}

	function stitched(html: string, fragments: Fragments): string {
		let from = html.indexOf(PLACEHOLDER_OPEN);
		if (from < 0) { return html; }
		let out = "";
		let at = 0;
		while (from >= 0) {
			const idAt = from + PLACEHOLDER_OPEN.length;
			const idEnd = html.indexOf("\"></template>", idAt);
			const id = html.slice(idAt, idEnd);
			const end = PLACEHOLDER_END + id + "-->";
			const to = html.indexOf(end, idEnd);
			const settled = fragments.get(id);
			if (idEnd < 0 || to < 0 || settled === null) {
				throw new Error("SSR: the placeholder of boundary \"" + id + "\" has no settled content to take its place");
			}
			out = out + html.slice(at, from) + stitched(settled as string, fragments);
			at = to + end.length;
			from = html.indexOf(PLACEHOLDER_OPEN, at);
		}
		return out + html.slice(at);
	}

	class CssBook {
		seen: Map<string, boolean> = registered();
		css: string = collectCss();

		add(id: string, rule: string): void {
			if (this.seen.has(id)) { return; }
			this.seen.set(id, true);
			this.css = this.css + rule;
		}
	}

	class StreamPass {
		book: CssBook = new CssBook();
		write: SsrWrite;
		root: SsrNode = new SsrNode("ssr-root", PLAIN);
		holes: Hole[] = [];
		dispose: Dispose = (): void => {};

		constructor() {
			const book = this.book;
			this.write = new SsrWrite((id: string, rule: string): void => { book.add(id, rule); });
			this.write.stitched = true;
		}
	}

	function rootPending(ctx: ServerContext, pass: StreamPass, n: NeonNode): Computation | null {
		return withServerContext(ctx, (): Computation | null => {
			ctx.holes = pass.holes;
			try {
				pass.dispose = asServer((): Dispose => render(n, writerHost(pass.write), pass.root as unknown as HostNode, ""));
				return null;
			} catch (e) {
				if (e instanceof NotReadyError) { return (e as NotReadyError).source; }
				throw e;
			} finally {
				ctx.holes = null;
			}
		});
	}

	function unfilled(html: string): void {
		if (html.indexOf("<!--pl-#") >= 0 || html.indexOf("<!--pl-^") >= 0) { throw new Error("[SSR_HOLE_UNFILLED] a text spot's marker reached the page without its text"); }
	}

	function openSources(holes: Hole[]): Computation[] {
		const open: Computation[] = [];
		for (const h of holes) { if (h.value === null) { open.push(h.source); } }
		return open;
	}

	// The shell is written once every text spot the root pass left open has its text, as Solid's renderToStream
	// holds its shell for the root holes. False when a spot failed for a reason other than a pending read: the
	// root mounts again, so an Errored around that spot catches it.
	async function rootHoles(ctx: ServerContext, pass: StreamPass): Promise<boolean> {
		const marks = ctx.marks as ServerMarks;
		const holes = marks.kept(pass.root.body, pass.holes);
		let open = openSources(holes);
		let rounds = 1;
		while (open.length > 0) {
			if (rounds >= MAX_PASSES) { throw unconverged("the root's text spots"); }
			rounds += 1;
			for (const w of pendingWaits(ctx, open)) { await w; }
			if (runHoles(ctx, holes) === HOLES_FAILED) { return false; }
			open = openSources(holes);
		}
		pass.root.body = marks.fill(pass.root.body, holes);
		return true;
	}

	function recordIds(ctx: ServerContext): string[] {
		const ids = ctx.started.slice(0, ctx.started.length);
		ids.sort();
		return ids;
	}

	// Solid's REPLACE_SCRIPT cut to the swap: $df and $dfr as one function, with none of the hydration
	// route (_$HY.f), ledger (_$HY.v), announce (_$HY.fe), retry queue (_$HY.dq), $dfl, stylesheet gates or head ops
	const REPLACE_SCRIPT = "function $df(e,n,o,t){if(!(n=document.getElementById(e)))return 0;if(!(o=document.getElementById(\"pl-\"+e)))return 0;for(;o&&(8!==o.nodeType||o.nodeValue!==\"pl-\"+e);)t=o.nextSibling,o.remove(),o=t;o.replaceWith(n.content),n.remove();return 1}";

	class Piece {
		id: string;
		html: string;
		css: string;
		records: string;

		constructor(id: string, html: string, css: string, records: string) {
			this.id = id;
			this.html = html;
			this.css = css;
			this.records = records;
		}
	}

	export class StreamRender {
		ctx: ServerContext = new ServerContext();
		pass: StreamPass = new StreamPass();
		finished: Promise<void>;
		pieces: Piece[] = [];
		waitingIds: string[] = [];
		waitingHtml: string[] = [];
		sent: int32 = 0;
		cssSent: int32 = 0;
		recorded: Map<string, boolean> = new Map<string, boolean>();
		listed: Map<string, boolean> = new Map<string, boolean>();
		sink: StreamSink | null = null;
		consumer: string = "";
		scripted: boolean = false;
		readableView: unknown | null = null;
		over: boolean = false;
		ended: boolean = false;
		failure: Error | null = null;
		result: SsrMarkup = { html: "", css: "", head: "", records: "" };

		constructor(n: NeonNode) {
			this.finished = drive(this, n);
		}

		// A fragment swaps a placeholder the page must already hold: one that settles before the shell, or before the fragment its placeholder sits in, waits for it.
		placed(id: string): boolean {
			const marker = PLACEHOLDER_OPEN + id + "\"></template>";
			for (const piece of this.pieces) { if (piece.html.indexOf(marker) >= 0) { return true; } }
			return false;
		}

		cut(id: string, html: string): void {
			if (id !== "" && !this.placed(id)) {
				this.waitingIds.push(id);
				this.waitingHtml.push(html);
				return;
			}
			const css = this.pass.book.css;
			const fresh = css.slice(this.cssSent, css.length);
			this.cssSent = css.length;
			this.pieces.push(new Piece(id, html, fresh, recordScripts(this.ctx, this.recorded, this.listed)));
			this.flush();
			for (let i = 0; i < this.waitingIds.length; i += 1) {
				if (!this.placed(this.waitingIds[i])) { continue; }
				const next = this.waitingIds[i];
				const nextHtml = this.waitingHtml[i];
				this.waitingIds.splice(i, 1);
				this.waitingHtml.splice(i, 1);
				this.cut(next, nextHtml);
				return;
			}
		}

		chunkOf(piece: Piece): string {
			const style = piece.css === "" ? "" : "<style>" + piece.css + "</style>";
			if (piece.id === "") { return style + piece.html + piece.records; }
			const call = "$df(\"" + scriptLiteral(piece.id) + "\")";
			const script = this.scripted ? call : REPLACE_SCRIPT + ";" + call;
			this.scripted = true;
			return style + "<template id=\"" + piece.id + "\">" + piece.html + "</template>" + piece.records + "<script>" + script + "</script>";
		}

		flush(): void {
			if (this.sink === null || this.ended) { return; }
			const sink = this.sink as StreamSink;
			while (this.sent < this.pieces.length) {
				const piece = this.pieces[this.sent];
				this.sent += 1;
				sink.write(this.chunkOf(piece));
			}
			if (!this.over) { return; }
			this.ended = true;
			if (this.failure !== null) { console.error("renderToStream: the stream ended early: " + (this.failure as Error).message); }
			sink.end();
		}

		claim(name: string): void {
			if (this.consumer !== "") {
				throw new Error("renderToStream result was already consumed via `" + this.consumer + "`; cannot also consume it via `" + name + "`. Use exactly one of `pipe`, `pipeTo`, or `readable`.");
			}
			this.consumer = name;
		}

		attach(sink: StreamSink): void {
			this.sink = sink;
			this.flush();
		}

		pipe(sink: StreamSink): void {
			this.claim("pipe");
			this.attach(sink);
		}

		then<R>(onFulfilled: (markup: SsrMarkup) => R, onRejected?: (error: Error) => R): Promise<R> {
			return deliver<R>(this, onFulfilled, onRejected);
		}
	}

	async function deliver<R>(r: StreamRender, onFulfilled: (markup: SsrMarkup) => R, onRejected?: (error: Error) => R): Promise<R> {
		await r.finished;
		const failure = r.failure;
		if (failure !== null) {
			if (onRejected === undefined) { throw failure; }
			return onRejected(failure);
		}
		return onFulfilled(r.result);
	}

	when (js) {
		export extern class WritableStream {}
		export extern class ReadableStream {}
		export extern class TransformStream {
			readable: ReadableStream;
			writable: WritableStream;
		}
		export extern function newTransform(): TransformStream from "new TransformStream()";

		interface WebSink {
			write: (chunk: string) => void;
			end: () => void;
			closed: Promise<void>;
		}

		// A write still in flight when the lock is released is dropped by workerd, so end waits for the chain
		extern function webSink(w: WritableStream): WebSink from
			"((w) => { const writer = w.getWriter(); const encoder = new TextEncoder(); let tail = Promise.resolve(); let finish; const closed = new Promise((r) => { finish = r; }); return { write: (s) => { tail = tail.then(() => writer.write(encoder.encode(s))); tail.catch(() => {}); }, end: () => { tail = tail.then(() => { writer.releaseLock(); return w.close(); }); tail.then(finish, finish); }, closed }; })(#)";

		export function pipeTo(this r: StreamRender, w: WritableStream): Promise<void> {
			r.claim("pipeTo");
			const sink = webSink(w);
			r.attach(sink);
			return sink.closed;
		}

		export function readable(this r: StreamRender): ReadableStream {
			if (r.readableView !== null) { return r.readableView as ReadableStream; }
			r.claim("readable");
			const pair = newTransform();
			const sink = webSink(pair.writable);
			r.attach(sink);
			r.readableView = pair.readable as unknown;
			return pair.readable;
		}
	}

	async function drive(r: StreamRender, n: NeonNode): Promise<void> {
		const ctx = r.ctx;
		ctx.fragments.settled = (id: string): void => {
			if (ctx.failure === null) { r.cut(id, ctx.fragments.get(id) as string); }
		};
		try {
			ctx.marks = stitchMarks(r.pass.write);
			let rounds = 1;
			let pending = rootPending(ctx, r.pass, n);
			while (pending !== null || !(await rootHoles(ctx, r.pass))) {
				if (rounds >= MAX_PASSES) { throw unconverged("the render"); }
				if (pending !== null) { for (const w of pendingWaits(ctx, [pending as Computation])) { await w; } }
				r.pass = new StreamPass();
				ctx.marks = stitchMarks(r.pass.write);
				rounds += 1;
				pending = rootPending(ctx, r.pass, n);
			}
			unfilled(r.pass.root.body);
			r.cut("", r.pass.root.body);
			const pass = r.pass;
			let html = "";
			let head = "";
			try {
				for (let at = 0; at < ctx.loops.length; at += 1) { await ctx.loops[at]; }
				if (ctx.failure === null) {
					html = stitched(pass.root.body, ctx.fragments);
					unfilled(html);
					head = writtenHead(pass.write.headKids);
				}
			} finally {
				pass.write.done = true;
				pass.dispose();
			}
			if (ctx.failure !== null) { throw ctx.failure; }
			r.result = { html: html, css: pass.book.css, head: head, records: recordScripts(ctx, null, null) };
		} catch (e) {
			r.failure = e;
		}
		r.over = true;
		r.flush();
	}

	export function renderToStream(n: NeonNode): StreamRender {
		return new StreamRender(n);
	}
} else {
	import { Node } from "std/meta";

	export macro renderToString(node: Node): Node {
		error("renderToString needs a -d:server build", node);
	}

	export macro renderToMarkup(node: Node): Node {
		error("renderToMarkup needs a -d:server build", node);
	}

	export macro renderToStream(node: Node): Node {
		error("renderToStream needs a -d:server build", node);
	}

}
