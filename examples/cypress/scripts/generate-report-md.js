const fs = require('fs');
const path = require('path');
const inputPath = path.join(__dirname, '../reports/overall-report.json');
const outputPath = path.join(__dirname, '../reports/cypress-results.md');
const imageRef = process.env.IMAGE_REF;

function collectTests(suite, rows = [], parentFile = '') {
  if (suite.tests && suite.tests.length) {
    suite.tests.forEach(test => {
      rows.push({
        suiteTitle: suite.title || 'Root Suite',
        file: parentFile,
        title: test.title || '',
        fullTitle: test.fullTitle || '',
        state: test.state || '',
        duration: test.duration != null ? test.duration : '',
        error: test.err && test.err.message ? test.err.message.replace(/\n/g, ' ') : 'N/A',
        code: test.code ? `${test.code.replace(/\n/g, '\\n')}` : ''
      });
    });
  }
  if (suite.suites && suite.suites.length) {
    suite.suites.forEach(subsuite => collectTests(subsuite, rows, parentFile));
  }
  return rows;
}

function main() {
  if (!fs.existsSync(inputPath)) {
    console.error('Input file not found:', inputPath);
    process.exit(1);
  }
  const data = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  const stats = data.stats || {};
  const results = data.results || [];
  if (!results.length) {
    console.error('No test results found.');
    process.exit(1);
  }

  let md = `Cypress Test Report
---
### Overview of Test Results
| Suites | Tests | Passes | Failures | Pending | Skipped | Pass % |
| :----- | :---- | :----- | :------- | :------ | :------ | :----- |
| ${stats.suites} | ${stats.tests} | ${stats.passes} | ${stats.failures} | ${stats.pending} | ${stats.skipped} | ${stats.passPercent ? stats.passPercent.toFixed(2) : '0.00'} |
\n**Image Name:** \`${imageRef || 'N/A'}\`\n
**Run Start:** \`${stats.start || 'N/A'}\`\n
**Run End:** \`${stats.end || 'N/A'}\`\n
**Duration:** \`${stats.duration || 'N/A'} ms\`\n
---
### Test Details by Suite
`;

  let allRows = [];
  results.forEach(result => {
    const parentFile = result.file || result.fullFile || '';
    if (result.suites && result.suites.length) {
      result.suites.forEach(suite => {
        allRows = allRows.concat(collectTests(suite, [], parentFile));
      });
    }
  });

  const suites = {};
  allRows.forEach(row => {
    const key = row.file ? `${row.suiteTitle} (${row.file})` : row.suiteTitle;
    if (!suites[key]) suites[key] = [];
    suites[key].push(row);
  });

  Object.keys(suites).forEach(suiteTitle => {
    md += `\n#### Suite: \`${suiteTitle}\`\n`;
    md += `| Title | State | Duration (ms) | Error Message | Code |\n`;
    md += `| :------------------- | :---- | :------------ | :------------ | :---- |\n`;
    suites[suiteTitle].forEach(row => {
      md += `| ${row.title} | ${row.state} | ${row.duration} | ${row.error} | ${row.code} |\n`;
    });
    md += '\n';
  });

  md += '\n---';
  fs.writeFileSync(outputPath, md, 'utf8');
  console.log('Markdown report generated at:', outputPath);
}

main();