interface CallbackResult { value: float64; }

function propertyValue<T>(props: { value: T }): T { return props.value; }

function callbackValue<T>(props: { pick: (value: T) => float64 }): float64 { return props.pick(0 as T); }

function renderItems<T>(props: { each: () => T[]; pick: (value: T) => float64 }): CallbackResult {
	return { value: props.pick(props.each()[0]) };
}

function invokeComponent<P>(component: (props: P) => CallbackResult, props: P): CallbackResult {
	const render = () => component(props);
	return render();
}

function optionalItems<T>(props: { each: () => T[]; label?: string }): float64 {
	const label = props.label;
	return props.each().length + (label ? label.length : 0);
}

function directValue<T>(value: T): T { return value; }

function OptionalCallbackFor<T>(props: { each: () => T[]; children: (item: T) => string; fallback?: string | null }): string {
	const fb = props.fallback;
	return props.children(props.each()[0]) + (fb == null ? "" : fb);
}

function OptionalCallbackForIdx<T>(props: { each: () => T[]; children: (item: T, index: () => number) => string; fallback?: string | null }): string {
	return props.children(props.each()[1], () => 1);
}

function optionalCallbackCreateComponent<P>(Comp: (props: P) => string, props: P): string {
	return Comp(props);
}

const optionalCallbackXs: number[] = [7, 8];

function comp<P>(f: (p: P) => number, props: P): number { return f(props); }

function GRow<T>(props: { each: () => T[]; children: (x: T, i: number) => number }): number { return props.children(props.each()[1], 7); }

type GenericLiteralV = (h: number) => number;

function genericLiteralIdx<T>(props: {
	each: () => T[];
	children: (item: T, index: number) => GenericLiteralV;
	fallback?: GenericLiteralV | null;
}): number {
	const xs = props.each();
	const fb = props.fallback;
	if (fb === null) { return props.children(xs[0], 0)(1); }
	return (fb as GenericLiteralV)(2);
}

test "genericCallbacks: literal and callback inference carry concrete values through generic consumers" {
	assert propertyValue({ value: 7 }) == 7;
	assert propertyValue<float64>({ value: 9 }) == 9;
	assert directValue("concrete") == "concrete";
	assert callbackValue({ pick: (value: float64) => value + 1 }) == 1;
	const items: float64[] = [1, 2, 3];
	const direct = renderItems({ each: () => items, pick: (value: float64) => value + 1 });
	const deferred = invokeComponent(renderItems, { each: () => items, pick: (value: float64) => value + 2 });
	assert direct.value == 2;
	assert deferred.value == 3;
}

test "genericCallbacks: higher-order literal fitting initializes omitted optional fields" {
	const items: float64[] = [4, 5];
	const result = invokeComponent(
		(props: { each: () => float64[]; label?: string }) => ({ value: optionalItems(props) }),
		{ each: () => items });
	assert result.value == 2;
	assert optionalItems({ each: () => items, label: "tag" }) == 5;
}

test "genericCallbacks: a generic call accepts a literal that omits an optional field" {
	assert OptionalCallbackFor({ each: () => optionalCallbackXs, children: (item: number) => "item " + item.toString() }) == "item 7";
}

test "genericCallbacks: the omitted optional field reads as null" {
	assert OptionalCallbackFor({ each: () => optionalCallbackXs, children: (item: number) => "x", fallback: "!" }) == "x!";
	assert OptionalCallbackFor({ each: () => optionalCallbackXs, children: (item: number) => "x" }) == "x";
}

test "genericCallbacks: a generic function passed as a value takes the same literal" {
	assert optionalCallbackCreateComponent(OptionalCallbackFor, { each: () => optionalCallbackXs, children: (item: number) => "item " + item.toString() }) == "item 7";
}

test "genericCallbacks: a two-parameter callback field still binds T" {
	assert OptionalCallbackForIdx({ each: () => optionalCallbackXs, children: (item: number, i: () => number) => item.toString() + "@" + i().toString() }) == "8@1";
}

test "genericCallbacks: unannotated row parameters take the instantiated field types" {
	const r = comp(GRow, { each: (): number[] => [1, 2], children: (x, i) => x * 10 + i });
	assert r === 27, "r=" + r.toString();
}

test "genericCallbacks: a partially annotated row keeps the annotation and types the rest" {
	const r = comp(GRow, { each: (): number[] => [1, 2], children: (x: number, i) => x * 10 + i });
	assert r === 27, "r=" + r.toString();
}

test "genericCallbacks: a synthesized Maybe wrap is not re-wrapped by the instantiated re-check" {
	const a = genericLiteralIdx<number>({
		each: () => [7, 8],
		children: (item, i) => { return (h: number): number => h + item; },
	});
	const b = genericLiteralIdx<number>({
		each: () => [9],
		children: (item, i) => { return (h: number): number => h + item; },
		fallback: (h: number): number => h * 100,
	});
	assert a === 8, "a=" + a.toString();
	assert b === 200, "b=" + b.toString();
}
