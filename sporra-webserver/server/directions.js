// One route, asked for by the edit panel and answered as a line of coordinates.
//
// The two hosts are fixed. The only thing a request can change is the two
// places, and those are checked before the URL is built, so this cannot be
// talked into fetching somewhere else. The browser never sees the upstream
// call: the User-Agent has to name this app, and a page full of visitors
// should not be a page full of clients on a demo server.

import {
  carRequestUrl,
  lineFromOsrm,
  lineFromTransitous,
  placeOk,
  placesApart,
  trainRequestUrl,
} from '../src/directions.js';

const MAX_BYTES = 2_000_000;
const CAR_TIMEOUT_MS = 15_000;
const TRAIN_TIMEOUT_MS = 25_000;

export class RouteError extends Error {
  /**
   * @param {'bad'|'none'|'failed'} code
   */
  constructor(code) {
    super(code);
    this.code = code;
  }
}

/**
 * @param {{mode:string, from:{lng:number, lat:number}, to:{lng:number, lat:number}, userAgent:string, referer?:string|null}} req
 * @returns {Promise<Array<[number, number]>>}
 */
export async function fetchDirections(req) {
  const mode = req.mode === 'train' ? 'train' : req.mode === 'car' ? 'car' : null;
  if (!mode || !placeOk(req.from) || !placeOk(req.to) || !placesApart(req.from, req.to)) {
    throw new RouteError('bad');
  }
  const url = mode === 'car' ? carRequestUrl(req.from, req.to) : trainRequestUrl(req.from, req.to);
  const timeout = mode === 'car' ? CAR_TIMEOUT_MS : TRAIN_TIMEOUT_MS;
  let res;
  try {
    res = await fetch(url, {
      headers: {
        Accept: 'application/json',
        'User-Agent': req.userAgent,
        ...(req.referer ? { Referer: req.referer } : {}),
      },
      redirect: 'error',
      signal: AbortSignal.timeout(timeout),
    });
  } catch (err) {
    console.warn(`directions ${mode} did not answer: ${err?.name || 'error'}`);
    throw new RouteError('failed');
  }
  if (!res.ok) {
    console.warn(`directions ${mode} answered ${res.status}`);
    res.body?.cancel?.();
    throw new RouteError(res.status === 400 ? 'none' : 'failed');
  }
  const buf = await res.arrayBuffer();
  if (buf.byteLength > MAX_BYTES) throw new RouteError('failed');
  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(buf));
  } catch {
    throw new RouteError('failed');
  }
  const line = mode === 'car' ? lineFromOsrm(body) : lineFromTransitous(body);
  if (!line) throw new RouteError('none');
  return line;
}
