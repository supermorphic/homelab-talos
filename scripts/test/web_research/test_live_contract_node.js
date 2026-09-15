'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const test = require('node:test');
const {
  boundedRequest,
  classifyBurst,
  crawlContract,
  crawlPayload,
  oversizedContract,
  oversizedPayload,
  prohibitedContract,
  resultRecord,
  searchContract,
  shouldRun,
} = require('./live_contract_node.js');

async function listen(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return server;
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
    server.closeAllConnections();
  });
}

test('active response still ends at the hard request deadline', async () => {
  const server = await listen((_request, response) => {
    response.writeHead(200, {'content-type': 'text/plain'});
    const timer = setInterval(() => response.write('x'), 5);
    response.on('close', () => clearInterval(timer));
  });
  const { port } = server.address();
  const started = Date.now();
  await assert.rejects(
    boundedRequest(`http://127.0.0.1:${port}/active`, { timeoutMs: 80, maxBytes: 1024 }),
    (error) => error.code === 'deadline',
  );
  assert.ok(Date.now() - started < 1000);
  await close(server);
});

test('response reader stops at one byte beyond its declared cap', async () => {
  const server = await listen((_request, response) => {
    response.writeHead(200, {'content-type': 'application/octet-stream'});
    response.end(Buffer.alloc(33, 120));
  });
  const { port } = server.address();
  await assert.rejects(
    boundedRequest(`http://127.0.0.1:${port}/large`, { timeoutMs: 1000, maxBytes: 32 }),
    (error) => error.code === 'response-too-large' && error.bytesRead === 33,
  );
  await close(server);
});

function jsonResponse(status, document) {
  return {
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
    body: Buffer.from(JSON.stringify(document)),
  };
}

function crawlResponse(url = 'https://example.com/', text = 'Example Domain') {
  return jsonResponse(200, {
    success: true,
    results: [{
      success: true,
      status_code: 200,
      url,
      redirected_url: url,
      markdown: {raw_markdown: text},
    }],
  });
}

test('search requires structured HTTP URLs and an example.com result', () => {
  const response = jsonResponse(200, {
    results: [
      {url: 'https://example.com/'},
      {url: 'https://www.example.com/reference'},
    ],
  });
  assert.equal(searchContract(response), 2);
  assert.throws(
    () => searchContract(jsonResponse(200, {results: [{url: 'javascript:alert(1)'}]})),
    (error) => error.code === 'search-contract',
  );
});

test('crawl success checks inner result and exact final URL', () => {
  assert.equal(crawlContract(crawlResponse(), 'https://example.com/', 'Example Domain'), 1);
  const falseSuccess = jsonResponse(200, {
    success: true,
    results: [{
      success: false,
      status_code: 200,
      url: 'https://example.com/',
      redirected_url: 'https://example.com/',
      markdown: {raw_markdown: 'Example Domain'},
    }],
  });
  assert.throws(
    () => crawlContract(falseSuccess, 'https://example.com/', 'Example Domain'),
    (error) => error.code === 'crawl-contract',
  );
});

test('prohibited seed requires an explicit failed native result', () => {
  const rejected = jsonResponse(400, {
    detail: 'URL blocked (SSRF protection): URL blocked',
  });
  assert.equal(prohibitedContract(rejected), 1);
  for (const distractor of [
    jsonResponse(400, {detail: 'Connection refused'}),
    jsonResponse(422, {detail: 'Unrelated validation error'}),
    jsonResponse(200, {success: true, results: [{success: false, status_code: 0}]}),
    crawlResponse(),
  ]) {
    assert.throws(
      () => prohibitedContract(distractor),
      (error) => error.code === 'prohibited-contract',
    );
  }
});

test('burst accepts only proved crawls or explicit busy and rate statuses', () => {
  const classified = classifyBurst([
    crawlResponse(),
    jsonResponse(429, {error: 'Rate limit exceeded: 60 per 1 minute'}),
    {
      ...jsonResponse(503, {detail: 'Server busy, retry later'}),
      headers: {'content-type': 'application/json', 'retry-after': '5'},
    },
    crawlResponse(),
  ], 'https://example.com/', 'Example Domain');
  assert.deepEqual(classified, {successful: 2, busy: 2});

  const falseSuccess = jsonResponse(200, {
    success: true,
    results: [{success: false, status_code: 200}],
  });
  assert.throws(
    () => classifyBurst([crawlResponse(), falseSuccess], 'https://example.com/', 'Example Domain'),
    (error) => error.code === 'burst-contract',
  );

  for (const unrelatedFailure of [
    jsonResponse(429, {detail: 'Unrelated throttling response'}),
    jsonResponse(503, {error: 'platform_auth_unavailable'}),
    jsonResponse(503, {detail: 'Server busy, retry later'}),
    {status: 503, headers: {}, body: Buffer.alloc(0)},
  ]) {
    assert.throws(
      () => classifyBurst([
        crawlResponse(),
        crawlResponse(),
        crawlResponse(),
        unrelatedFailure,
      ], 'https://example.com/', 'Example Domain'),
      (error) => error.code === 'burst-contract',
    );
  }
});

test('crawl fixture contains only bounded native browser options', () => {
  const payload = crawlPayload('https://example.com/');
  assert.deepEqual(payload, {
    urls: ['https://example.com/'],
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
  });
});

test('result record exposes only sanitized fixed fields', () => {
  assert.deepEqual(
    resultRecord('search', true, 200, 42, 3, 12.8),
    {phase: 'search', result: 'pass', status: 200, size: 42, count: 3, duration: 13},
  );
});

test('main runs only for a Node stdin module', () => {
  assert.equal(shouldRun('/workspace/[stdin]'), true);
  assert.equal(shouldRun('/workspace/live_contract_node.js'), false);
});

test('oversized fixture is fixed, network-free, and below the input cap', () => {
  const payload = oversizedPayload();
  const encoded = Buffer.from(JSON.stringify(payload));
  assert.ok(encoded.length < 50 * 1024);
  assert.equal(payload.urls.length, 1);
  assert.ok(payload.urls[0].startsWith('raw:<html>'));
  assert.equal((payload.urls[0].match(/<a href=/g) || []).length, 220);
  assert.equal(payload.urls[0].includes('<script'), false);
  assert.equal(payload.urls[0].includes('<img'), false);
});

test('oversized response requires the proxy exact replacement response', () => {
  const replacement = {
    status: 502,
    headers: {'content-type': 'application/json', 'content-length': '51'},
    body: Buffer.from('{"error":"upstream response too large or encoded"}\n'),
  };
  assert.equal(oversizedContract(replacement), 1);
  for (const distractor of [
    {...replacement, status: 500},
    {...replacement, body: Buffer.from('{"error":"upstream unavailable"}\n')},
    jsonResponse(502, {error: 'upstream response too large or encoded'}),
  ]) {
    assert.throws(
      () => oversizedContract(distractor),
      (error) => error.code === 'oversized-contract',
    );
  }
});

test('oversized response accepts the independently reproduced Envoy buffer rejection', () => {
  const rejection = {
    status: 500,
    headers: {'content-type': 'text/plain', 'content-length': '21'},
    body: Buffer.from('Internal Server Error'),
  };
  assert.equal(oversizedContract(rejection), 1);
  for (const distractor of [
    {...rejection, status: 503},
    {...rejection, headers: {...rejection.headers, 'content-encoding': 'gzip'}},
    {...rejection, headers: {...rejection.headers, 'content-length': '22'}},
    {...rejection, body: Buffer.from('upstream unavailable')},
    jsonResponse(500, {error: 'Internal server error', correlation_id: 'synthetic'}),
  ]) {
    assert.throws(() => oversizedContract(distractor),
      (error) => error.code === 'oversized-contract');
  }
});
