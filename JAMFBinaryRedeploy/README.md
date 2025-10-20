## JAMF Binary Self Heal   

As of JAMF 10.36, we have the ability to send out a command for the JAMF binary to "self heal" itself.  Useful for when you get the dreaded "Device Signature failure".  I have found in my testing, that once this command is sent to the device, it will also trigger the enrollment process as well.

**New in v1.5** I having included instructions on how to manually deploy the JAMF binary from a macOS workstaion


Initial Dialog asking for info

![](./JAMBinaryRedeploy%20-%20Info.png)

Confirmation window

![](./JAMBinaryRedeploy%20-%20Confirm.png)

Results screen

![](./JAMBinaryRedeploy%20-%20Done.png)

Manual Step method

![](./JAMBinaryRedeploy%20-%20Manual.png)

## JAMF API Information ##

If you are using the Modern JAMF API credentials, you need to set:

```Send Computer Remote Command to Install Package```

```Read Computer Check-In```

## History ##

- 1.0 - Initial
- 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
- 1.2 - Now works with JAMF Client/Secret or Username/password authentication
    - Change variable declare section around for better readability
- 1.3 - Made API changes for JAMF Pro 11.20 and higher
- 1.4 - Added function to check JAMF credentials are passed
    - Fixed function to determine which SS/SS+ is being used
- 1.5 - Added option for manual deploy of the binary with instructions on how to perform
    - Moved more items into functions from the main script to clean up things
    - Moved all "exit" commands into the clean_and_exit funtion to make sure temp files are erased