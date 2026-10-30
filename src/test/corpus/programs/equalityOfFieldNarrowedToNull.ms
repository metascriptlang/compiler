// @stdout: eq=true ne=false
// @stdout: str=true strNe=false
// @stdout: plain=true plainNe=false
interface Model {
	timer: number | null;
	label: string | null;
}

function arm(m: Model): void {
	m.timer = 5;
	m.label = "x";
}

function main(): void {
	const m: Model = { timer: null, label: null };
	if (m.timer !== null) return;
	if (m.label !== null) return;
	arm(m);
	const timer = m.timer;
	if (timer === null) return;
	const label = m.label;
	if (label === null) return;
	const five: number = 5;
	console.log(`eq=${m.timer == timer} ne=${m.timer != timer}`);
	console.log(`str=${m.label == label} strNe=${m.label != label}`);
	console.log(`plain=${m.timer == five} plainNe=${m.timer != five}`);
}

main();
