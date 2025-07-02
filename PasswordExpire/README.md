## Password Expiration Notice

I was wanting to find a way to notify the users if their network password is about to expire.  I key off a configuration.plist file that has the key 'PasswordLastChanged' and determine how many days are left until their password expires.  

The variable PASSWORD_EXPIRE_IN_DAYS can be used to set your expiration length (in days).  The script will show a notification center dialog if you the user is within 7 days of expiration.

v1.2 adds the option to view your password days until expiration "on demand" so you can view it directly from Self service.


**Initial Prompt**

![First Dialog prompt](/PasswordExpire/PasswordExpire.png)

**Notification Center prompt**

![Notification Center](/PasswordExpire/PasswordExpireNotification.png)

**Script Parameters**

![](/PasswordExpire/PasswordExpire-Parameters.png)

##### _v1.0 - Initial Commit_
##### _v1.2 - Add option for "on demand" viewing of password_
