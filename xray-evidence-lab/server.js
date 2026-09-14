const express = require('express');
const _ = require('lodash');
const axios = require('axios');
const minimist = require('minimist');
const jwt = require('jsonwebtoken');
const moment = require('moment');

const argv = minimist(process.argv.slice(2));
const port = argv.port || process.env.PORT || 3000;

const app = express();

app.get('/', (req, res) => {
  res.json({
    message: 'Hello World',
    startedAt: moment().toISOString(),
  });
});

app.get('/healthz', (req, res) => res.json({ status: 'ok' }));

// Exercises the dependency tree so the SCA scan and SBOM have something to chew on.
app.get('/info', (req, res) => {
  const token = jwt.sign({ svc: 'hello-express' }, 'lab-only-not-a-real-secret');
  res.json({
    deps: _.sortBy(Object.keys(require('./package.json').dependencies)),
    httpClient: axios.VERSION || 'axios',
    token: `${token.slice(0, 12)}...`,
  });
});

app.listen(port, () => {
  console.log('Hello World');
  console.log(`hello-express listening on port ${port}`);
});
