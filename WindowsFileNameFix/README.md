## Windows FileName Fix

When storing files in OneDrive on a Mac, you must adhere to naming rules primarily designed for Windows compatibility. If you ignore these, OneDrive will likely trigger a sync error (indicated by a red "X") or automatically rename the file. 

This script will go thru the directory (and sub folders) of you choice and scan for "illegal" filenames and convert them to a "safe" name.  You have the option of exporting the changes files into a CSV so you can see what was converted.

![](./WindowsFileNameFix.png)

## Prohibited Characters

The following characters are strictly forbidden in file and folder names: 

* Asterisk ( * )
* Colon ( : )
* Double quote ( " )
* Less than ( < ) and Greater than ( > )
* Question mark ( ? )
* Slash ( / ) and Backslash ( \ )
* Pipe ( | )

## Restricted Character Placement

Leading/Trailing Spaces: 

You cannot start or end a file or folder name with a space.

Trailing Periods: File or folder names cannot end with a period (.).

Consecutive Periods: Avoid using two or more periods in a row in the middle of a name.

Hidden Files: Starting a name with a period will hide the file on macOS and may cause sync issues. 

## Name and Path Length Limits

Individual Name Limit: A single file or folder name cannot exceed 255 characters.

Total Path Limit: The entire path (including all folders and the file name) must be fewer than 400 characters.

URL Encoding: OneDrive converts spaces to %20 in web links. This turns one character into three, which can push a long path over the 400-character limit unexpectedly. 

## Invalid Names (Windows Legacy)

The following names are reserved by Windows and cannot be used for any file or folder: 
.lock, CON, PRN, AUX, NUL

COM0 through COM9

LPT0 through LPT9

Any file starting with ~$ (temporary Office files). 

Tip: To fix existing issues, you can use the OneDrive Sync Problems Viewer on your Mac by clicking the OneDrive icon in the menu bar and selecting "View sync problems".


| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial