## Uptime

GUI Notification of a request for a user to restart if over X days have passed.  Both the days & timers can be adjust via script variables (or passed in from a JAMF script)

![](/UpTime/Uptime.png)

An example of the smartgroup that can be setup for systems with an uptime over 30 days

![](/UpTime/Uptime_SmartGroup.png)

and the Extended Attribute that creates the 'Uptime Status' field of each computer

```
#!/bin/sh

uptimeOutput=$(uptime)

#detect "day" by removal and then string comparison, awk gets number of days between "up " and  " day"

[[ "${uptimeOutput/day/}" != "${uptimeOutput}" ]] && uptimeDays=$(awk -F "up | day" '{print $2}' <<< "${uptimeOutput}")

echo "<result>${uptimeDays:-0}</result>"
```

##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_

