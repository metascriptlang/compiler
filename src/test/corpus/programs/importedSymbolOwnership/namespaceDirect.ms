import * as headers from "./library";
import { Headers } from "./library";

interface Response { headers: Headers; }
function setHeader(this response: Response, name: string, value: string): void {
	headers.setHeader(response.headers, name, value);
}
export function direct(): string {
	const response: Response = { headers: { names: [], values: [] } };
	response.setHeader("a", "b");
	return response.headers.names[0] + response.headers.values[0];
}
