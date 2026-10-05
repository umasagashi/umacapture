// Worker entry point. The tables are generated at deploy time from the module set served to users
// (tool/cloudflare/build_share_tables.py) and are not tracked: they carry game text.

import tables from "./tables.generated.json";
import { createWorker } from "./worker.mjs";

export default createWorker(tables);
