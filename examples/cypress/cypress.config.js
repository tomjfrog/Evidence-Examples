const { defineConfig } = require("cypress");

module.exports = defineConfig({
  projectId: "cypress-example", // Replace with your actual project ID
  fixturesFolder: false,
  reporter: "mochawesome",
  reporterOptions: {
    "json": true,
    "html": false,
    "overwrite": false,
    reportDir: "reports",
    reportFilename: 'cypress-results.json',
  },
  e2e: {
    setupNodeEvents(on, config) {},
    baseUrl: "http://localhost:3000",
    specPattern: "cypress/e2e/*.cy.js"
  },
});
