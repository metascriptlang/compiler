import { Host, HostNode, NeonNode, TextSpan } from "./hostTypes";
import { Style, emptyStyle } from "./style";
import { NeonEvent } from "./event";
import { Accessor } from "../core/signal";
import { createRenderEffect } from "../core/effect";
import { Cleanup } from "../core/types";

const SPAN_TOUCHES = ["onTouchStart", "onTouchMove", "onTouchEnd", "onTouchCancel"];

// A host without a paragraph capability lays spans out as nested Texts, kept by position.
function spanNodes(read: Accessor<TextSpan[]>): NeonNode {
	return (host: Host, parent: HostNode, before: HostNode | null): void => {
		const shown: HostNode[] = [];
		const words: HostNode[] = [];
		const styles: (Style | null)[] = [];
		let latest: TextSpan[] = [];
		createRenderEffect<TextSpan[]>((prev: TextSpan[] | null): TextSpan[] => read(), (spans: TextSpan[], prev: TextSpan[] | null): Cleanup | null => {
			latest = spans;
			for (let i = 0; i < spans.length; i += 1) {
				const s = spans[i];
				if (i >= shown.length) {
					const el = host.createElement("text");
					const word = host.createText(s.text);
					host.append(el, word);
					const at = i;
					host.addEvent(el, "onPress", (e: NeonEvent): void => {
						if (at >= latest.length) { return; }
						const press = latest[at].onPress;
						if (press !== null) { (press as (e: NeonEvent) => void)(e); }
					});
					for (const name of SPAN_TOUCHES) {
						host.addEvent(el, name, (e: NeonEvent): void => {
							if (at >= latest.length) { return; }
							const touch = latest[at].onTouch;
							if (touch !== null) { (touch as (name: string, e: NeonEvent) => void)(name, e); }
						});
					}
					host.insertBefore(parent, el, before);
					shown.push(el);
					words.push(word);
					styles.push(null);
				} else {
					host.setText(words[i], s.text);
				}
				const own: Style | null = s.style !== null ? s.style as Style : null;
				if (own !== styles[i]) {
					host.setStyle(shown[i], own !== null ? own as Style : emptyStyle());
					styles[i] = own;
				}
			}
			while (shown.length > spans.length) {
				host.removeChild(parent, shown.pop() as HostNode);
				words.pop();
				styles.pop();
			}
			return null;
		}, { transparent: true });
	};
}

export function paragraphChildren(kids: NeonNode | null, spans: Accessor<TextSpan[]> | null): NeonNode {
	return (host: Host, node: HostNode, before: HostNode | null): void => {
		const own = host.paragraph;
		if (own !== null) {
			(own as (host: Host, node: HostNode, before: HostNode | null, kids: NeonNode | null, spans: Accessor<TextSpan[]> | null) => void)(host, node, before, kids, spans);
			return;
		}
		if (spans !== null) { spanNodes(spans as Accessor<TextSpan[]>)(host, node, before); }
		else if (kids !== null) { (kids as NeonNode)(host, node, before); }
	};
}

// A label a framework site builds by hand: its one string goes through the host's paragraph where it has one.
export function setTextContent(host: Host, label: HostNode, s: string): void {
	const own = host.paragraph;
	if (own === null) {
		host.append(label, host.createText(s));
		return;
	}
	const word: NeonNode = (h: Host, parent: HostNode, before: HostNode | null): void => { h.append(parent, h.createText(s)); };
	(own as (host: Host, node: HostNode, before: HostNode | null, kids: NeonNode | null, spans: Accessor<TextSpan[]> | null) => void)(host, label, null, word, null);
}
