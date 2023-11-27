     HCOPYRIGHT('Patrik Schindler <poc@pocnet.net>, 2023-10-19')
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
     HDFTACTGRP(*NO) ACTGRP(*CALLER)
     H*
     H* Tweak default compiler output: Don't be too verbose.
     HOPTION(*NOXREF : *NOSECLVL : *NOSHOWCPY : *NOEXT : *NOSHOWSKP)
     H*
     H* When going prod, enable this for more speed/less CPU load.
     HOPTIMIZE(*FULL)
     H*
     H*************************************************************************
     H* List of INxx, we use:
     H*- Keys:
     H* 01..24: Command Attn Keys. (DSPF)
     H*- SFL Handling:
     H*     31: SFLDSP.
     H*     32: SFLDSPCTL.
     H*     33: SFLCLR.
     H*     34: SFLEND, EOF from Database file.
     H*
     H*************************************************************************
     F* File descriptors. Unfortunately, we're bound to handle files by file
     F*  name or record name. We can't use variables to make this more dynamic.
     F* Restriction of RPG.
     F*
     FINVPF     IF   E           K DISK
     F*
     F* Display file.
     FINVDF     CF   E             WORKSTN
     F                                     SFILE(INVSFL:SFLRCDNBR)
     F*
     F*************************************************************************
     D* Global Variables (additional to autocreated ones by referenced files).
     D* Sorted by size, descending, to minimise memory padding.
     D*
     D*************************************************************************
     C* This is needed for parameter passing.
     C     *ENTRY        PLIST
     C                   PARM                    HOSTNAME$        38
     C*
     C* This is to stay on screen in any case.
     C                   WRITE     INVBTM
     C*
     C     MAINREENTRY   TAG
     C*
     C* Now let the real fun begin!
     C                   EXSR      LOADDSPSFL
     C                   EXFMT     INVCTL
     C*
     C* Handle Returned F-Keys. These are usually defined as CA in the DSPF and
     C*  return no data to handle.
     C                   SELECT
     C*------------------------------------------------------------------------
     C* Handle SFL Reload with data from database.
     C     *IN05         WHENEQ    *ON
     C                   EXSR      LOADDSPSFL
     C                   GOTO      MAINREENTRY
     C*
     C* Go to previous screen if user pressed F12.
     C     *IN12         WHENEQ    *ON
     C                   MOVE      *OFF          *IN12
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C*------------------------------------------------------------------------
     C                   ENDSL
     C*
     C* Properly end *PGM. With ACTGRP anything else than *NEW, we must set LR!
     C                   MOVE      *ON           *INLR
     C                   RETURN
     C*
     C*************************************************************************
     C* SFL subroutines
     C*************************************************************************
     C     CLEARSFL      BEGSR
     C* Reset stuff to before the first load.
     C                   MOVEA     '0010'        *IN(31)
     C                   MOVE      *ZERO         SFLRCDNBR
     C                   WRITE     INVCTL
     C                   MOVE      *OFF          *IN33
     C*
     C                   ENDSR
     C*************************************************************************
     C     LOADDSPSFL    BEGSR
     C* Read over next, at most SFLPAG count of records in the nicely sorted LF
     C*  and write them into the SFL. Increment SFLRCDNBR which determines the
     C*  line where the record is to be be inserted.
     C* Stop when SFL is full or EOF happens (*IN34).
     C*
     C* Reset SFL state to default.
     C                   EXSR      CLEARSFL
     C*
     C* Jump to first record of desired hostname.
     C     HOSTNAME$     SETLL     SHOWINV
     C*
     C* Read loop start.
     C     1             DO        999
     C     HOSTNAME$     READE     SHOWINV                                34
     C     *IN34         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Write ready-made records into the SFL.
     C                   ADD       1             SFLRCDNBR
     C*
     C* Make sure we know if the SFL is full.
     C     SFLRCDNBR     IFGE      999
     C                   MOVE      *ON           *IN96
     C                   LEAVE
     C                   ENDIF
     C*
     C                   WRITE     INVSFL
     C                   ENDDO
     C*
     C* Loop ended. Display the subfile- and subfile control records or
     C*  indicate an empty SFL by (not) setting IN31.
     C     SFLRCDNBR     IFGT      *ZERO
     C                   MOVE      *ON           *IN31
     C* Jump back to first line.
     C                   Z-ADD     1             SFLRCDNBR
     C*
     C                   ELSE
     C* If SFL is empty, don't try to show: We'll crash! Instead show excuse.
     C                   MOVE      *OFF          *IN31
     C                   WRITE     INVND
     C                   ENDIF
     C*
     C* Finally allow to show all the data on the display. Actual DSPF write
     C*  is handled in the main routine.
     C                   MOVE      *ON           *IN32
     C*
     C                   ENDSR
     C*************************************************************************
     C* vim: syntax=rpgle colorcolumn=81 autoindent noignorecase
