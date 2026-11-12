// What a handler receives. One flat struct, not a union of pointer/key/input
// events: a union would force every handler to narrow before reading anything,
// and BUGS.md §2 still has a bare-union-at-use-site hole on the C lane.
//
// A field a host cannot supply stays at its zero value rather than becoming
// nullable — `e.value` on a click is "", `e.x` on a keypress is 0. Handlers read
// what the event they subscribed to actually carries, so the zero is never
// ambiguous in practice, and no handler pays for narrowing.
//
// Adding a field here is backward compatible (hosts construct events, handlers
// only read them), so this starts deliberately small. Changing the ARITY of a
// handler is the expensive move, and that is what landing this does once.

export interface NeonEvent {
	type: string;   // "click", "input", "keydown" — the JSX name with "on" stripped
	timeStamp: number;
	value: string;  // the target's text value where it has one
	x: number;      // pointer position in host coordinates; the layout origin on onLayout; the content offset on onScroll
	y: number;
	width: number;  // the layout size on onLayout; the viewport size on onScroll
	height: number;
	contentWidth: number;
	contentHeight: number;
	key: string;    // logical key: "a", "A", "Enter"
	code: string;   // physical key, W3C KeyboardEvent.code: "KeyA", "Enter"
	altKey: boolean;
	ctrlKey: boolean;
	metaKey: boolean;
	shiftKey: boolean;
	repeat: boolean;
	isComposing: boolean;
	scancode: number;      // the platform's physical key code, as the window reports it
	mods: number;          // modifier bit set as the window reports it; the four *Key flags are the portable reading
	consumedMods: number;  // the modifiers that already shaped `key`/`text`
	unshifted: number;     // the code point the key makes with no modifier, 0 when none
	text: string;          // keydown: the text the key types; onTextInput: the committed text; onPreedit: the composing text
	cursor: number;        // onPreedit: the caret inside `text`, in UTF-16 units
	button: number;        // pointer events: the window's numbering, Ion's 1 left, 2 right, 3 middle; 0 when none is held
	pressed: boolean;      // pointer events: a button is held
	pointerOrigin: boolean;
	locationX: number;     // pointer events: x relative to the target, the deepest node the pointer hit (RN's locationX), in layout points
	locationY: number;
	deltaX: number;        // onWheel, in the unit deltaMode names, with Ion's signs: dy > 0 is away from the user
	deltaY: number;
	deltaMode: number;     // onWheel: DOM_DELTA_PIXEL for layout points (a touch pan, a trackpad), DOM_DELTA_LINE for wheel notches
	propagationStopped: boolean;
}

export const DOM_DELTA_PIXEL = 0;
export const DOM_DELTA_LINE = 1;

export function neonEvent(type: string): NeonEvent {
	return {
		type, timeStamp: 0, value: "", x: 0, y: 0, width: 0, height: 0, contentWidth: 0, contentHeight: 0, key: "", code: "",
		altKey: false, ctrlKey: false, metaKey: false, shiftKey: false, repeat: false, isComposing: false,
		scancode: 0, mods: 0, consumedMods: 0, unshifted: 0, text: "", cursor: 0,
		button: 0, pressed: false, pointerOrigin: false, locationX: 0, locationY: 0, deltaX: 0, deltaY: 0, deltaMode: DOM_DELTA_PIXEL,
		propagationStopped: false,
	};
}

export function stopPropagation(this e: NeonEvent): void {
	e.propagationStopped = true;
}

// "onPress" → "click". Every host derives the type the same way, so a handler
// comparing `e.type` sees one spelling everywhere.
export function eventType(name: string): string {
	if (name.length > 2 && name.charAt(0) === "o" && name.charAt(1) === "n") {
		return name.slice(2, name.length).toLowerCase();
	}
	return name.toLowerCase();
}
