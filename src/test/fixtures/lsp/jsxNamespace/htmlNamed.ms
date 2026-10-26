export interface GlobalAttrs {
	/** Unique id of the element. */
	id: string;
}
export interface AnchorAttrs extends GlobalAttrs {
	/** The URL the link points to. */
	href: string;
}
export interface HtmlElements {
	/** The anchor element. https://developer.mozilla.org/docs/Web/HTML/Element/a */
	a: AnchorAttrs;
}
