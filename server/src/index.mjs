// Worker entry point. The name tables are read from D1 (tables.mjs), not built into the script.

import { createWorker } from "./worker.mjs";

export default createWorker();
