## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung) - see there for further details. Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*.

## Introduction.

The script and example configuration file are meant for automatic inventorization of Cisco devices according to a master database table on an AS/400 (IBM i) system containing login details.

In addition, the retrieved configurations will be maintained in either *CVS* or *git* change tracking systems. Setup and usage of change tracking systems is beyond the scope of this document.

**Note:** Git support **requires** ssh session multiplexing to be disabled for the git repository host for pull/push. This can be achieved by adding the following stanza to your *~/.ssh/config*:
```
host scmhost
  ControlMaster no
  ControlPersist no
```

This Perl script has been tested under Linux only, because it has quite some module dependencies, and my machine is too old and slow to make serious use of PASE. In theory, it should be possible to install perl along with the necessary modules and run the script in PASE on IBM i.

**Note:** The script assumes a configured and functioning ODBC connection to the AS/400 machine. Setup of this is beyond the scope of this document.

## Preparation.
- `cp cisco-config-backuprc /etc`,
- Edit */etc/cisco-config-backuprc* to reflect your environment.

Next, you should install the required perl modules. For Debian systems, this is:
```
apt-get install libdbi-perl libdbd-odbc-perl libexpect-perl libtimedate-perl
```

The script spawns external programs through *Expect* to connect and fake-interactively steer devices. Currently *ssh* and *telnet* are supported connection options. You need a command line ssh and telnet client installed, respectively.

## Running.
Before running this script, you need to prepare the AS/400 environment. Refer to [the documentation](../as400/README.md) to finish preparation.

Available command line options, mostly for debugging purposes:
```
cisco-erfassung(.pl) [options] device1 [device2 ...]

-c: Suppress CVS/git functions
-d: Enable debug mode
-h: Show this help and exit
-n: Suppress setting empty database fields to NULL
-o: Suppress cleanup of orphaned database entries, and orphaned CVS/git files
-t: Test database connection and exit
-v: Show version and exit
```

If no devices (hostnames) are given, all hosts found in the database are handled.

**Note:** Logging is done almost entirely via syslog, facility *user*, unless you're using debug-mode.

If the script runs without issues, I recommend to run it at least daily from *cron*, etc.

----
2024-03-12 poc@pocnet.net
