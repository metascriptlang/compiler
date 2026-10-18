import { Tag, mkTag, mkInt, mkBig } from "./tag";

export async function gather(): Promise<string> {
	const tags = await Promise.all([mkTag("c", 3), mkTag("d", 4)]);
	const ints = await Promise.all([mkInt(5), mkInt(6)]);
	const bigs = await Promise.all([mkBig(7), mkBig(8)]);
	return tags[0].label + tags[1].label + (tags[0].n + tags[1].n).toString() + "/" + (ints[0] + ints[1]).toString() + "/" + (bigs[0] + bigs[1]).toString();
}
