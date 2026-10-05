// Vercel Function entry (Node.js runtime). vercel.json rewrites /r/* here; the handler reads the
// path from the request URL and refuses everything that is not /r/<id>.png.
//
// PUBLIC_ORIGIN is where the public JSON and the fonts come from: https://umacapture.com in
// production, the staging workers.dev origin on a preview deployment.

import { createHandler } from "../src/handler.mjs";

const origin = process.env.PUBLIC_ORIGIN;
if (!origin) throw new Error("PUBLIC_ORIGIN is not set");

const handle = createHandler({ origin });

// Every method is routed to the handler so that it, not the platform, answers 405.
export const GET = handle;
export const HEAD = handle;
export const POST = handle;
export const PUT = handle;
export const PATCH = handle;
export const DELETE = handle;
export const OPTIONS = handle;
