'use strict';

const http = require('node:http');
const https = require('node:https');
const path = require('node:path');

const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const SEARCH_URL = 'http://searxng.web-research.svc.cluster.local:8080/search';
const CRAWL_URL = 'http://crawl4ai.envoy-gateway-system.svc.cluster.local:8080/crawl';
const EXCLUDED_URL = 'http://crawl4ai.envoy-gateway-system.svc.cluster.local:8080/token';
const STATIC_URL = 'https://example.com/';
const STATIC_TEXT = 'Example Domain';
const JAVASCRIPT_URL = 'https://quotes.toscrape.com/js/';
const JAVASCRIPT_TEXT = 'The world as we have created it';
const LOOPBACK_URL = 'https://127.0.0.1/';

class ContractError extends Error {
  constructor(code, bytesRead = 0) {
    super(code);
    this.code = code;
    this.bytesRead = bytesRead;
  }
}

function jsonDocument(response, code) {
  const contentType = String(response.headers['content-type'] || '').toLowerCase();
  const contentEncoding = String(response.headers['content-encoding'] || 'identity').toLowerCase();
  if (!contentType.startsWith('application/json') ||
      (contentEncoding !== '' && contentEncoding !== 'identity')) {
    throw new ContractError(code);
  }
  try {
    return JSON.parse(response.body.toString('utf8'));
  } catch (_error) {
    throw new ContractError(code);
  }
}

function searchContract(response) {
  if (response.status !== 200) throw new ContractError('search-contract');
  const document = jsonDocument(response, 'search-contract');
  if (!Array.isArray(document.results) || document.results.length === 0) {
    throw new ContractError('search-contract');
  }
  let exampleMatch = false;
  for (const result of document.results) {
    if (!result || typeof result.url !== 'string') {
      throw new ContractError('search-contract');
    }
    let candidate;
    try {
      candidate = new URL(result.url);
    } catch (_error) {
      throw new ContractError('search-contract');
    }
    if (!['http:', 'https:'].includes(candidate.protocol)) {
      throw new ContractError('search-contract');
    }
    if (candidate.hostname === 'example.com' || candidate.hostname.endsWith('.example.com')) {
      exampleMatch = true;
    }
  }
  if (!exampleMatch) throw new ContractError('search-contract');
  return document.results.length;
}

function crawlContract(response, expectedUrl, expectedText) {
  if (response.status !== 200) throw new ContractError('crawl-contract');
  const document = jsonDocument(response, 'crawl-contract');
  const results = document.results;
  const result = Array.isArray(results) && results.length === 1 ? results[0] : null;
  if (document.success !== true || !result || result.success !== true ||
      result.status_code !== 200 || result.url !== expectedUrl ||
      result.redirected_url !== expectedUrl ||
      !result.markdown || typeof result.markdown.raw_markdown !== 'string' ||
      !result.markdown.raw_markdown.includes(expectedText)) {
    throw new ContractError('crawl-contract');
  }
  return 1;
}

function prohibitedContract(response) {
  if (response.status === 400) {
    const document = jsonDocument(response, 'prohibited-contract');
    if (document.detail === 'URL blocked (SSRF protection): URL blocked') return 1;
  }
  throw new ContractError('prohibited-contract');
}

function nativeBackpressureContract(response) {
  if (response.status === 429) {
    const document = jsonDocument(response, 'burst-contract');
    return document.error === 'Rate limit exceeded: 60 per 1 minute';
  }
  if (response.status === 503) {
    const document = jsonDocument(response, 'burst-contract');
    return document.detail === 'Server busy, retry later' &&
      String(response.headers['retry-after'] || '') === '5';
  }
  return false;
}

function classifyBurst(responses, expectedUrl, expectedText) {
  if (!Array.isArray(responses) || responses.length !== 4) {
    throw new ContractError('burst-contract');
  }
  let successful = 0;
  let busy = 0;
  for (const response of responses) {
    try {
      if (nativeBackpressureContract(response)) {
        busy += 1;
        continue;
      }
      crawlContract(response, expectedUrl, expectedText);
      successful += 1;
    } catch (_error) {
      throw new ContractError('burst-contract');
    }
  }
  return {successful, busy};
}

function boundedRequest(url, options = {}) {
  const timeoutMs = options.timeoutMs;
  const maxBytes = options.maxBytes;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 ||
      !Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    return Promise.reject(new ContractError('invalid-limit'));
  }
  const parsed = new URL(url);
  const transport = parsed.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    let settled = false;
    let bytesRead = 0;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      callback(value);
    };
    const request = transport.request(parsed, {
      method: options.method || 'GET',
      headers: {'accept-encoding': 'identity', ...(options.headers || {})},
      agent: false,
    });
    const deadline = setTimeout(() => {
      const error = new ContractError('deadline', bytesRead);
      request.destroy(error);
      finish(reject, error);
    }, timeoutMs);
    request.on('response', (response) => {
      const chunks = [];
      response.on('data', (chunk) => {
        const remaining = maxBytes + 1 - bytesRead;
        if (remaining > 0) {
          const bounded = chunk.subarray(0, remaining);
          chunks.push(bounded);
          bytesRead += bounded.length;
        }
        if (bytesRead > maxBytes) {
          const error = new ContractError('response-too-large', bytesRead);
          response.destroy(error);
          request.destroy(error);
          finish(reject, error);
        }
      });
      response.on('end', () => finish(resolve, {
        status: response.statusCode || 0,
        headers: response.headers,
        body: Buffer.concat(chunks),
      }));
      response.on('error', (error) => finish(reject, error));
    });
    request.on('error', (error) => finish(reject, error));
    if (options.body !== undefined) request.write(options.body);
    request.end();
  });
}

function crawlPayload(url) {
  return {
    urls: [url],
    browser_config: {
      type: 'BrowserConfig',
      params: {text_mode: true, verbose: false},
    },
    crawler_config: {
      type: 'CrawlerRunConfig',
      params: {
        cache_mode: {type: 'CacheMode', params: 'bypass'},
        page_timeout: 45000,
        verbose: false,
        screenshot: false,
        pdf: false,
        only_text: true,
        exclude_all_images: true,
      },
    },
  };
}

function oversizedPayload() {
  const base = `https://example.com/${'a'.repeat(40000)}/`;
  const links = Array.from(
    {length: 220},
    (_value, index) => `<a href="item-${index}">Fixture item ${index}</a>`,
  ).join('');
  const html = `<html><head><base href="${base}"></head>` +
    `<body><p>Bounded public fixture</p>${links}</body></html>`;
  return crawlPayload(`raw:${html}`);
}

function oversizedContract(response) {
  const expected = Buffer.from('{"error":"upstream response too large or encoded"}\n');
  const contentType = String(response.headers['content-type'] || '').toLowerCase();
  const encoding = String(response.headers['content-encoding'] || '').toLowerCase();
  const declaredLength = Number(response.headers['content-length']);
  if (response.status !== 502 || contentType !== 'application/json' || encoding ||
      declaredLength !== expected.length || !response.body.equals(expected)) {
    throw new ContractError('oversized-contract', response.body.length);
  }
  return 1;
}

function resultRecord(phase, passed, status, size, count, duration) {
  return {
    phase,
    result: passed ? 'pass' : 'fail',
    status: Number.isSafeInteger(status) && status >= 0 && status <= 599 ? status : 0,
    size: Number.isSafeInteger(size) && size >= 0 ? size : 0,
    count: Number.isSafeInteger(count) && count >= 0 ? count : 0,
    duration: Math.max(0, Math.round(duration)),
  };
}

function shouldRun(filename) {
  return path.basename(filename) === '[stdin]';
}

async function call(url, timeoutMs, body, extraHeaders = {}) {
  const encoded = body === undefined ? undefined : JSON.stringify(body);
  const headers = {
    accept: 'application/json',
    ...extraHeaders,
  };
  if (encoded !== undefined) {
    headers['content-type'] = 'application/json';
    headers['content-length'] = Buffer.byteLength(encoded);
  }
  return boundedRequest(url, {
    method: encoded === undefined ? 'GET' : 'POST',
    headers,
    body: encoded,
    timeoutMs,
    maxBytes: MAX_RESPONSE_BYTES,
  });
}

async function runPhase(phase, operation) {
  const started = Date.now();
  try {
    const value = await operation();
    return resultRecord(
      phase,
      true,
      value.status,
      value.size,
      value.count,
      Date.now() - started,
    );
  } catch (error) {
    return resultRecord(
      phase,
      false,
      error && Number.isSafeInteger(error.status) ? error.status : 0,
      error && Number.isSafeInteger(error.bytesRead) ? error.bytesRead : 0,
      0,
      Date.now() - started,
    );
  }
}

function contractFailure(code, response) {
  const error = new ContractError(code, response ? response.body.length : 0);
  error.status = response ? response.status : 0;
  return error;
}

async function crawl(url, expectedText, extraHeaders = {}) {
  const response = await call(CRAWL_URL, 85000, crawlPayload(url), extraHeaders);
  try {
    const count = crawlContract(response, url, expectedText);
    return {status: response.status, size: response.body.length, count};
  } catch (_error) {
    throw contractFailure('crawl-contract', response);
  }
}

async function main() {
  const watchdog = setTimeout(() => process.exit(124), 510000);
  const records = [];

  records.push(await runPhase('search', async () => {
    const url = new URL(SEARCH_URL);
    url.searchParams.set('q', 'site:example.com "Example Domain"');
    url.searchParams.set('format', 'json');
    const response = await call(url, 30000);
    try {
      const count = searchContract(response);
      return {status: response.status, size: response.body.length, count};
    } catch (_error) {
      throw contractFailure('search-contract', response);
    }
  }));

  records.push(await runPhase('static-crawl', () => crawl(STATIC_URL, STATIC_TEXT)));
  records.push(await runPhase('authorization-replacement', () => crawl(
    STATIC_URL,
    STATIC_TEXT,
    {authorization: 'Bearer synthetic-invalid-client-token'},
  )));

  records.push(await runPhase('route-exclusion', async () => {
    const response = await call(EXCLUDED_URL, 20000, {});
    if (response.status !== 404) throw contractFailure('route-exclusion', response);
    return {status: response.status, size: response.body.length, count: 1};
  }));

  records.push(await runPhase('javascript-crawl', () => crawl(
    JAVASCRIPT_URL,
    JAVASCRIPT_TEXT,
  )));

  records.push(await runPhase('oversized-response', async () => {
    const response = await call(CRAWL_URL, 85000, oversizedPayload());
    try {
      const count = oversizedContract(response);
      return {status: response.status, size: response.body.length, count};
    } catch (_error) {
      throw contractFailure('oversized-contract', response);
    }
  }));

  records.push(await runPhase('prohibited-loopback', async () => {
    const response = await call(CRAWL_URL, 30000, crawlPayload(LOOPBACK_URL));
    try {
      const count = prohibitedContract(response);
      return {status: response.status, size: response.body.length, count};
    } catch (_error) {
      throw contractFailure('prohibited-contract', response);
    }
  }));

  records.push(await runPhase('concurrency-burst', async () => {
    const responses = await Promise.all([
      call(CRAWL_URL, 90000, crawlPayload(STATIC_URL)),
      call(CRAWL_URL, 90000, crawlPayload(STATIC_URL)),
      call(CRAWL_URL, 90000, crawlPayload(STATIC_URL)),
      call(CRAWL_URL, 90000, crawlPayload(STATIC_URL)),
    ]);
    let classified;
    try {
      classified = classifyBurst(responses, STATIC_URL, STATIC_TEXT);
    } catch (_error) {
      const response = responses.find((item) => item.status !== 200);
      throw contractFailure('burst-contract', response || responses[0]);
    }
    return {
      status: Math.max(...responses.map((response) => response.status)),
      size: responses.reduce((total, response) => total + response.body.length, 0),
      count: classified.successful,
    };
  }));

  records.push(await runPhase('recovery', () => crawl(STATIC_URL, STATIC_TEXT)));

  clearTimeout(watchdog);
  for (const record of records) process.stdout.write(`${JSON.stringify(record)}\n`);
  process.exitCode = records.every((record) => record.result === 'pass') ? 0 : 1;
}

module.exports = {
  boundedRequest,
  classifyBurst,
  ContractError,
  crawlContract,
  crawlPayload,
  oversizedContract,
  oversizedPayload,
  prohibitedContract,
  resultRecord,
  searchContract,
  shouldRun,
};

if (shouldRun(module.filename)) {
  main().catch(() => {
    process.exitCode = 1;
  });
}
