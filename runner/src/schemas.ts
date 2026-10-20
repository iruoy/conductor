// Compose application schemas through this module so accidental mutations fail during development and tests.
// Pi keeps its own pinned TypeBox instance; these settings deliberately apply only to Conductor's schemas.
import System from "typebox/system";

System.Settings.Set({ immutableTypes: process.env.NODE_ENV !== "production" });

export { Type } from "typebox";
