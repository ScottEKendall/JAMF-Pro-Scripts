## Low Disk Space

Nice GUI alerting the user that their available disk space is below a certain threshold

![](/LowDiskSpace/LowDiskSpace.png)

An example of the smartgroup that can be setup for available disk space over 80%

![](/LowDiskSpace/SmartGroup.png)

and the Extended Attribute that creates the 'Disk Space Used %' field of each computer

```
#!/bin/sh
#https://www.jamf.com/jamf-nation/discussions/12546/boot-volume-free-space-ea

DU=$(df -h /Users | awk 'END{ print $(NF-4) }' | tr -d '%' )

# print the reuslts padding with leading 0

echo "<result>$(printf "%02d\n" $DU)</result>" ```




##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_

