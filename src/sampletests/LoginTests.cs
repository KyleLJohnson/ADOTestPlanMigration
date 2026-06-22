using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace SampleTests
{
    [TestClass]
    public class LoginTests
    {
        private string? _validUsername;
        private string? _validPassword;

        [TestInitialize]
        public void Setup()
        {
            // Simulated test data setup
            _validUsername = "testuser";
            _validPassword = "Password123!";
        }

        [TestMethod]
        public void VerifyLoginSuccess()
        {
            // Arrange
            var loginService = new FakeLoginService();

            // Act
            var result = loginService.Login(_validUsername, _validPassword);

            // Assert
            Assert.IsTrue(result, "Expected login to succeed with valid credentials.");
        }

        [TestMethod]
        public void VerifyLoginFailure_InvalidPassword()
        {
            // Arrange
            var loginService = new FakeLoginService();

            // Act
            var result = loginService.Login(_validUsername, "WrongPassword");

            // Assert
            Assert.IsFalse(result, "Expected login to fail with invalid password.");
        }

        [TestMethod]
        public void VerifyLoginFailure_InvalidUsername()
        {
            // Arrange
            var loginService = new FakeLoginService();

            // Act
            var result = loginService.Login("wronguser", _validPassword);

            // Assert
            Assert.IsFalse(result, "Expected login to fail with invalid username.");
        }
    }

    // ✅ Fake service to simulate authentication logic (for demo purposes)
    public class FakeLoginService
    {
        public bool Login(string username, string password)
        {
            return username == "testuser" && password == "Password123!";
        }
    }
}
