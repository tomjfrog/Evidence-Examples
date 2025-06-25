describe("Server Homepage - Title and Error Handling Tests", () => {
    it("should have the correct title", () => {
        cy.visit("http://localhost:3000/server.html");
        cy.title().should("include", "My Server Application");
    });

    it("should throw an error when a non-existent input is typed into", () => {
        cy.visit("http://localhost:3000/server.html");
        cy.get('body').then($body => {
            const elementExists = $body.find("#non-existent-input").length > 0;
            if (!elementExists) {
                throw new Error("The non-existent input does not exist in the DOM.");
            } else {
                cy.get("#non-existent-input").type("test");
            }
        });
    });
});
describe("Server Homepage - Main Content Display Tests", () => {

    it("should display the main heading", () => {
        cy.visit("http://localhost:3000/server.html");
        cy.get("h1").should("exist");
        cy.get("h1").should("have.text", "Welcome to My Server Application");
    });

    it("should display the test element with correct text", () => {
        cy.visit("http://localhost:3000/server.html");
        cy.get("#my-element").should("exist");
        cy.get("#my-element").should("have.text", "This is a server test element.");
    });

});