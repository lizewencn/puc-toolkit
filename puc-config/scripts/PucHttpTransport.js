'use strict';

const http = require('http');
const https = require('https');

function fail(message, code = 1) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  let descriptor;
  try {
    descriptor = JSON.parse(input);
  } catch {
    fail('Transport input is not valid JSON.', 2);
  }

  let target;
  try {
    target = new URL(descriptor.uri);
  } catch {
    fail('Transport URI is invalid.', 2);
  }
  if (!['http:', 'https:'].includes(target.protocol)) {
    fail('Transport URI must use HTTP or HTTPS.', 2);
  }

  let body;
  try {
    body = Buffer.from(descriptor.bodyBase64 || '', 'base64');
  } catch {
    fail('Transport body is not valid base64.', 2);
  }

  const client = target.protocol === 'https:' ? https : http;
  const options = {
    protocol: target.protocol,
    hostname: target.hostname,
    port: target.port || undefined,
    path: `${target.pathname}${target.search}`,
    method: descriptor.method || 'POST',
    headers: descriptor.headers || {},
    timeout: Number(descriptor.timeoutMs) || 60000,
  };
  if (target.protocol === 'https:') {
    options.rejectUnauthorized = descriptor.allowInsecureTls !== true;
    options.minVersion = 'TLSv1.2';
  }

  const request = client.request(options, (response) => {
    const chunks = [];
    response.on('data', (chunk) => chunks.push(chunk));
    response.on('end', () => {
      const rawHeaders = {};
      for (let index = 0; index < response.rawHeaders.length; index += 2) {
        const name = response.rawHeaders[index].toLowerCase();
        const value = response.rawHeaders[index + 1];
        if (!rawHeaders[name]) rawHeaders[name] = [];
        rawHeaders[name].push(value);
      }
      process.stdout.write(JSON.stringify({
        statusCode: response.statusCode,
        statusMessage: response.statusMessage || '',
        headers: rawHeaders,
        bodyBase64: Buffer.concat(chunks).toString('base64'),
        tlsProtocol: response.socket && response.socket.encrypted
          ? response.socket.getProtocol()
          : null,
      }), () => process.exit(0));
    });
  });

  request.on('timeout', () => request.destroy(new Error('Request timed out.')));
  request.on('error', (error) => fail(`Transport request failed: ${error.code || error.name}: ${error.message}`));
  request.end(body);
});
