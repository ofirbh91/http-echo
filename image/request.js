// Preserve the assignment's request structure without echoing credentials.
const config = require('../nconf');
const allowedHeaders = new Set([
  'host', 'accept', 'content-type', 'content-length', 'user-agent',
  'x-request-id', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto'
]);
module.exports = (req) => {
  if (!config.get('enable:request')) return undefined;
  return {
    params: req.params,
    query: req.query,
    cookies: {},
    body: req.body,
    headers: Object.fromEntries(Object.entries(req.headers).filter(([name]) => allowedHeaders.has(name)))
  };
};
