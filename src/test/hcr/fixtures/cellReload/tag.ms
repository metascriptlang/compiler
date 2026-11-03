export struct Tag { text: string; }

export function onDestroy(this t: Tag): void {
	console.log(`HCR-CELL drop ${t.text}`);
}
