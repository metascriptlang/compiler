// Style — the portable style IR (docs/STYLE.md §3).
//
// Flat by design: one vocabulary covering layout + paint + text. Hosts project
// the subset they understand (docs/STYLE.md §5), so there is no ViewStyle /
// TextStyle split. This module must not import Yoga, void, or any host type.
//
// `null` means unset. Dimensions are `number | string`: a bare number is points,
// a string is "50%" or "auto".

import { styleInterfaceBody, setStyleFieldBody, mergeStyleBody } from "../macros/style/fields";

export type FlexDirection = "row" | "column" | "row-reverse" | "column-reverse";
export type Justify = "flex-start" | "flex-end" | "center" | "space-between" | "space-around" | "space-evenly";
export type Align = "auto" | "flex-start" | "flex-end" | "center" | "stretch" | "baseline";
export type PositionType = "static" | "relative" | "absolute" | "fixed" | "sticky";
export type Wrap = "nowrap" | "wrap" | "wrap-reverse";
export type Display = "flex" | "none" | "contents" | "block" | "inline" | "inline-block" | "inline-flex";
export type Overflow = "visible" | "hidden" | "scroll" | "clip" | "auto";
export type Direction = "inherit" | "ltr" | "rtl";
export type WritingDirection = "auto" | "ltr" | "rtl";
export type TextAlign = "auto" | "left" | "center" | "right" | "justify";
export type FontWeight = "normal" | "bold"
	| "100" | "200" | "300" | "400" | "500" | "600" | "700" | "800" | "900";
export type FontStyle = "normal" | "italic";
export type FontSizeAdjust = "none" | "from-font"
	| "ex-height from-font" | "cap-height from-font" | "ic-width from-font";
export type TextDecorationLine = "none" | "underline" | "line-through" | "underline line-through"
	| "overline" | "underline overline" | "overline line-through" | "underline overline line-through";
export type TextDecorationStyle = "solid" | "double" | "dotted" | "dashed" | "wavy";
export type BorderStyle = "solid" | "dotted" | "dashed";
export type BoxSizing = "border-box" | "content-box";
export type Isolation = "auto" | "isolate";
export type BackfaceVisibility = "visible" | "hidden";
export type UserSelect = "auto" | "none" | "text" | "contain" | "all";
export type TextTransform = "none" | "capitalize" | "uppercase" | "lowercase";
export type WhiteSpace = "normal" | "nowrap" | "pre" | "pre-wrap" | "pre-line" | "break-spaces";
export type ObjectFit = "cover" | "contain" | "fill" | "scale-down" | "none";
export type BorderCollapse = "collapse" | "separate";

styleInterfaceBody("block");

styleInterfaceBody(0);

// Every style field's value fits this one union: string-literal unions are
// strings at runtime, dimensions are number | string, null means unset. It is
// the wire type of the per-property channel (setStyleProp / VDynStyle).
export type StyleValue = number | string | null;

export function isBoldWeight(weight: FontWeight | null): boolean {
	return weight === "bold" || weight === "600" || weight === "700"
		|| weight === "800" || weight === "900";
}

export function emptyStyle(): Style {
	return {};
}

// The per-property write behind reactive style fields (docs/STYLE.md §6). One
// switch instead of 40 setters on every host; the enum-ish fields narrow from
// the wire union with a cast because the checker cannot see which names carry
// which member.
setStyleFieldBody(0);

// `style={[a, b, c]}` — later layers win at runtime when a layer is a sheet
// reference; all-literal arrays merge at expansion instead (element macro, S3).
export function layerStyles(layers: Style[]): Style {
	let acc = layers[0];
	for (let i = 1; i < layers.length; i += 1) {
		acc = mergeStyle(acc, layers[i]);
	}
	return acc;
}

// One layer of `style={[base, over]}`: a field set in `over` wins, an unset one
// falls through to `base`. Written field by field because unset is `null` rather
// than absence, so a copy cannot distinguish the two without naming each field.
mergeStyleBody(0);

function noBreakpointTable(base: Style, over: Style): StyleBlock[] {
	throw new Error("a style carries media blocks but no breakpoint table was loaded: build the table with createBreakpoints from src/render/breakpoints");
}

let layerMedia: (base: Style, over: Style) => StyleBlock[] = noBreakpointTable;

export function installMediaLayering(layer: (base: Style, over: Style) => StyleBlock[]): void {
	layerMedia = layer;
}

export function mergeMedia(base: Style, over: Style): StyleBlock[] | null {
	return base.media === null ? over.media : layerMedia(base, over);
}
