## Delete Expired Certificates

 it is generally recommended to remove expired certificates from your macOS keychain to prevent authentication errors, clear up clutter, and avoid security risks. While expired certificates are technically "safe" because they are no longer usable, leaving them could cause various system issues.

>**Why You Should Remove Them**
>
>**Prevent Connection Failures:** Systems like Kerberos or Wi-Fi login services may mistakenly >try to use an expired certificate as an identity, leading to login failures.
>
>**Avoid Security Alarms:** Unnecessary expired certificates can trigger false security alarms >in management environments.
>
>**Reduce Clutter:** Periodic cleanup of "Keychain Access" ensures that reputable software >only attempts to authenticate using valid, current certificates.
>
>**Compliance & Trust:** In enterprise or developer settings, removing expired certificates is >a best practice to maintain security standards and avoid accidental deployment of invalid >credentials.

 This script can be run in either a Verbose mode (default) or Silent mode.  You can use the Silent mode in your MDM environment to remove a user's expired certificates during their MDM check-in period.

 You can also control which certificates types will be excluded from the removal process.  You can exclude:

 * Apple
 * Root CA
 * Self-Signed
 * Intermediate

 Verbose mode will present the user with the following screen...

![](./DeleteExpiredCerts-Welcome.png)


| **Version**|**Notes**|
|:--------:|-----|
| 0.1 | Initial Release |

