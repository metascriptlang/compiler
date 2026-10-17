export interface Opts<C> {
	flag?: boolean | null;
	label?: ((value: C) => string | null) | null;
	before?: (() => boolean) | null;
}

export function libMake<C>(value: C, options: Opts<C> = {}): string {
	const flag = options.flag ?? true;
	const label = options.label;
	const before = options.before;
	return (flag ? "on" : "off") + (label === null ? " nolabel" : " label") + (before === null ? " nobefore" : " before");
}
