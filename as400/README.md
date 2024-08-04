This directory contains text-based full-screen applications derived from parts of my [AS/400 Subfile Template](https://github.com/PoC-dev/as400-sfltemplates), and the accompanying table definitions supporting the script in the `../linux` subdirectory.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung). Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*. The project itself is subject to the GNU Public License version 2.

## Introduction.
The application collection in here is meant for supporting the functions listed in the [root directory README](../README.md).

Data is collected through a Perl script having been tested under Linux only (because it has some external module dependencies).

Please note that the AS/400 UI is currently in German language only.

## Preparation.
For details regarding the handling/uploading of the files in this directory, please refer to the README of my templates project mentioned above. You need to
- create a library for the data: `crtlib cisco` in a 5250 session,
- create a source physical file to contain the sources within said library: `crtsrcpf cisco/sources rcdlen(112)` in a 5250 session,
- upload the files: `ftp as400-ip < ftpupload.txt` from your host, assumedly Linux.

**Note:** The applications rely on certain objects from the subfile templates mentioned before:
- the *genericsmsg* message file (for error message presentation),
- the menu includes in *qgpl/menuuim*.

Make sure you created those according to the instructions in the subfile template documentation before continuing with object compilation here.

## Compiling the AS/400 objects.
From a 5250 session, issue
```
chgcurlib cisco
wrkmbrpdm *curlib/sources
```

There's a hierarchy of dependencies to observe. Thus, objects are to be compiled in a certain order depending on their type. In the list being shown, enter 14 into the OPT field on each line where the type matches, and press Enter to start the compile.

The order of types is:
1. PF
1. LF
1. DSPF
1. PRTF
1. RPGLE

**Note:** The print files need certain parameters at compile time. Do not use 14 for these, but the respective compile command at the beginning of every print file.

The help panel groups have no dependencies and can be compiled independent of any order.

**Note:** The main menu cannot be compiled with option 14. You can find the correct compile command at the beginning of CMDCISCO.

### Upgrading from earlier versions.
Sometimes, you want to upgrade the code base to the latest version from github. But there might have been incompatible changes introduced meanwhile. Please read the [NEWS](../NEWS.md) for incompatible changes and remedies.

Apart from this, the easiest way to upgrade is to upload/overwrite the source members, and follow the above directions to recompile the objects. **There is one notable exception! No physical files should be just recompiled.** If you try, one of two things might happen:
- Compilation stops because there are files relating to the PF, making it impossible to delete the PF without manual intervention,
- Compilation commences and overwrites the PF and all contained data.

Usually this is not what you want. You **can** *update* a PF in place according to the updated description, though:
```
chgpf file(*curlib/mypf) srcfile(*curlib/sources)
```

This will move the existing file out of the way, create a new file, copy back existing data, adjust journaling accordingly, and delete the old file.

If changes could result in discarding of existing data, a screen will pop up and warn you. Usually, it's safe to commence the operation by answering `(I)gnore` (possible loss of data). My changes will always be done in a way to not discard important data. Afterwards, just continue as directed above with the other file types.

## Journal the database tables for commitment control.
Commitment control is a way to collect multiple database changes, and either apply them completely or not. This assures a consistent state of all the database tables in question.

Commitment control requires tables to be journaled. Create the journal related objects and start the journaling process.
```
crtjrnrcv jrnrcv(cisco00001) threshold(5120)
crtjrn jrn(ciscojrn) jrnrcv(*curlib/cisco00001) mngrcv(*system) dltrcv(*yes) rcvsizopt(*rmvintent)
strjrnpf file(*curlib/acdcapf *curlib/acmatchpf *curlib/cfgverpf *curlib/dcapf *curlib/hstpf *curlib/invpf *curlib/osmatchpf *curlib/vlanpf) jrn(*curlib/ciscojrn) omtjrne(*opnclo)
```
**Note:** The status of `strjrnpf` is retained between IPLs. This must be done just once.

## Use the applications.
You can use the applications by issuing
```
chgcurlib cisco
go cmdcisco
```

This presents you with a menu from where you can choose the individual applications.

**Note:** Extensive online help (in German language) is provided. You can access the initial help text in the main menu (by pressing `F1`) to get started quickly.

## ToDo.
Main Host list/master file: HSTDF HSTHP HSTPF HSTPG HSTPOSLF:
- Use transactions for deleting auxiliary table contents
- Expand error handling for auxiliary table updates
- When deleting an entry, also delete the corresponding entry in OSMRPTPF.

----

2024-08-03 poc@pocnet.net
