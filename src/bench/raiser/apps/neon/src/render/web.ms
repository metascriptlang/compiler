import { VAttr, attr, htmlTagFor } from "./node";

export const VIEW_CLASS = "neon-view";
export const TEXT_CLASS = "neon-text";

export const RN_WEB_BASE_CSS =
	":where(.neon-view){align-content:flex-start;align-items:stretch;" +
	"background-color:transparent;border:0 solid black;box-sizing:border-box;display:flex;" +
	"flex-basis:auto;flex-direction:column;flex-shrink:0;list-style:none;margin:0;" +
	"min-height:0;min-width:0;padding:0;position:relative;text-decoration:none;z-index:0}" +
	":where(button.neon-view){font:inherit;color:inherit;text-align:inherit}" +
	":where(.neon-text){background-color:transparent;border:0 solid black;" +
	"box-sizing:border-box;list-style:none;margin:0;padding:0;position:relative;" +
	"text-decoration:none;white-space:pre-wrap;overflow-wrap:break-word}";

export const SERVED_HEAD = "data-neon-head";

export const SCROLL_CLASS = "neon-scrollview";
export const ACTIVITY_CLASS = "neon-activity";
export const TEXTAREA_CLASS = "neon-textarea";

export const SCROLL_CSS =
	`.${SCROLL_CLASS}{overflow-x:hidden;overflow-y:auto}.neon-hide-horizontal::-webkit-scrollbar:horizontal{height:0}.neon-hide-vertical::-webkit-scrollbar:vertical{width:0}@keyframes neon-refresh-spin{to{transform:rotate(360deg)}}.neon-refresh-indicator[aria-busy=true]{animation:neon-refresh-spin 1s linear infinite}`;

export const TEXTAREA_CSS = `.${TEXTAREA_CLASS}{field-sizing:content;resize:none}`;

export const CONTROL_RULES_ID = "neon-controls";

export const VIDEO_CLASS = "neon-video";
export const WEBVIEW_CLASS = "neon-webview";
export const CAMERA_CLASS = "neon-camera";
export const VIDEO_COVER_CLASS = "neon-video-cover";
export const VIDEO_STRETCH_CLASS = "neon-video-stretch";
export const CAMERA_MIRROR_CLASS = "neon-camera-mirror";
export const MEDIA_RULES_ID = "neon-media";
export const CAMERA_RULES_ID = "neon-camera";

export const MEDIA_CSS = `.${WEBVIEW_CLASS}{border:0;display:block;background:#ffffff}` +
	`.${VIDEO_CLASS}{display:block;background:#000000;object-fit:contain}` +
	`.${VIDEO_COVER_CLASS}{object-fit:cover}.${VIDEO_STRETCH_CLASS}{object-fit:fill}`;

export const CAMERA_CSS = `.${CAMERA_CLASS}{display:block;background:#000000;object-fit:cover}.${CAMERA_MIRROR_CLASS}{transform:scaleX(-1)}`;

export const FRAME_SANDBOX = "allow-same-origin allow-forms allow-popups";

// react-native-webview's page bridge: `window.ReactNativeWebView.postMessage(data)` reaches
// onMessage, and with `intercept` a link click asks onShouldStartLoadWithRequest first.
export function bridgeScript(intercept: boolean): string {
	let script = "(function(){window.ReactNativeWebView={postMessage:function(d){parent.postMessage(String(d),'*');}};";
	if (intercept) {
		script += "document.addEventListener('click',function(e){var a=e.target&&e.target.closest?e.target.closest('a[href]'):null;" +
			"if(!a||(a.target&&a.target!=='_self'))return;var h=a.href;if(!h||h.indexOf('javascript:')===0)return;" +
			"if(a.getAttribute('href').charAt(0)==='#')return;e.preventDefault();parent.postMessage({__neonLoad:h},'*');},true);";
	}
	return script + "})();";
}

export function frameDocument(html: string, baseUrl: string, intercept: boolean): string {
	const base = baseUrl !== "" ? `<base href="${baseUrl}">` : "";
	return `${base}<script>${bridgeScript(intercept).split("</").join("<\\/")}</script>${html}`;
}

export const CONTROL_CSS = ".neon-activity{box-sizing:border-box;border-radius:50%;border:3px solid currentColor;border-top-color:transparent;animation:neon-activity-spin 0.8s linear infinite;color:#999999}.neon-activity[data-animating=false]{animation:none}.neon-activity[data-animating=false]:not([data-hides=false]){visibility:hidden}@keyframes neon-activity-spin{to{transform:rotate(360deg)}}.neon-image{object-fit:cover}.neon-image[data-resize=contain]{object-fit:contain}.neon-image[data-resize=stretch]{object-fit:fill}.neon-image[data-resize=center]{object-fit:none}.neon-image:not([src]){visibility:hidden}";

export const LINES_CLASS = "neon-lines";
export const TEXT_RULES_ID = "neon-text-props";

export const TEXT_CSS = ".neon-lines{display:-webkit-box !important;-webkit-box-orient:vertical;overflow:hidden}.neon-clip{text-overflow:clip}.neon-select-none{user-select:none;-webkit-user-select:none}.neon-select-text{user-select:text;-webkit-user-select:text}";

export struct WebRule {
	id: string;
	css: string;
}

export function clampedLines(value: string): boolean {
	return value !== "" && value !== "0";
}

export function linesClass(value: string): string {
	return `neon-lines-${value}`;
}

export function linesRule(value: string): WebRule {
	return { id: linesClass(value), css: `.${linesClass(value)}{-webkit-line-clamp:${value}}` };
}

export function webHtmlTag(tag: string): string {
	return match (tag) {
		"scrollview" | "activityindicator" => "div",
		"switch" => "input",
		"multilinetextinput" => "textarea",
		"webview" => "iframe",
		"camera" => "video",
		_ => htmlTagFor(tag),
	};
}

export function webControlClass(tag: string): string {
	return match (tag) {
		"scrollview" => SCROLL_CLASS,
		"activityindicator" => ACTIVITY_CLASS,
		"multilinetextinput" => TEXTAREA_CLASS,
		"video" => VIDEO_CLASS,
		"webview" => WEBVIEW_CLASS,
		"camera" => CAMERA_CLASS,
		_ => "",
	};
}

export function webFixedAttrs(tag: string): VAttr[] {
	if (tag === "video") { return [attr("playsinline", "")]; }
	if (tag === "camera") { return [attr("playsinline", ""), attr("muted", ""), attr("autoplay", "")]; }
	if (tag === "switch") { return [attr("type", "checkbox"), attr("role", "switch")]; }
	return [];
}

export struct ControlAttr {
	name: string;
	value: string | null;
	color: string;
}

function flagAttribute(name: string, value: string): ControlAttr {
	return { name: name, value: value === "true" ? "" : null, color: "" };
}

function droppedAttribute(): ControlAttr {
	return { name: "", value: null, color: "" };
}

export function controlAttr(tag: string, name: string, value: string): ControlAttr | null {
	if (tag === "switch") {
		return match (name) {
			"value" => flagAttribute("checked", value),
			"disabled" => flagAttribute("disabled", value),
			"thumbColor" | "trackColorOn" | "trackColorOff" => droppedAttribute(),
			_ => null,
		};
	}
	if (tag === "activityindicator") {
		return match (name) {
			"animating" => ({ name: "data-animating", value: value, color: "" }),
			"hidesWhenStopped" => ({ name: "data-hides", value: value, color: "" }),
			"color" => ({ name: "", value: null, color: value }),
			_ => null,
		};
	}
	if (tag === "multilinetextinput" && (name === "value" || name === "defaultValue")) {
		return droppedAttribute();
	}
	if (tag === "video") {
		return match (name) {
			"source" => ({ name: "src", value: value, color: "" }),
			"repeat" => flagAttribute("loop", value),
			"controls" => flagAttribute("controls", value),
			"paused" | "muted" | "volume" | "rate" | "progressUpdateInterval" | "resizeMode" | "command" => droppedAttribute(),
			_ => null,
		};
	}
	if (tag === "webview") {
		return match (name) {
			"javaScriptEnabled" => ({ name: "sandbox", value: value === "false" ? FRAME_SANDBOX : null, color: "" }),
			"source" | "interceptLoads" | "loadDecision" | "command" => droppedAttribute(),
			_ => null,
		};
	}
	if (tag === "camera" && (name === "facing" || name === "flash" || name === "active" || name === "mirror" || name === "command")) {
		return droppedAttribute();
	}
	return null;
}

export function webRules(tag: string): WebRule[] {
	const rules: WebRule[] = [];
	if (webBaseClass(tag) !== "") { rules.push({ id: "neon-base", css: RN_WEB_BASE_CSS }); }
	match (tag) {
		"scrollview" => { rules.push({ id: SCROLL_CLASS, css: SCROLL_CSS }); },
		"multilinetextinput" => { rules.push({ id: TEXTAREA_CLASS, css: TEXTAREA_CSS }); },
		"switch" | "activityindicator" => { rules.push({ id: CONTROL_RULES_ID, css: CONTROL_CSS }); },
		"video" | "webview" => { rules.push({ id: MEDIA_RULES_ID, css: MEDIA_CSS }); },
		"camera" => { rules.push({ id: CAMERA_RULES_ID, css: CAMERA_CSS }); },
		_ => {},
	}
	return rules;
}

export struct ScrollLook {
	overflowX: string;
	overflowY: string;
	touchAction: string;
	scrollbarWidth: string;
	overscrollBehaviorY: string;
	overflowAnchor: string;
	hideHorizontal: boolean;
	hideVertical: boolean;
}

export function scrollLook(
	horizontal: boolean,
	enabled: boolean,
	horizontalIndicator: boolean,
	verticalIndicator: boolean,
	refreshEnabled: boolean,
	keepsVisibleContent: boolean,
): ScrollLook {
	return {
		overflowX: enabled && horizontal ? "auto" : "hidden",
		overflowY: enabled && !horizontal ? "auto" : "hidden",
		touchAction: enabled ? (horizontal ? "pan-x" : "pan-y") : "none",
		scrollbarWidth: !horizontalIndicator && !verticalIndicator ? "none" : "auto",
		overscrollBehaviorY: refreshEnabled ? "contain" : "",
		overflowAnchor: keepsVisibleContent ? "none" : "",
		hideHorizontal: !horizontalIndicator,
		hideVertical: !verticalIndicator,
	};
}

export function scrollLookCss(look: ScrollLook): string {
	let css = "overflow-x:" + look.overflowX + ";overflow-y:" + look.overflowY +
		";touch-action:" + look.touchAction + ";scrollbar-width:" + look.scrollbarWidth + ";";
	if (look.overscrollBehaviorY !== "") { css = css + "overscroll-behavior-y:" + look.overscrollBehaviorY + ";"; }
	if (look.overflowAnchor !== "") { css = css + "overflow-anchor:" + look.overflowAnchor + ";"; }
	return css;
}

export function webBaseClass(tag: string): string {
	return match (tag) {
		"view" | "holder" | "pressable" | "scrollview" | "svg" => VIEW_CLASS,
		"text" => TEXT_CLASS,
		_ => "",
	};
}

function ariaRole(role: string): string | null {
	return match (role) {
		"header" => "heading",
		"image" => "img",
		"adjustable" => "slider",
		"summary" => "region",
		"none" => "presentation",
		"togglebutton" => "button",
		"text" => null,
		_ => role,
	};
}

function inputMode(keyboardType: string): string {
	return match (keyboardType) {
		"numeric" | "number-pad" => "numeric",
		"decimal-pad" => "decimal",
		"phone-pad" => "tel",
		"email-address" => "email",
		"url" => "url",
		_ => "text",
	};
}

export const ARIA_STATE_NAMES: string[] = ["aria-checked", "aria-selected", "aria-disabled", "aria-busy", "aria-expanded", "aria-pressed"];

export function ariaStateRole(role: string, html: string): string {
	return role === "" && html === "button" ? "button" : role;
}

export function ariaStateValues(state: string, role: string): (string | null)[] {
	const tokens: string[] = state === "" ? [] : state.split(",");
	const has = (token: string): boolean => tokens.indexOf(token) >= 0;
	const checked = has("checked") ? "true" : has("unchecked") ? "false" : has("mixed") ? "mixed" : null;
	const toggles = role === "button" || role === "togglebutton";
	const pressed = has("selected") ? "true" : checked !== null ? checked : role === "togglebutton" ? "false" : null;
	return [
		toggles ? null : checked,
		toggles || !has("selected") ? null : "true",
		has("disabled") ? "true" : null,
		has("busy") ? "true" : null,
		has("expanded") ? "true" : has("collapsed") ? "false" : null,
		toggles ? pressed : null,
	];
}

export const ARIA_VALUE_NAMES: string[] = ["aria-valuemin", "aria-valuemax", "aria-valuenow", "aria-valuetext"];

// "min,max,now,text": the three numbers may be empty and the text, last, may hold commas.
export function ariaValueValues(value: string): (string | null)[] {
	const out: (string | null)[] = [];
	let rest = value;
	for (let i = 0; i < 3; i += 1) {
		const cut = rest.indexOf(",");
		const field = cut < 0 ? rest : rest.slice(0, cut);
		rest = cut < 0 ? "" : rest.slice(cut + 1);
		out.push(field === "" ? null : field);
	}
	out.push(rest === "" ? null : rest);
	return out;
}

// RN props that write several aria attributes at once; the other names write one.
export function ariaGroupNames(name: string): string[] {
	return match (name) {
		"accessibilityState" => ARIA_STATE_NAMES,
		"accessibilityValue" => ARIA_VALUE_NAMES,
		_ => [],
	};
}

export function ariaGroupValues(name: string, value: string, role: string): (string | null)[] {
	return name === "accessibilityValue" ? ariaValueValues(value) : ariaStateValues(value, role);
}

export function domAttrValue(name: string, value: string): string | null {
	return match (name) {
		"accessibilityRole" | "role" => ariaRole(value),
		"accessibilityLiveRegion" => value === "none" ? "off" : value,
		"accessibilityLabelledBy" => value.split(",").join(" "),
		"accessibilityElementsHidden" => value === "true" ? "true" : null,
		"importantForAccessibility" => value === "no-hide-descendants" ? "true" : null,
		"focusable" => value === "true" ? "0" : "-1",
		"accessibilityActions" => null,
		"editable" => value === "false" ? "" : null,
		"autoFocus" => value === "true" ? "" : null,
		"secureTextEntry" => value === "true" ? "password" : "text",
		"keyboardType" => inputMode(value),
		"autoCorrect" => value === "false" ? "off" : "on",
		"accessible" | "blurOnSubmit" | "multiline" | "placeholderTextColor" => null,
		_ => value,
	};
}

export function domAttrName(name: string): string {
	return match (name) {
		"accessibilityLabel" => "aria-label",
		"accessibilityHint" => "aria-description",
		"accessibilityRole" => "role",
		"accessibilityLiveRegion" => "aria-live",
		"accessibilityLabelledBy" => "aria-labelledby",
		"accessibilityElementsHidden" | "importantForAccessibility" => "aria-hidden",
		"accessibilityViewIsModal" => "aria-modal",
		"focusable" => "tabindex",
		"nativeID" => "id",
		"editable" => "readonly",
		"keyboardType" => "inputmode",
		"returnKeyType" => "enterkeyhint",
		"autoCapitalize" => "autocapitalize",
		"autoCorrect" => "autocorrect",
		"maxLength" => "maxlength",
		"autoFocus" => "autofocus",
		"secureTextEntry" => "type",
		_ => name,
	};
}

export const IMAGE_TAG = "img";
export const IMAGE_CLASS = "neon-image";
export const BLUR_PREFIX = "neon-blur-";
export const TILE_PREFIX = "neon-tile-";

export function svgPrefix(count: int32): string {
	return `neon-svg${count}`;
}

export function blurRule(radius: string): WebRule | null {
	const px = parseFloat(radius);
	if (!(px > 0)) { return null; }
	const id = `${BLUR_PREFIX}${Math.round(px * 10)}`;
	return { id: id, css: `.${id}{filter:blur(${px}px)}` };
}

function cssString(text: string): string {
	return text.split("\\").join("\\\\").split("\"").join("\\\"").split("\n").join("\\a ").split("<").join("\\3c ");
}

// A tile's class comes from its source, so the page and the browser name the same picture alike
// and a class on a served image never means another source. Two sources that hash alike share a
// class: the browser host refuses that at the second one.
function sourceKey(src: string): string {
	let h: int64 = 5381;
	for (let i = 0; i < src.length; i += 1) { h = (h * 33 + src.charCodeAt(i)) % 4294967296; }
	return h.toString();
}

export function tileRule(src: string): WebRule {
	const id = `${TILE_PREFIX}${sourceKey(src)}`;
	return { id: id, css: `.${id}{background-image:url("${cssString(src)}");background-repeat:repeat;object-position:-100000px 0}` };
}
