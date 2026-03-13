## Dialog Progress ##

This script comes in handy to show a progress window when you have a lengthy download (ie. MS office, xcode, Adobe apps, etc).  You will need to create two policies to allow this dialog window to work

1.  Create a policy that will do the actual install of the application and make sure to assign it a trigger name:

![](./DialogProgress-event.png)

2.  Create another policy that runs the Dialog Progress indicator and when configuring this policy, you will tell it when policy trigger to run

![](./DialogProgress-Parameters.png)

3.  Customize the progress display window with a title & icon.
4.  In your Self service policy, call the policy that you created in Step #2

## Results ##

![](./DialogProgress.png)

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial
| 1.1 | Fixed window layout for Tahoe & SD v3.0
| 1.2 | Changed JAMF 'policy -trigger' to 'JAMF policy -event'
||       Fixed variable names in the defaults file section


