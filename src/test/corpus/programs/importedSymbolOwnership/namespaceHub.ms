import * as headers from "./hub";
import { Headers } from "./hub";

interface Response { headers: Headers; }
function setHeader(this response: Response, name: string, value: string): void {
	headers.setHeader(response.headers, name, value);
}
export function throughHub(): string {
	const response: Response = { headers: { names: [], values: [] } };
	response.setHeader("c", "d");
	return response.headers.names[0] + response.headers.values[0];
}
