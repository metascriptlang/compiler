export function Counter(): string {
	static const t = noteTemplate("tpl-g2");
	return t + "!";
}
