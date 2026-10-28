// @stdout: xxx
function go(): void {
	let text: string | null = "x".repeat(3);
	const saved = text;
	console.log(saved);
}
go();
