This file points out incompatible changes regarding updates to newer versions, and remedies.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung). Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*. The project itself is subject to the GNU Public License version 2.

## 2024-08-03: removed field cfupddb in dcapf, added the need for `show running-config` in IOS devices.
Practice has shown that the timestamp when the configuration was last updated - derived from the version system status - isn't very useful, and prone to fall prey to corner cases in the perl script. Thus, the `cfupddb` field has been replaced with `cfupdt` and `cfsavd` fields. Both are derived from actual configuration content. Follow the steps in the [AS/400-README](as400/README.md#Upgrading), section *Upgrading* regarding the need to upgrade physical files. In this case, *dcapf*.

Because `cfupdt` and `cfsavd` are derived from the running configuration, issuing `show running-config` must also be added as allowed command on all IOS devices:
```
privilege exec level 2 show running-config
```

**Note:** Cisco ASA doesn't provide a time stamp for its `running-config`.

I'm aware that this can be a lot of work. But with clever shell scripting, copy-paste of configuration snippets, and the use of ssh-keys for device authentication, even changing dozens of devices is done in mere minutes. Both timestamps are optional, and a device not allowing `show running-config` isn't treated as fatal. Just the timestamps won't be obtained. If you add the privilege, a future version will provide optical indication of devices which have a newer *running-config* vs. *startup-config*: Admin has forgotten to issue a `write mem` — a classic.

----

2024-08-03 poc@pocnet.net
