import { midValue, midWord, word } from "./top";

@exportName("hcrIfaceValue")
export function hcrIfaceValue(): int32 {
	return midValue();
}

@exportName("hcrIfaceWord")
export function hcrIfaceWord(): string {
	return midWord() + word();
}
