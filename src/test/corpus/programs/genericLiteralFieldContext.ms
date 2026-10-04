// Parity program — an object literal passed to a generic call gives each
// property whose field does not mention the type parameter that field's
// declared type: an object literal, a number literal and a nested property,
// into a direct generic call and into a generic component passed through
// createComponent.
//
// @stdout: direct a 40x0 b 0.5 frame 7x9|component a 40x0 0.5|component b -|nested a 0.25 12x0
// @exit: 0

type Accessor<T> = distinct (() => T);
function accessor<T>(f: () => T): Accessor<T> { return f as Accessor<T>; }

interface Style {
	height?: number | null;
	width?: number | null;
}

function styleText(s: Style): string { return `${s.height ?? 0}x${s.width ?? 0}`; }

function createComponent<P>(Comp: (props: P) => string, props: P): string { return Comp(props); }

function measure<T>(o: { item: T; show: (item: T) => string; style: Accessor<Style>; frame: Style; inner: { item: T; ahead: Accessor<number> } }): string {
	return `direct ${o.show(o.item)} ${styleText(o.style())} ${o.show(o.inner.item)} ${o.inner.ahead() / 4} frame ${styleText(o.frame)}`;
}

function Boxed<T>(props: { data: () => T[]; show: (item: T) => string; style?: Accessor<Style> | null; ahead?: Accessor<number> | null }): string {
	const s = props.style;
	const a = props.ahead;
	const head = `component ${props.show(props.data()[0])}`;
	if (s == null || a == null) return `${head} -`;
	return `${head} ${styleText(s())} ${a() / 4}`;
}

function Nested<T>(props: { data: () => T[]; show: (item: T) => string; layout: { ahead: Accessor<number>; style: Accessor<Style> } }): string {
	return `nested ${props.show(props.data()[0])} ${props.layout.ahead() / 4} ${styleText(props.layout.style())}`;
}

const words: string[] = ["a", "b"];
const out: string[] = [];

out.push(measure({ item: "a", show: (w: string): string => w, style: accessor(() => ({ height: 40 })), frame: { height: 7, width: 9 }, inner: { item: "b", ahead: accessor(() => 2) } }));
out.push(createComponent(Boxed, { data: accessor(() => words), show: (w: string): string => w, style: accessor(() => ({ height: 40 })), ahead: accessor(() => 2) }));
out.push(createComponent(Boxed, { data: () => words.slice(1), show: (w: string): string => w }));
out.push(createComponent(Nested, { data: () => words, show: (w: string): string => w, layout: { ahead: accessor(() => 1), style: accessor(() => ({ height: 12 })) } }));
console.log(out.join("|"));
