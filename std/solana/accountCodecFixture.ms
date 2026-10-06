import { Discriminator } from "./discriminator";

enum CodecHiddenKind { Zero = 0, Last = 9 }
struct CodecHiddenChild { alive: boolean; kind: CodecHiddenKind; kinds: CodecHiddenKind[2]; }

export struct CodecHiddenAccount {
	first: uint8;
	children: CodecHiddenChild[2];
	last: boolean;
}

export function discriminator(this typeof CodecHiddenAccount): Discriminator {
	return { bytes: [11, 12, 13, 14, 15, 16, 17, 18] };
}

export function hiddenAccount(): CodecHiddenAccount {
	return {
		first: 7,
		children: [
			{ alive: false, kind: CodecHiddenKind.Last, kinds: [CodecHiddenKind.Zero, CodecHiddenKind.Last] },
			{ alive: true, kind: CodecHiddenKind.Zero, kinds: [CodecHiddenKind.Last, CodecHiddenKind.Zero] },
		],
		last: true,
	};
}

export function hiddenAccountValid(value: CodecHiddenAccount): boolean {
	return value.first == 7 && !value.children[0].alive && value.children[1].alive &&
		value.children[0].kind == CodecHiddenKind.Last && value.children[1].kind == CodecHiddenKind.Zero &&
		value.children[0].kinds[0] == CodecHiddenKind.Zero && value.children[0].kinds[1] == CodecHiddenKind.Last &&
		value.children[1].kinds[0] == CodecHiddenKind.Last && value.children[1].kinds[1] == CodecHiddenKind.Zero && value.last;
}
