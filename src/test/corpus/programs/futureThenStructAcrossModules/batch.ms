export struct Batch { paths: string[]; label: string; count: int32; }
export struct Tag { label: string; }

export async function nextBatch(): Promise<Batch> {
	return { paths: ["a", "b"], label: "l", count: 2 };
}

export async function nextTag(): Promise<Tag> {
	return { label: "t" };
}
