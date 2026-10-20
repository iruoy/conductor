import { describe, expect, it } from "vitest";
import { Type } from "../src/schemas.ts";

describe("application schemas", () => {
	it("rejects mutations of shared subschemas without changing either composed schema", () => {
		const source = Type.Object({ name: Type.String() });
		const optional = Type.Optional(source);
		expect(() => Object.assign(source.properties.name, { type: "number" })).toThrow(TypeError);
		expect(source.properties.name.type).toBe("string");
		expect(optional.properties.name.type).toBe("string");
	});
});
