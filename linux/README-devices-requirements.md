This file describes the data acquisition process and recommended changes on the devices in question to maximize security.

You can easily use the same administrative account you use to configure your devices for this software. But you should be aware that due to the nature of "manual" logins, cleartext passwords are required to be saved somewhere — in the database. Using separate read-only accounts for this software on your devices greatly reduces the risk for abuse, should those passwords ever leak into undesired hands.

**Note:** Telnet logins with the ancient password-only mechanism are not supported. Please use the recommended `aaa new-model`.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung). Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*. The project itself is subject to the GNU Public License version 2.

## What the script does.
- Read master data (hstpf) to get a list of eligible devices. Only if no hostnames are given on the command line.
- Log into a given host according to settings and credentials in master data,
  - optionally answer ssh prompts about missing host keys,
  - optionally send enable command and password if configured in master data,
- set terminal length to 0 to suppress paging,
- issue `show version` and parse output,
  - optionally issue `show flash`, `show flash:`, `show bootflash:`, `dir flash:` until no error. This is done only when `show version` did not provide information about flash storage size.
- Issue `show inventory` and parse output,
- issue `show vtp status` and parse output,
  - issue `show vlan` and `show vlan-switch` until no error. Parse output.
- Obtain configuration from device, and store into database and version control system:
  - issue `more system:running-config` for ASAs, so output includes clear text PSKs and password hashes for successful configuration restores,
  - issue `show startup-config` for everything else.
- issue `show failover` on ASAs,
- issue `show running-config` on IOS to obtain current timestamps,
- issue `exit` to disconnect from the device.

Depending on the importance of the desired data in question, failure to run certain commands results in an error condition for the host being handled. It will be skipped entirely.

## Device configuration peculiarities.
Acquired data includes the current configuration, which is the NVRAM stored configuration on IOS based devices, and the currently active (running) configuration on ASAs.

This difference is due to a security enhancement: the ASA per default replaces any password or PSK string with asterisks in the *running-* and *startup-config*. A special command `more system:running-config` is needed to include the unobstructed strings, and in turn have a complete copy.

On IOS devices, the textual *running-config* is assembled from a binary representation in RAM. IOS per default excludes any configuration statements for which the current user has no authority. To keep the necessary changes on the device as little as possible, it only tries to access the *startup-config* which is a true text file in NVRAM, representing the complete configuration.

## Recommended configuration.
### ASA.
Currently, there is no established minimal configuration for restricted accounts on ASAs.

### IOS.
With the default configuration, telnet connections ask simply for a password. This is long deprecated and you should use `aaa new-model` commands instead. Subsequently remove any `password` directives in the `line` stanzas of the configuration.

In any case, you should keep an administrative backup session open, and test with a second session that your changed configuration still allows you to gain configuration privileges.

For IOS devices, `show`-commands have are allowed implicitly with privilege level 2. But this level does not allow to enter configuration mode, even when the command line is elevated ("enabled"). This is an acceptable middle ground between security and excessive configuration statements being necessary to allow individual commands.

The following snippet is sufficient for releases 15.2(2)T and onward:
```
aaa new-model
aaa authentication login default local
aaa authorization exec default local
aaa authorization console
!
username backup privilege 2 secret 0 secretsecret
!
privilege exec level 2 dir
file privilege 2
```

Releases between 12.1 and 15.2(2)T do not support `file privilege`. Ignore this parameter for those. Later releases use this parameter to allow access to files, such as *startup-config*.

IOS 12.0 does not support `secret` for usernames. Use `password` instead:
```
username backup privilege 2 password 0 secretsecret
```

IOS 11.2 doesn't know about
- `aaa authorization console`,
- `dir`
- `privilege level`.

Thus you must provide an enable password in the master data to reach enable mode, and use the implicitly allowed `show` commands.

----

2024-08-04 poc@pocnet.net
