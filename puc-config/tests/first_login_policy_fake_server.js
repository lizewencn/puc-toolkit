const http = require('http');
const port = Number(process.argv[2]);
let flag = 0;
let returnNullFlagOnce = false;
const configurationGuid = 'DynamicConfigGuid@common';
const requests = [];

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/requests') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ requests }));
  }
  if (req.method === 'GET' && req.url === '/null-flag-once') {
    returnNullFlagOnce = true;
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ok: true }));
  }
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const value = JSON.parse(body || '{}');
    requests.push(value);
    let response;
    if (value.cmd_name === 'conf_query_dc_pwd_config_request') {
      const returnedFlag = returnNullFlagOnce ? null : flag;
      returnNullFlagOnce = false;
      response = { result: 0, msg: 'ok', dispatcher_password_config: { guid: configurationGuid, realm: 'puc.com', first_login_change_flag: returnedFlag } };
    } else if (value.cmd_name === 'conf_edit_dc_pwd_config_req') {
      if (value.guid !== configurationGuid) response = { result: 91, msg: 'wrong guid' };
      else { flag = value.first_login_change_flag; response = { result: 0, msg: 'ok' }; }
    } else response = { result: 99, msg: 'unknown command' };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(response));
  });
});
server.listen(port, '127.0.0.1');
