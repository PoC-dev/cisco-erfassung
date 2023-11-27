This is a collection of scripts and other files to ease handling/updating a more or less large amount of Cisco devices.

The application as a whole is split in two:
- [Database tables and maintenance application](as400/README.md) for AS/400 V4R5 and successors,
- [Perl script](linux/README.md) for automatic inventory data collection.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung). Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*.

## Using.
First, read the already mentioned READMEs for both parts. Roughly, you need to
- assemble the AS/400 part of the application,
- manually fill the hosts master file with data about how to connect to your devices,
- set up ODBC on Linux so the perl script can connect to the database,
- set up CVS or git on the Linux machine for keeping track of configuration changes,
- run the perl script to acquire data,
- manually fill subsequent tables with desired software versions,
- run the report for learning which devices need updates.

**Note:** Extensive online help (in German language) is provided in the AS/400 part. Please read the initial help text in the main menu (by pressing `F1`) to get started quickly.

## Acknowledgements.
A huge thank you goes to [Mathias Peter IT-Systemhaus](https://www.mathpeter.com), my current employer who allowed me to spend part of my work time on this project.

We agreed on this "light" version of the application to be released as OpenSource, and a non-public, more complete version for our internal use, featuring:
- customer numbers,
- further device flags,
- update audit trails when doing a "maintenance run",
- and more.

Contact me if you're interested. This version will be available for a fee.

**Note:** Currently, the internal version is still in development stage and not yet ready for external deployment.

2023-11-27 poc@pocnet.net
