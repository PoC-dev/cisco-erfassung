This directory contains a text-based full-screen application derived from parts of my [AS/400 Subfile Template](https://github.com/PoC-dev/as400-sfltemplates), and the accompanying table definitions for the script one directory up.

## License.
This document is part of the Cisco device management solution, to be found on [GitHub](https://github.com/PoC-dev/cisco-erfassung) - see there for further details. Its content is subject to the [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) license, also known as *Attribution-ShareAlike 4.0 International*.

## Introduction.

The application collection in here is meant for
- maintaining a master file of Cisco components, with accompanying login credentials,
- maintaining master files of desired software versions for said components,
- present automatically derived inventory data,
- show where updates are necessary through a printed report.

Inventory data is collected through a Perl script having been tested under Linux only (because it has some external module dependencies).

Please note that the AS/400 UI is currently in German language only.

## Preparation.
For details regarding the handling/uploading of the files in this directory, please refer to the README of my above templates project. You need to
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

**Note:** The print files need certain parameters at compile time. You can find the correct compile command at the beginning of every print file.

The help panel groups have no dependencies and can be compiled independent of any order.

**Note:** The main menu cannot be compiled with option 14. You can find the correct compile command at the beginning of CMDCISCO.

## Journal the database tables for commitment control.

Commitment control is a way to collect multiple database changes, and either apply them completely or not. This assures a consistent state of all the database tables in question.

Commitment control requires tables to be journaled. Create the journal related objects and start the journalling process.
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

**Note:** Extensive online help (in German language) is provided. Please read the initial help text in the main menu (by pressing `F1`) to get started quickly.

2023-11-27 poc@pocnet.net
