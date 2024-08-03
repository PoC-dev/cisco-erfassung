This is a collection of scripts and other files to ease handling/updating a more or less large amount of Cisco devices, and some CLI compatibles.

Please read the [NEWS](NEWS.md) for incompatible changes and remedies.

The application is used in two production environments — at least that's what I know for sure — and thus is continuously tested against
- Cisco IOS and IOS XE devices
  - Routers:
    - classic IOS ranging from 2500s and 2600 running IOS 12.3, 870, 1700 running 12.4, 880, c880, 2900 running 15.x
    - 1100 and ISR4K running IOS XE 17.3 through 17.9
  - Switches: A very broad range covering
    - classic IOS ranging from version 12.1 (Cat 2950) to 15.2 (Cat 2960, 3560, 3750)
    - IOS XE 16 and 17 on Cat 3850 and Cat 9300
  - WiFi AP1142N
- Nexus 5k/7.3

If you can't find your Cisco device in this list, that doesn't mean it won't work. It just means I have no regular access to said device (anmymore) to actually test. Chances are very high that also your device will work, if configured properly.

There is some basic support for Ubiquity swiches, but this has not been tested for a long time and should be considered "likely broken".

Some of the more elaborated HP switches should also work, but same applies here: No way to test.

The application as a whole is split in two:
- [Database tables and maintenance application](as400/README.md) for AS/400 V4R5 and successors,
- [Perl script](linux/README.md) for automatic inventory data collection.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung). Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*. The project itself is subject to the GNU Public License version 2.

## Using.
First, read the already mentioned READMEs for both parts. Roughly, you need to
- assemble the AS/400 part of the application,
- manually fill the hosts master file with data about how to connect to your devices,
- configure devices with separate login credentials having the least required authorization (optional),
- set up ODBC on Linux so the perl script can connect to the database,
- set up CVS or git on the Linux machine for keeping track of configuration changes,
- run the perl script to acquire data,
- manually fill subsequent tables with desired software versions,
- run the report for learning which devices need updates.

**Note:** Extensive online help (in German language) is provided in the AS/400 part. Please read the initial help text in the main menu (by pressing `F1`) to get started quickly.

Consult [README-devices-requirements](linux/README-devices-requirements.md) to learn about the data acquisition process and recommended changes on the devices in question.

## Acknowledgements.
A huge thank you goes to [Mathias Peter IT-Systemhaus](https://www.mathpeter.com), my current employer who allowed me to spend part of my work time on this project.

We agreed on this "light" version of the application to be released as OpenSource, and a non-public, more complete version for our internal use, featuring:
- customer numbers,
- further device flags,
- audit trails for individual tasks when doing a "maintenance run",
- and more.

Contact me if you're interested. This version will be available for a fee.

**Note:** Currently, the internal version is still in development stage and not yet ready for external deployment.

----

2024-08-04 poc@pocnet.net
