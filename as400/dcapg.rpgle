     HCOPYRIGHT('Patrik Schindler <poc@pocnet.net>, 2024-08-04')
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
     HCVTOPT(*DATETIME) DFTACTGRP(*NO) ACTGRP(*CALLER) ALWNULL(*USRCTL)
     H*
     H* Tweak default compiler output: Don't be too verbose.
     HOPTION(*NOXREF : *NOSECLVL : *NOSHOWCPY : *NOEXT : *NOSHOWSKP)
     H*
     H* When going prod, enable this for more speed.
     HOPTIMIZE(*FULL)
     H*
     H*************************************************************************
     H* List of INxx, we use.
     H*- Keys:
     H* 01..24: Command Attn Keys (DSPF).
     H* 25..26: Paging (DSPF).
     H*- SFL Handling (both regular and deletion):
     H*     31: SFLDSP.
     H*     32: SFLDSPCTL.
     H*     33: SFLCLR.
     H*     34: SFLEND, EOF from Database file.
     H*- General DSPF Conditioning:
     H*     43: Show ENABLE field (if not NULL).
     H*     44: DCA = 1
     H*     45: UPD_IGN = 1
     H*     46: ACU_IGN = 1
     H*     47: Show red 'Erfassung too old' warning.
     H*     48: Show CFSAVD field (if not NULL).
     H*     49: Show CFUPDT field (if not NULL).
     H*     50: Show red 'Config not saved' warning.
     H*     51: Show red 'End of Support!' warning.
     H*     52: Show VER_SOLL/Update if version is different to given version.
     H*     53: Show ASDM version (if not NULL).
     H*     54: Show reload reason (if not NULL).
     H*     55: Color reload reason red, so it indicates error.
     H*     56: Show string if failover is present.
     H*     57: Show VTP pruning (if not NULL).
     H*     58: VTP_PRUNING = 1
     H*     60: Show DSPREC Form 2 instead of 1.
     H*- Other Error Handling:
     H*     71: CHAIN found no records in hosts
     H*     72: CHAIN found no records in dca
     H*     73: CHAIN found no records in dcaosmatch
     H*
     H*************************************************************************
     F* File descriptors. Unfortunately, we're bound to handle files by file
     F*  name or record name. We can't use variables to make this more dynamic.
     F* Restriction of RPG.
     F*
     F* Main/primary files.
     FHSTPF     IF   E           K DISK
     FDCAPF     IF   E           K DISK
     FDCAOSMATCHIF   E           K DISK    PREFIX(N_)
     FVLANPF    IF   E           K DISK    USROPN
     F*
     F* Display File.
     FDCADF     CF   E             WORKSTN
     F                                     SFILE(MAINSFL:SFLRCDNBR)
     F*
     D*************************************************************************
     D* A timestamp looks like this: yyyy-mm-dd-hh.mm.ss.mmmmmm
     D*
     DHOSTNAME$        S                    LIKE(HOSTNAME)
     D*
     D* Storage for handling timestamp data for checking too old erfassung.
     DTS_DB            S               Z
     DTS_NOW           S               Z
     D*
     DTS_RESULT        S              3S 0
     D*
     D* Storage for handling date for checking past EOS due.
     DDT_DB            S               D
     DDT_NOW           S               D
     D*
     DDT_RESULT        S              4S 0
     D*
     C*************************************************************************
     C* This is where we come in.
     C     *ENTRY        PLIST
     C                   PARM                    HOSTNAME$        38
     C*
     C* Define a a search key for finding OS Updates.
     C     OSMATCH       KLIST
     C                   KFLD                    N_FLASH
     C                   KFLD                    N_MODEL
     C                   KFLD                    N_RAM
     C*
     C* Find given hostname.
     C     HOSTNAME$     CHAIN     HOSTS                              71
     C     *IN71         IFEQ      *ON
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C                   ENDIF
     C*
     C     HOSTNAME$     CHAIN     DCATBL                             72
     C     *IN72         IFEQ      *ON
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C                   ENDIF
     C*
     C* Fill key fields for lookup.
     C                   Z-ADD     FLASH         N_FLASH
     C                   MOVE      MODEL         N_MODEL
     C                   Z-ADD     RAM           N_RAM
     C*
     C* Lookup alternate OS version, and EOS information.
     C*  Values will be used later.
     C     OSMATCH       CHAIN     CHECKOSTBL                         73
     C*
     C* Code statements appear in the same order as in the DSPF.
     C*-------------------------------------------------------------------------
     C* Display for page one.
     C*
     C* Show or hide ENABLE depending on availability.
     C                   IF        NOT %NULLIND(ENABLE)
     C                   MOVE      *ON           *IN43
     C                   ELSE
     C                   MOVE      *OFF          *IN43
     C                   ENDIF
     C*
     C* Fill out automation field.
     C     DCA           IFEQ      *ZERO
     C                   MOVE      *OFF          *IN44
     C                   ELSE
     C                   MOVE      *ON           *IN44
     C                   ENDIF
     C*
     C* Fill out updates field.
     C     UPD_IGN       IFEQ      *ZERO
     C                   MOVE      *OFF          *IN45
     C                   ELSE
     C                   MOVE      *ON           *IN45
     C                   ENDIF
     C*
     C* Fill out ac updates field.
     C     ACU_IGN       IFEQ      *ZERO
     C                   MOVE      *OFF          *IN46
     C                   ELSE
     C                   MOVE      *ON           *IN46
     C                   ENDIF
     C*
     C* Shorten Time Stamps for last inventory run.
     C     16            SUBST     STAMP:1       STAMP$
     C     '.':':'       XLATE     STAMP$        STAMP$
     C     '-':' '       XLATE     STAMP$:11     STAMP$
     C*
     C* Show warning message if last inventory is older than three days. Cisco-
     C*  erfassung should run every single day.
     C                   TIME                    TS_NOW
     C                   MOVE      STAMP         TS_DB
     C     TS_NOW        SUBDUR    TS_DB         TS_RESULT:*D
     C     TS_RESULT     IFGT      3
     C                   MOVE      *ON           *IN46
     C                   ELSE
     C                   MOVE      *OFF          *IN46
     C                   ENDIF
     C*
     C* Show cfupdt depending on availability.
     C                   IF        NOT %NULLIND(CFUPDT)
     C     16            SUBST     CFUPDT:1      CFUPDT$
     C     '.':':'       XLATE     CFUPDT$       CFUPDT$
     C     '-':' '       XLATE     CFUPDT$:11    CFUPDT$
     C                   MOVE      *ON           *IN48
     C                   ELSE
     C                   MOVE      *OFF          *IN48
     C                   ENDIF
     C*
     C* Show cfsavd depending on availability.
     C                   IF        NOT %NULLIND(CFSAVD)
     C     16            SUBST     CFSAVD:1      CFSAVD$
     C     '.':':'       XLATE     CFSAVD$       CFSAVD$
     C     '-':' '       XLATE     CFSAVD$:11    CFSAVD$
     C                   MOVE      *ON           *IN49
     C                   ELSE
     C                   MOVE      *OFF          *IN49
     C                   ENDIF
     C*
     C* Alert if running-config is newer than startup-config.
     C                   IF        NOT %NULLIND(CFUPDT)
     C                   IF        NOT %NULLIND(CFSAVD)
     C     CFUPDT        IFGT      CFSAVD
     C                   MOVE      *ON           *IN50
     C                   ELSE
     C                   MOVE      *OFF          *IN50
     C                   ENDIF
     C                   ENDIF
     C                   ENDIF
     C*------------------------------------------
     C* Display for page two.
     C*----------------------------
     C     *IN73         IFEQ      *OFF
     C* A record has been found.
     C*
     C* Check if the entry we found signals EOS. If yes, show EOS warning.
     C                   IF        NOT %NULLIND(N_EOS)
     C                   TIME                    DT_NOW
     C                   MOVE      N_EOS         DT_DB
     C     DT_NOW        SUBDUR    DT_DB         DT_RESULT:*D
     C* If date difference is greater than 0...
     C     DT_RESULT     IFGT      *ZERO
     C                   MOVE      *ON           *IN51
     C                   ELSE
     C                   MOVE      *OFF          *IN51
     C                   ENDIF
     C*
     C                   ENDIF
     C*
     C* Check if the found OS version is equal to the current version. If not,
     C*  we have an update to show.
     C     VERSION       IFNE      N_VERSION
     C                   MOVE      *ON           *IN52
     C                   MOVE      N_VERSION     VER_SOLL
     C                   ELSE
     C                   MOVE      *OFF          *IN52
     C                   ENDIF
     C*
     C                   ENDIF
     C*----------------------------
     C                   IF        NOT %NULLIND(ASA_DM_VER)
     C                   MOVE      *ON           *IN53
     C                   ELSE
     C                   MOVE      *OFF          *IN53
     C                   ENDIF
     C*
     C                   IF        NOT %NULLIND(RLD$REASON)
     C                   MOVE      *ON           *IN54
     C                   ELSE
     C                   MOVE      *OFF          *IN54
     C                   ENDIF
     C*
     C* If reload was due to some error, color field.
     C     'error'       SCAN      RLD$REASON:1                           55
     C     'Critical'    SCAN      RLD$REASON:1                           55
     C     'fault'       SCAN      RLD$REASON:1                           55
     C*
     C* This numeric A, so we can use it directly.
     C                   MOVE      ASA_FOVER     *IN56
     C*
     C*-------------------------------------------------------------------------
     C* Now, show forms as desired. This is a crude multipage-form workaround.
     C*
     C     *ZERO         DOWEQ     *ZERO
     C*
     C     *IN60         IFEQ      *OFF
     C                   EXFMT     DSPHST1
     C                   ELSE
     C                   EXFMT     DSPHST2
     C                   ENDIF
     C*
     C                   SELECT
     C*
     C     *IN10         WHENEQ    *ON
     C                   EXSR      DSPVLAN
     C*
     C     *IN25         WHENEQ    *ON
     C                   MOVE      *OFF          *IN60
     C*
     C     *IN26         WHENEQ    *ON
     C                   MOVE      *ON           *IN60
     C*
     C                   OTHER
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C*
     C                   ENDSL
     C*
     C* Handle exit separately: It won't be recognized when returning from
     C*  DSPVLAN.
     C     *IN03         IFEQ      *ON
     C     *IN12         OREQ      *ON
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C                   ENDIF
     C*
     C                   ENDDO
     C*-------------------------------------------------------------------------
     C*
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C**************************************************************************
     C     DSPVLAN       BEGSR
     C*
     C* Setup SFL.
     C                   MOVEA     '0110'        *IN(31)
     C                   MOVE      *ZERO         SFLRCDNBR
     C                   WRITE     MAINCTL
     C                   MOVE      *OFF          *IN33
     C                   OPEN      VLANPF
     C     HOSTNAME      SETLL     VLANTBL
     C*
     C* Read over all records and write them into the SFL. Increment SFLRCDNBR
     C*  which determines the line where the record is to be be inserted. Stop
     C*  when EOF happens (*IN34).
     C*----------------------------
     C* Read loop start.
     C     *ZERO         DOWEQ     *ZERO
     C     HOSTNAME      READE     VLANTBL                                34
     C     *IN34         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Increment line-number-to-insert.
     C                   ADD       1             SFLRCDNBR
     C*
     C* Make sure we know if the SFL is full.
     C     SFLRCDNBR     IFGE      999
     C                   MOVE      *ON           *IN96
     C                   LEAVE
     C                   ENDIF
     C*
     C* Write ready-made records into the SFL.
     C                   WRITE     MAINSFL
     C*
     C                   ENDDO
     C*----------------------------
     C* Loop ended.
     C                   CLOSE     VLANPF
     C                   WRITE     MAINBTM
     C*
     C* Ouput VTP Pruning status.
     C                   IF        NOT %NULLIND(VTP_PRUNE)
     C                   MOVE      *ON           *IN57
     C* This numeric A, so we can use it directly.
     C                   MOVE      VTP_PRUNE     *IN58
     C                   ELSE
     C                   MOVE      *OFF          *IN57
     C                   ENDIF
     C*
     C* Display the subfile- and subfile control records, or indicate an empty
     C*  SFL by not setting IN31, and write the "no data" record.
     C     SFLRCDNBR     IFGT      *ZERO
     C                   MOVE      *ON           *IN31
     C                   ELSE
     C                   MOVE      *OFF          *IN31
     C                   WRITE     MAINND
     C                   ENDIF
     C*
     C* Set Cursor Position for SFL to 1.
     C                   Z-ADD     1             SFLRCDNBR
     C*
     C* Finally, show the SFL.
     C                   EXFMT     MAINCTL
     C*
     C* Just go back with F12.
     C     *IN12         IFEQ      *ON
     C                   MOVE      *OFF          *IN12
     C                   ENDIF
     C*
     C                   ENDSR
     C**************************************************************************
     C* vim: syntax=rpgle colorcolumn=81 autoindent noignorecase
