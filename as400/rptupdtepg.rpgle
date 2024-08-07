     HCOPYRIGHT('Patrik Schindler <poc@pocnet.net>, 2023-11-23')
     H*
     H* This file is part of cisco-erfassung, an application conglomerate for
     H*  management of Cisco devices on AS/400, i5/OS and IBM i.
     H*
     H* This is free software; you can redistribute it and/or modify it
     H*  under the terms of the GNU General Public License as published by the
     H*  Free Software Foundation; either version 2 of the License, or (at your
     H*  option) any later version.
     H*
     H* It is distributed in the hope that it will be useful, but WITHOUT
     H*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
     H*  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
     H*  for more details.
     H*
     H* You should have received a copy of the GNU General Public License along
     H*  with it; if not, write to the Free Software Foundation, Inc., 59
     H*  Temple Place, Suite 330, Boston, MA 02111-1307 USA or get it at
     H*  http://www.gnu.org/licenses/gpl.html
     H*
     H* Compiler flags.
     HDFTACTGRP(*NO) ACTGRP(*CALLER) ALWNULL(*USRCTL)
     H*
     H* Tweak default compiler output: Don't be too verbose.
     HOPTION(*NOXREF : *NOSECLVL : *NOSHOWCPY : *NOEXT : *NOSHOWSKP)
     H*
     H* When going prod, enable this for more speed.
     HOPTIMIZE(*FULL)
     H*
     H**********************************************************************
     H* List of INxx, we use:
     H*- Other Error Handling:
     H*     74: EOF from database file
     H*     75: Printing Overflow Indicator
     H*
     H**********************************************************************
     F* File descriptors. Unfortunately, we're bound to handle files by file
     F*  name or record name. We can't use variables to make this more dynamic.
     F* Restriction of RPG.
     F*
     F* Main/primary file.
     FOSUPDTELF IF   E           K DISK
     FACUPDLF   IF   E           K DISK
     F*
     F* Printer File for output.
     FRPTUPDTEPTO    E             PRINTER OFLIND(*IN75)
     F*
     D**********************************************************************
     D* Global Variables (additional to autocreated ones by referenced files).
     D*
     C**********************************************************************
     C* This is very straightforward. Read all records and copy to printer
     C*  file.
     C*
     C* First, print out the headings.
     C                   WRITE     PRT1PAG
     C*----------------------------
     C                   WRITE     PRTHEAD1
     C*
     C* Now, iterate until EOF and handle page overflows.
     C     *LOVAL        SETGT     UPDATES
     C     *ZERO         DOWEQ     *ZERO
     C                   READ      UPDATES                                74
     C*
     C     *IN74         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C                   WRITE     PRTLST1
     C*
     C* Handle Page Overflow.
     C     *IN75         IFEQ      *ON
     C                   WRITE     PRTFOOT
     C                   WRITE     PRTHEAD1
     C                   MOVE      *OFF          *IN75
     C                   ENDIF
     C*
     C                   ENDDO
     C                   WRITE     PRTFOOT
     C*----------------------------
     C                   WRITE     PRTHEAD2
     C*
     C* Now, iterate until EOF and handle page overflows.
     C     *LOVAL        SETGT     ACUPDATES
     C     *ZERO         DOWEQ     *ZERO
     C                   READ      ACUPDATES                              74
     C*
     C     *IN74         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C                   WRITE     PRTLST2
     C*
     C* Handle Page Overflow.
     C     *IN75         IFEQ      *ON
     C                   WRITE     PRTFOOT
     C                   WRITE     PRTHEAD2
     C                   MOVE      *OFF          *IN75
     C                   ENDIF
     C*
     C                   ENDDO
     C*----------------------------
     C* Finished. Write closing Record Format.
     C                   WRITE     PRTEND
     C*
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C**********************************************************************
     C* vim: syntax=rpgle colorcolumn=81 autoindent noignorecase
