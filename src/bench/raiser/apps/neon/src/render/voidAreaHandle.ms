import { NeonEvent } from "./event";
import { RaiseError, createErrorRoute } from "../core/boundary";

export enum AreaKeyAction {
	Release,
	Press,
	Repeat,
}

export enum AreaKeyMod {
	Shift,
	Ctrl,
	Alt,
	Super,
	CapsLock,
	NumLock,
	ShiftRight,
	CtrlRight,
	AltRight,
	SuperRight,
}

export struct AreaKeyEvent {
	action: AreaKeyAction;
	key: int32;
	scancode: int32;
	mods: BitSet<AreaKeyMod>;
	consumedMods: BitSet<AreaKeyMod>;
	unshifted: int32;
	text: string;
}

export enum AreaPointerKind {
	Button,
	Motion,
	Wheel,
	Leave,
}

export struct AreaPointerEvent {
	kind: AreaPointerKind;
	pixelX: float64;
	pixelY: float64;
	button: int32;
	pressed: boolean;
	dx: float64;
	dy: float64;
	deltaMode: number;
	mods: BitSet<AreaKeyMod>;
}

export function setEventMods(ev: NeonEvent, mods: BitSet<AreaKeyMod>): void {
	ev.altKey = mods.has(AreaKeyMod.Alt);
	ev.ctrlKey = mods.has(AreaKeyMod.Ctrl);
	ev.metaKey = mods.has(AreaKeyMod.Super);
	ev.shiftKey = mods.has(AreaKeyMod.Shift);
	ev.mods = (mods as uint16) as number;
}

export struct AreaPreedit {
	text: string;
	cursor: int32;
}

export struct AreaResize {
	pixelWidth: int32;
	pixelHeight: int32;
	scale: float32;
}

export type Unsubscribe = () => void;

export interface VoidAreaHandle {
	pixelWidth: () => int32;
	pixelHeight: () => int32;
	scale: () => float32;
	onResize: (fn: (e: AreaResize) => void) => Unsubscribe;
	requestFrame: () => void;
	onKey: (fn: (e: AreaKeyEvent) => void) => Unsubscribe;
	onText: (fn: (text: string) => void) => Unsubscribe;
	onPreedit: (fn: (e: AreaPreedit) => void) => Unsubscribe;
	onPointer: (fn: (e: AreaPointerEvent) => void) => Unsubscribe;
	onFocus: (fn: (focused: boolean) => void) => Unsubscribe;
	setImeRect: (pixelX: int32, pixelY: int32, pixelW: int32, pixelH: int32) => void;
}

export interface Listeners<T> {
	add: (fn: (e: T) => void) => Unsubscribe;
	emit: (e: T) => void;
	clear: () => void;
}

interface Listener<T> {
	fn: (e: T) => void;
}

export function listeners<T>(): Listeners<T> {
	let entries: Listener<T>[] = [];
	return {
		add: (fn: (e: T) => void): Unsubscribe => {
			const entry: Listener<T> = { fn };
			entries.push(entry);
			return (): void => {
				const i = entries.indexOf(entry);
				if (i >= 0) { entries.splice(i, 1); }
			};
		},
		emit: (e: T): void => {
			const snapshot = entries.slice(0);
			for (const entry of snapshot) {
				if (entries.indexOf(entry) >= 0) { entry.fn(e); }
			}
		},
		clear: (): void => { entries = []; },
	};
}

export struct LayerAnchor {
	node: unknown;
	inText: boolean;
}

export interface AreaLayer {
	anchor: LayerAnchor;
	layout: (pixelWidth: int32, pixelHeight: int32) => void;
	prepare: (pixelWidth: int32, pixelHeight: int32) => void;
	draw: () => void;
	hit?: ((x: float32, y: float32, kind: AreaPointerKind, e: NeonEvent) => boolean) | null;
}

export interface AreaHub {
	handle: VoidAreaHandle;
	enter: (mount: () => void) => void;
	addLayer: (layer: AreaLayer) => Unsubscribe;
	layers: () => AreaLayer[];
	layoutLayers: (pixelWidth: int32, pixelHeight: int32) => void;
	prepareLayers: (due: AreaLayer[], pixelWidth: int32, pixelHeight: int32) => void;
	drawLayers: (before: (layer: AreaLayer) => void) => void;
	key: (e: AreaKeyEvent) => void;
	text: (text: string) => void;
	preedit: (e: AreaPreedit) => void;
	pointer: (e: AreaPointerEvent) => void;
	focus: (focused: boolean) => void;
	resize: (e: AreaResize) => void;
	close: () => void;
}

export interface AreaOps {
	initialPixelWidth: int32;
	initialPixelHeight: int32;
	requestFrame: () => void;
	setImeRect: (pixelX: int32, pixelY: int32, pixelW: int32, pixelH: int32) => void;
	enter?: ((mount: () => void) => void) | null;
}

class LayerGuard {
	raise: RaiseError | null = null;
	stopped: boolean = false;
}

function attempt(guard: LayerGuard, step: () => void): boolean {
	try {
		step();
		return true;
	} catch (e) {
		const raise = guard.raise;
		if (raise === null) { throw e; }
		guard.stopped = true;
		raise(e);
		return false;
	}
}

export function createAreaHub(ops: AreaOps): AreaHub {
	const keys = listeners<AreaKeyEvent>();
	const texts = listeners<string>();
	const preedits = listeners<AreaPreedit>();
	const pointers = listeners<AreaPointerEvent>();
	const focuses = listeners<boolean>();
	const resizes = listeners<AreaResize>();
	let width = ops.initialPixelWidth;
	let height = ops.initialPixelHeight;
	let scale: float32 = 1.0;
	let layers: AreaLayer[] = [];
	let guards: LayerGuard[] = [];
	const live = (layer: AreaLayer): LayerGuard | null => {
		const i = layers.indexOf(layer);
		return i < 0 || guards[i].stopped ? null : guards[i];
	};
	let prepared: AreaLayer[] = [];
	return {
		handle: {
			pixelWidth: (): int32 => width,
			pixelHeight: (): int32 => height,
			scale: (): float32 => scale,
			onResize: resizes.add,
			requestFrame: ops.requestFrame,
			onKey: keys.add,
			onText: texts.add,
			onPreedit: preedits.add,
			onPointer: pointers.add,
			onFocus: focuses.add,
			setImeRect: ops.setImeRect,
		},
		enter: ops.enter !== null ? ops.enter as (mount: () => void) => void : (mount: () => void): void => { mount(); },
		addLayer: (layer: AreaLayer): Unsubscribe => {
			const guard = new LayerGuard();
			guard.raise = createErrorRoute((): void => {
				guard.stopped = false;
				ops.requestFrame();
			});
			layers.push(layer);
			guards.push(guard);
			return (): void => {
				const i = layers.indexOf(layer);
				if (i >= 0) {
					layers.splice(i, 1);
					guards.splice(i, 1);
				}
			};
		},
		layers: (): AreaLayer[] => layers,
		layoutLayers: (pixelWidth: int32, pixelHeight: int32): void => {
			for (const layer of layers.slice(0)) {
				if (layers.indexOf(layer) >= 0) { layer.layout(pixelWidth, pixelHeight); }
			}
		},
		prepareLayers: (due: AreaLayer[], pixelWidth: int32, pixelHeight: int32): void => {
			prepared = [];
			for (const layer of due) {
				const guard = live(layer);
				if (guard === null) { continue; }
				if (attempt(guard, (): void => { layer.prepare(pixelWidth, pixelHeight); })) { prepared.push(layer); }
			}
		},
		drawLayers: (before: (layer: AreaLayer) => void): void => {
			const due = prepared;
			prepared = [];
			for (const layer of due) {
				const guard = live(layer);
				if (guard === null) { continue; }
				before(layer);
				attempt(guard, (): void => { layer.draw(); });
			}
		},
		key: keys.emit,
		text: texts.emit,
		preedit: preedits.emit,
		pointer: pointers.emit,
		focus: focuses.emit,
		resize: (e: AreaResize): void => {
			width = e.pixelWidth;
			height = e.pixelHeight;
			scale = e.scale;
			resizes.emit(e);
		},
		close: (): void => {
			keys.clear();
			texts.clear();
			preedits.clear();
			pointers.clear();
			focuses.clear();
			resizes.clear();
			layers = [];
			guards = [];
			prepared = [];
		},
	};
}
