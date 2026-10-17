console.log("nested body");
export async function describe(): Promise<string> {
	const s = await import("./sizes");
	return `${s.toneName(s.Tone.Light)} ${s.toneName(s.Tone.Dark)}`;
}
