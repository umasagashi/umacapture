// A minimal Chrome DevTools Protocol client over the browser-level WebSocket, with flattened sessions.
// Node's global WebSocket is enough; no npm dependency.

export class Cdp {
  #ws;
  #seq = 0;
  #pending = new Map();
  #listeners = new Set();

  static async connect(browserWsUrl) {
    const cdp = new Cdp();
    cdp.#ws = new WebSocket(browserWsUrl);
    await new Promise((resolve, reject) => {
      cdp.#ws.onopen = resolve;
      cdp.#ws.onerror = () => reject(new Error(`cannot open ${browserWsUrl}`));
    });
    cdp.#ws.onmessage = (m) => cdp.#dispatch(JSON.parse(m.data));
    cdp.#ws.onclose = () => {
      for (const p of cdp.#pending.values()) p.reject(new Error(`${p.method}: connection closed`));
      cdp.#pending.clear();
      for (const l of cdp.#listeners) l({ method: 'Cdp.closed', params: {} });
    };
    return cdp;
  }

  #dispatch(msg) {
    if (msg.id !== undefined && this.#pending.has(msg.id)) {
      const p = this.#pending.get(msg.id);
      this.#pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`${p.method}: ${JSON.stringify(msg.error)}`));
      else p.resolve(msg.result);
    } else if (msg.method) {
      for (const l of this.#listeners) l(msg);
    }
  }

  /** Sends [method] to the browser, or to the target attached as [sessionId]. */
  send(method, params = {}, sessionId = undefined) {
    const id = ++this.#seq;
    const body = { id, method, params };
    if (sessionId) body.sessionId = sessionId;
    this.#ws.send(JSON.stringify(body));
    return new Promise((resolve, reject) => this.#pending.set(id, { resolve, reject, method }));
  }

  /** Calls [listener] with every event ({method, params, sessionId}); returns the unsubscribe function. */
  on(listener) {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  close() {
    try { this.#ws.close(); } catch { /* already closed */ }
  }
}
