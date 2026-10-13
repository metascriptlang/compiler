export function scaled(value: int32, factor: int32 = 3, offset: int32 = 1): int32 {
	return value * factor + offset;
}

export class Label {
	text: string;
	constructor(text: string = "none") {
		this.text = text;
	}
	show(prefix: string = "<", suffix: string = ">"): string {
		return prefix + this.text + suffix;
	}
}
