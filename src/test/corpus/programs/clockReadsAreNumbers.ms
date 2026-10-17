// @stdout: date digits perf digits
// @skip-raiser: the Raiser std declares no Date
function digits(text: string): string {
	return text.length > 0 && !text.startsWith("<") ? "digits" : text;
}

const stamp = "neon-" + Date.now().toString();
console.log(`date ${digits(stamp.slice(5, stamp.length))} perf ${digits(performance.now().toString())}`);
