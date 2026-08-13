'use strict';

const http = require('http');
const port = Number(process.argv[2]);
const expectedToken = 'test-token';
const accounts = new Map(['mhw19001', 'mhw19002', 'other'].map((name, index) => [name, {
  dispatcher_account: name,
  dispatcher_name: `User ${index + 1}`,
  dispatcher_no: String(1000 + index),
  dispatcher_pwd: 'stored-cipher',
  guid: `guid-${index + 1}`,
  puc_id: '00001',
  org_identifier: index === 0 ? '00' : '',
  org_alias: index === 0 ? 'Dispatch' : '',
  org_identifier_list: index === 0 ? '00' : '',
  custom_org_identifier_list: index === 0 ? '00' : '',
  custom_org_id: index === 0 ? '00' : '',
  system_id_list: index === 0 ? '100;200' : '',
  dispatch_sap_list: index === 0 ? '{"sapList":[]}' : '',
  role: 'operations',
  role_guid: 'role-1',
  judge_sync_edit: 1,
  system_type: 0,
  imei_list: [],
  is_change_pwd: 0,
}]));
const writes = [];
let policyQueries = 0;

function send(response, value, headers = {}) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length, ...headers });
  response.end(body);
}

const server = http.createServer((request, response) => {
  const chunks = [];
  request.on('data', (chunk) => chunks.push(chunk));
  request.on('end', () => {
    if (request.url === '/health') return send(response, { ok: true }, { 'set-cookie': ['session=abc; Path=/'] });
    if (request.url === '/writes') return send(response, { writes, policyQueries });
    if (request.url !== '/confs') return send(response, { result: 404, msg: 'not found' });
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { return send(response, { result: 400, msg: 'bad json' }); }
    if (request.headers.token !== expectedToken) return send(response, { result: 51800032, msg: 'verify-token failed' });
    if (body.cmd_name === 'conf_query_dc_pwd_config_request') {
      policyQueries += 1;
      return send(response, { result: 0, msg: 'ok', dispatcher_password_config: { guid: 'DcPwdConfig@common', realm: 'puc.com', first_login_change_flag: 1 } });
    }
    if (body.cmd_name === 'role_request') return send(response, { result: 0, role_list: [{ guid: 'role-super', role_alias: 'superadministrator' }] });
    if (body.cmd_name === 'system_list_request') return send(response, { result: 0, system_list: [{ system_id: '100' }, { system_id: '200' }] });
    if (body.cmd_name === 'sap_list_request') return send(response, { result: 0, sap_base_list: [] });
    if (body.cmd_name === 'short_organization_list_request') return send(response, { result: 0, organization_info_list: [{ org_identifier: '00', org_alias: 'Dispatch', parent_org_identifier: '' }] });
    if (body.cmd_name === 'personnel_organization_list_req') return send(response, { result: 0, organization_info_list: [{ custom_org_id: '00', custom_org_alias: 'Dispatch', parent_custom_org_id: '' }] });
    if (body.cmd_name === 'account_list_request') {
      const query = String(body.querykey || '').toLowerCase();
      const list = [...accounts.values()].filter((item) => item.dispatcher_account.toLowerCase().includes(query));
      return send(response, { result: 0, account_list: list, page_count: 1 });
    }
    if (body.cmd_name === 'update_account') {
      writes.push({ account: body.dispatcher_account, password: body.dispatcher_pwd, isChangePassword: body.is_change_pwd, fields: Object.keys(body) });
      const current = accounts.get(body.dispatcher_account);
      if (current) accounts.set(body.dispatcher_account, { ...current, ...body });
      return send(response, { result: 0 });
    }
    if (body.cmd_name === 'add_account') {
      writes.push({ account: body.dispatcher_account, operation: 'add_account' });
      return send(response, { result: 0 });
    }
    return send(response, { result: 400, msg: 'unknown command' });
  });
});

server.listen(port, '127.0.0.1', () => process.stdout.write('READY\n'));
