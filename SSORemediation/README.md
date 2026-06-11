## SSO Remediation

This script is designed to Detemrine the results of Apple SSO and Jamf Conditional Access checks for Microsoft Entra ID device registration and compliance status, 
and provide detailed analysis and remediation steps based on the combined results.

## Help Wanted ##

![](https://www.mortylefkoe.com/wp-content/uploads/2014/11/bigstock-help-please-helping-hand-111914-e1416352858954.jpg)

What I am wanting to do is to offer a Swift Dialog message or script to run under certain condtions:

Apple's SSO command can return the following results:

```
POUserStateNeedsRegistration (2)
POUserStateNeedsNewKeys (1)
POUserStateNormal (0)
```

and the JAMF condition access policy can return these results:

```
0 = MSALPlatformSSONotEnabled
1 = MSALPlatformSSOEnabledNotRegistered
2 = MSALPlatformSSOEnabledAndRegistered
```

Detemrining the results of these outputs can provide remediation on what to do:

> GOAL: the Apple SSO command should be 0
> and the JAMF CA command should be 2.

What I am needing your help with is what should be done under non-ideal circumstances.  Once we determine what do to do for what issue, then I can construct a SD display or script steps to get the user back into ideal conditions

>DISCLAIMER: This script is in no way complete, and should not be used as-is for remediation >purposes!  Please provide PRs or reach out to me on Slack via #Macadmins channel so we can >work together and making a good robust script

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 Alpha | JAMF Admins / Developer help needed


