This file describes the necessary steps to successfully run the data acquisition script.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung). Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*. The project itself is subject to the GNU Public License version 2.

## Introduction.
The script and example configuration file are meant for automatic inventorization of Cisco devices according to a master database table on an AS/400 (IBM i) system containing login details.

In addition, the retrieved configurations will be maintained in either *CVS* or *git* change tracking systems. Setup and usage of change tracking systems is beyond the scope of this document.

**Note:** Git support **requires** ssh session multiplexing to be disabled for the git repository host for pull/push. This can be achieved by adding the following stanza to your *~/.ssh/config*:
```
host scmhost
  ControlMaster no
  ControlPersist no
```

The Perl script has been tested under Linux only, because it has some module dependencies, and my AS/400 is too old and slow to make serious use of PASE. In theory, it should be possible to install perl along with the necessary modules and run the script in PASE on IBM i.

**Note:** The script assumes a configured and functioning ODBC connection to the AS/400 machine. Setup of this is beyond the scope of this document.

## Preparation.
- `cp cisco-config-backuprc /etc`,
- Edit */etc/cisco-config-backuprc* to reflect your environment,
- Use `chown`/`chmod` commands to make the file readable only by the user intended to run the data acquisition script.

I recommend using a separate user account to run the script for security reasons.

Next, you should install the required perl modules. For Debian systems, this is:
```
apt-get install libdbi-perl libdbd-odbc-perl libexpect-perl libtimedate-perl
```

The script reads the master data table, spawns external programs through *Expect* to connect and fake-interactively steer devices. Currently *ssh* and *telnet* are supported connection options. You need a command line ssh and telnet client installed, respectively.

Consult [README-devices-requirements](README-devices-requirements.md) to learn about the data acquisition process and recommended changes on the devices in question.

Finally, set up your preferred source control application and an empty repository according to the configuration in */etc/cisco-config-backuprc*. The perl script supports CVS and git. How to do this is beyond the scope of this document.

However, git support requires a repository server for proper shared access to a master repository. I strongly advise against putting sensitive data such as password hashes or clear text VPN PSKs into a cloud based git service such as GitHub. Not even if the repository is marked private. There have been data breaches before.

On the other hand CVS is easier to set up and doesn't need extensive infrastructure.

## Running.
Before running this script, you need to prepare the AS/400 environment. Refer to [the documentation](../as400/README.md).

Available command line options, mostly for debugging purposes:
```
cisco-erfassung(.pl) [options] hostname [hostname ...]

-c: Suppress CVS/git functions
-d: Enable debug mode
-h: Show this help and exit
-n: Suppress setting empty database fields to NULL
-o: Suppress cleanup of orphaned database entries, and orphaned CVS/git files
-t: Test database connection and exit
-v: Show version and exit
```

If no hostnames are given, all hosts found in the database are handled, if eligible for automatic handling. The automatic-handling flag is ignored when passing hostnames on the command line.

**Note:** Logging is done entirely via syslog, facility *user*, unless you're using debug-mode, which also emits messages on stdout.

If the script runs without issues, I recommend to run it at least daily from *cron*.

## Bugs and enhancement ideas.
- Parse configuration headers and emit message when running-config age > startup-config age: No `wr` done.
- Use date/time functions from one module and not two.

----

2024-08-04 poc@pocnet.net
