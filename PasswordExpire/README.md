## Password Expiration Notice

I was wanting to find a way to notify the users if their network password is about to expire.  I key off a configuration.plist file that has the key 'PasswordLastChanged' and determine how many days are left until their password expires.  

The variable PASSWORD_EXPIRE_IN_DAYS can be used to set your expiration length (in days).  The script will show a notification center dialog if you the user is within 7 days of expiration.

**Initial Prompt**

![First Dialog prompt](/PasswordExpire/PasswordExpire.png)
Notification Center prompt

![Notification Center](/PasswordExpire/PasswordExpireNotification.png)

##### _v1.0 - Initial Commit_
