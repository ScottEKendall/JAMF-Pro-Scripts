## Grant Secure Token

Secure Tokens on macOS are used to allow users to:

This script will determine the status of the user's SecureToken.  If there is a user on the system that can grant a secure token, then the logged in user will be able to use that information to assign themselves a secure token.

* Perform Software Updates
* Approve Kernel Extensions
* Approve System Extensions
* Enable FileVault

Welcome Screen (If user has a valid token already)

![](/GrantSecureToken/GrantSecureToken_NoIssues.png)

Process if the user needs a token and there is an account on the system that can grant a token

![](/GrantSecureToken/GrantSecureToken_Welcome.png)

![](/GrantSecureToken/GrantSecureToken_Passwords.png)

Message if token is successfully granted

![](/GrantSecureToken/GrantSecureToken_Success.png)

Problems updatng the token (with error message)

![](/GrantSecureToken/GrantSecureToken_Failure.png)

##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_
