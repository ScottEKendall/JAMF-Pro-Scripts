## Get JAMF DDM Info ##

Apple has declared DDM as "The Future" of software delivery and thankfully JAMF does have their new Blueprints functionality for us to use, but JAMFs reporting of Blueprint information is lacking on detailed information about deployments & failures.  This script is designed to extract all DDM information from any given machine and display active & failed blueprints as well as pending software update information.

![](JAMFGetDDMInfo-Welcome.png)

If there are any blueprint failures the blueprint ID will be listed and the potential cause as to why it failed. 

![](JAMFGetDDMInfo-Blueprint_Failures.png)

If there are any potential software update failures, they will be listed in here as well as the reason

![](JAMFGetDDMInfo-Software_Failures.png)

As is, the script (in its early Alpha stage) will function on a single system, but I have much more planned for it, such as:

* Select any static/smart group and it will process the DDM reports for all machines in the groups
* Export results via CSV / Email
* Report on failed blueprints from selected systems that you choose
* More DDM Details extracted & reported on
  
If you have any ideas/suggestions on how to improve the DDM reporting ability, please drop me a line!

## History ##

##### _0.1 - Initial Commit (Alpha)_

