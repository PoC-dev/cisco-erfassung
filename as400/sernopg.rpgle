     HCOPYRIGHT('Patrik Schindler <poc@pocnet.net>, 2025-08-04')
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
     HDFTACTGRP(*NO) ACTGRP(*NEW)
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
     H* 25..27: Paging up/down, Home. (DSPF)
     H*     29: Valid Command Key pressed. (DSPF)
     H*- SFL Handling (both regular and deletion):
     H*     31: SFLDSP.
     H*     32: SFLDSPCTL.
     H*     33: SFLCLR.
     H*     34: SFLEND, EOF from Database file.
     H*     35: Begin-of-File, BOF from Database file.
     H*- General DSPF Conditioning:
     H*     41: Place Cursor in Pos-To Field.
     H*- Other Stuff:
     H*     71: READC from Subfile EOF.
     H*     72: SETLL of POSTO found no records.
     H*- Error Conditions:
     H*     99: Set Reverse Video for SFL OPT entry.
     H*
     H*************************************************************************
     F* File descriptors. Unfortunately, we're bound to handle files by file
     F*  name or record name. We can't use variables to make this more dynamic.
     F* Restriction of RPG.
     F*
     F* LF as positioning aid for READ/READP: We read just key values which is
     F*  considerably faster than reading whole records from the main file.
     F*  Also this helps us keeping a consistent pointer state between the
     F*  virtual SFL canvas vs. database current record position. Input only!
     F* Important! We're dealing with a *file* pointer, which is implicitly
     F*  shared by all record formats in that logical file!
     FSERNOLF   IF   E           K DISK    INFDS(FINFDS)
     F*
     F* Display file with multiple subfiles among other record formats.
     FSERNODF   CF   E             WORKSTN
     F                                     SFILE(MAINSFL:SFLRCDNBR)
     F*
     F*************************************************************************
     D* Global Variables (additional to autocreated ones by referenced files).
     D* Sorted by size, descending, to minimise memory padding.
     D*
     D* Needed for proper UPDATE of SFL: An overlay of our current data from
     D*  the main file. Beware, this is *not* a copy but just a pointer (of a
     D*  different kind).
     DT_INV          E DS                  EXTNAME(SERNOLF:FWDPOS) INZ
     D* To actually store stuff, we need separate space. V4 doesn't know about
     D*  LIKEDS, so we need to build the struct by hand.
     DC_INV            DS                  INZ
     D C_INV$SERNO                         LIKE(INV$SERNO)
     D C_HOSTNAME                          LIKE(HOSTNAME)
     D C_INV$NAME                          LIKE(INV$NAME)
     D* DS for holding dynamic data for shortening Strings.
     DSTRSHRTDS        DS                  INZ
     D STRLEN_CUR                     3S 0
     D STRLEN_MIN                     3S 0
     D STRLEN_MAX                     3S 0
     D*
     D* How many records do we have in the database?
     D* Information struct for getting a file's record count.
     DFINFDS           DS
     D DBRCDCNT              156    159I 0
     D*
     D* Must equal SFLPAG in the Display File. CONST not allowed: Is already
     D*  specified as ordinary variable via DSPF-Inclusion. Duh!
     DSFLSIZ           S              5S 0 INZ(13)
     D*
     D* File Error status variable to track READ/WRITE/UPDATE/DELETE.
     DFSTAT            S              5S 0
     D*
     D* What to display in CFGVER?
     DTYP              S              3A
     D*
     D* This should contain the number of records last read into the SFL.
     DSFLRCDCNT        S              2S 0
     D*
     D* This is used for proper READP iterations and gets calculated on the fly
     D*  within RELOADSFL and PAGEUP routines.
     DREADPVAL         S              2S 0
     D*
     D* Call prototypes -------------------------------------------------------
     DCFGVERPG         PR                  EXTPGM('CFGVERPG')
     DCFGHST                               LIKE(HOSTNAME)
     DCFGTYP                               LIKE(TYP)
     D*
     DDCAPG            PR                  EXTPGM('DCAPG')
     DDCAHST                               LIKE(HOSTNAME)
     D*
     DINVPG            PR                  EXTPGM('INVPG')
     DINVHST                               LIKE(HOSTNAME)
     D*
     D*************************************************************************
     C* Start the main loop: Write SFLCTL and wait for keypress to read.
     C*  This will be handled after *INZSR was implicitly called by RPG for
     C*  the first time we run.
     C     *IN03         DOUEQ     *ON
     C     *IN12         OREQ      *ON
     C*
     C* Show  F-Key footer display.
     C                   WRITE     MAINBTM
     C*
     C* Make sure, we have an indicator of "no records" when SFL is empty.
     C     *IN31         IFEQ      *OFF
     C                   WRITE     MAINND
     C                   ENDIF
     C*
     C* Reset global SFL Error State from last loop iteration.
     C                   MOVE      *OFF          *IN99
     C*
     C* Show Subfile control record and wait for keypress.
     C                   EXFMT     MAINCTL
     C*
     C* Jump out immediately if user pressed F3. We need this additionally
     C*  to the DOUEQ-Loop to prevent another loop-cycle and thus late exit.
     C     *IN03         IFEQ      *ON
     C                   MOVE      *OFF          *IN03
     C                   RETURN
     C                   ENDIF
     C*------------------------------------------------------------------------
     C* Handle Pos-To field first, if used and enough records in database.
     C     POSTO         IFNE      *BLANK
     C     DBRCDCNT      ANDGT     SFLSIZ
     C                   MOVEL     POSTO         C_INV$SERNO
     C     C_INV$SERNO   SETLL     FWDPOS                             72
     C*
     C* Force cursor back into search field (most likely, we'll be instructed
     C*  to search again), and reset.
     C                   MOVE      *ON           *IN41
     C                   MOVE      *BLANK        POSTO
     C                   MOVE      *BLANK        C_INV$SERNO
     C*
     C* If we found something, load from there. If not, go up one page, to
     C*  prevent seeing "no data" because not found usually means EOF.
     C     *IN72         IFEQ      *OFF
     C                   EXSR      LOADDSPSFL
     C                   ELSE
     C*
     C* If we hit EOF from previous read, go back two pages. If not, one.
     C     *IN34         IFEQ      *ON
     C     SFLSIZ        MULT      2             READPVAL
     C                   ELSE
     C                   Z-ADD     SFLSIZ        READPVAL
     C                   ENDIF
     C*
     C* Read backwards to the point we calculated above.
     C                   EXSR      READPSR
     C*
     C                   ENDIF
     C                   ITER
     C*
     C                   ELSE
     C* Nothing to do, let cursor jump to or stay in SFL.
     C                   MOVE      *OFF          *IN41
     C                   ENDIF
     C*
     C*------------------------------------------------------------------------
     C* Handle Returned F-Keys. These are usually defined as CA in the DSPF and
     C*  return no data to handle. IN29 indicates any valid key has been
     C*  pressed. Watching IN29 here might save a few CPU cycles.
     C     *IN29         IFEQ      *ON
     C                   SELECT
     C*
     C*----------------------------
     C* Handle SFL Reload with data from database.
     C     *IN05         WHENEQ    *ON
     C*
     C* If @EOF, load only current number of records to prevent jumping display.
     C     *IN34         IFEQ      *OFF
     C                   Z-ADD     SFLSIZ        READPVAL
     C                   ELSE
     C                   Z-ADD     SFLRCDCNT     READPVAL
     C                   ENDIF
     C*
     C                   EXSR      READPSR
     C*
     C*------------------
     C* Scroll- and cursor handling.
     C     *IN25         WHENEQ    *ON
     C                   EXSR      PAGEDOWN
     C     *IN26         WHENEQ    *ON
     C                   EXSR      PAGEUP
     C     *IN27         WHENEQ    *ON
     C                   MOVE      *ON           *IN41
     C*
     C*----------------------------
     C                   ENDSL
     C                   ITER
     C* If no F-Keys were pressed, handle OPT choices.
     C                   ELSE
     C*
     C* Only read from SFL if SFL actually has entries!
     C     *IN31         IFEQ      *ON
     C*
     C* Loop and read changed records from the SFL. This implicitly affects the
     C*  SFL RRN variable! Read starts automatically at record 1.
     C     *ZERO         DOWEQ     *ZERO
     C                   READC     MAINSFL                                71
     C     *IN71         IFEQ      *ON
     C* If there was an error one loop-iteration before, leave loop immediately.
     C* Aka, locked record or the like; so the user can see where we stopped.
     C     *IN99         OREQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*------------------------------------------------------------------------
     C* Better use SELECT/WHENxx than CASExx: There's no "OTHER" with CASExx
     C*  but we need to ignore a blank/invalid selection with a new loop
     C*  iteration to prevent UPDATEing RRN 1 with the last READ/WRITE-Cycle
     C*  from LOADDSPSFL.
     C                   SELECT
     C*
     C     OPT           WHENEQ    '5'
     C                   CALLP     DCAPG(HOSTNAME)
     C*
     C     OPT           WHENEQ    '7'
     C                   MOVE      'cfg'         TYP
     C                   CALLP     CFGVERPG(HOSTNAME:TYP)
     C*
     C     OPT           WHENEQ    '8'
     C                   MOVE      'ver'         TYP
     C                   CALLP     CFGVERPG(HOSTNAME:TYP)
     C*
     C     OPT           WHENEQ    '9'
     C                   CALLP     INVPG(HOSTNAME)
     C*
     C     OPT           WHENEQ    ' '
     C* Reset Error State for that one entry. Remember, we're still in READC.
     C                   MOVE      *OFF          *IN99
     C*
     C                   OTHER
     C                   ITER
     C                   ENDSL
     C*------------------------------------------------------------------------
     C* Handle SFL Updates: We may only UPDATE a SFL with an immediate prior
     C*  READ. This makes the following section cumbersome. But it's still
     C*  more desirable than to reload the whole SFL after every change.
     C* Copy original data (from disk) to data-copy.
     C                   CLEAR                   C_INV
     C                   MOVEL     T_INV         C_INV
     C*
     C* Now re-read the record from the subfile position we last were at
     C* (implicit SFLRCDNBR, already set).
     C     SFLRCDNBR     CHAIN     MAINSFL
     C* Discard (outdated) data from SFL by restoring from our saved copy.
     C                   EVAL      T_INV     =   C_INV
     C* *BLANK out OPT to show to the user we're finished with that one. Keep
     C*  entry active if error occured within an EXSR call.
     C     *IN99         IFEQ      *OFF
     C                   MOVE      *BLANK        OPT
     C                   ENDIF
     C*
     C* Set conditioning INxx for every row of data or do other stuff like
     C*  shortening of strings and the like.
     C                   EXSR      PREPSFLDTA
     C*
     C* Finally, update the record in the SFL.
     C                   UPDATE    MAINSFL
     C*
     C* User may interrupt current READC-loop.
     C     *IN12         IFEQ      *ON
     C                   MOVE      *OFF          *IN12
     C                   LEAVE
     C                   ENDIF
     C*
     C* End of readc-loop!
     C                   ENDDO
     C* End of If-IN31-ON.
     C                   ENDIF
     C*------------------------------------------------------------------------
     C* End of OPT-Handling (IN29 = OFF).
     C                   ENDIF
     C* End of main loop.
     C                   ENDDO
     C* Properly end *PGM.
     C                   RETURN
     C*========================================================================
     C* SFL subroutines
     C*========================================================================
     C     CLEARSFL      BEGSR
     C* Reset SFL state to before the first load.
     C*
     C                   MOVEA     '0010'        *IN(31)
     C                   MOVE      *ZERO         SFLRCDNBR
     C                   WRITE     MAINCTL
     C                   MOVE      *OFF          *IN33
     C*
     C                   ENDSR
     C*************************************************************************
     C     LOADDSPSFL    BEGSR
     C* Read over next, at most SFLPAG count of records in the nicely sorted LF,
     C*  and write them into the SFL. Increment SFLRCDNBR which determines the
     C*  line where the record is to be be inserted.
     C* Stop when SFL is full or EOF happens (*IN34).
     C*
     C* Reset SFL state to default.
     C                   EXSR      CLEARSFL
     C*----------------------------
     C* Read loop start.
     C     1             DO        SFLSIZ
     C                   READ      FWDPOS                                 34
     C     *IN34         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Set conditioning INxx for every row of data or do other stuff like
     C*  shortening of strings and the like.
     C                   EXSR      PREPSFLDTA
     C*
     C* Reset OPT to blank to prevent stray OPT entries to be duplicated.
     C                   MOVE      *BLANK        OPT
     C*
     C* Reset error *INs.
     C                   MOVEA     '000000000'   *IN(91)
     C*
     C* Increment line-number-to-insert.
     C                   ADD       1             SFLRCDNBR
     C*
     C* Write ready-made records into the SFL.
     C                   WRITE     MAINSFL
     C                   ENDDO
     C*----------------------------
     C* Save the number of copied records.
     C                   Z-ADD     SFLRCDNBR     SFLRCDCNT
     C*
     C* Loop ended. Display the subfile- and subfile control records, or
     C*  indicate an empty SFL by (not) setting IN31.
     C*------------------
     C     SFLRCDNBR     IFGT      *ZERO
     C                   MOVE      *ON           *IN31
     C*
     C* Try to find out if next record will be EOF or not: So we can indicate
     C*  "more" or EOF to the user. This prevents a scrolldown to an empty SFL
     C*  showing "no records".
     C* Do check only if SFL is full. If not, we're certainly at EOF.
     C     SFLRCDCNT     IFEQ      SFLSIZ
     C                   READ      FWDPOS                                 34
     C     *IN34         IFEQ      *OFF
     C                   READP     FWDPOS                                 35
     C                   ENDIF
     C                   ELSE
     C* If SFL is not full, allow scrollback, if we have enough records in PF.
     C     DBRCDCNT      IFGT      SFLSIZ
     C                   MOVE      *OFF          *IN35
     C                   ENDIF
     C                   ENDIF
     C*------------------
     C                   ELSE
     C*------------------
     C* If SFL is empty, don't try to show: We'll crash! Instead show excuse.
     C                   MOVE      *OFF          *IN31
     C                   ENDIF
     C*------------------
     C*
     C* Always place cursor in line 1 after a reload.
     C                   Z-ADD     1             SFLRCDNBR
     C*
     C* Finally allow to show all the data on the display. Actual DSPF write
     C*  is handled in the main routine.
     C                   MOVE      *ON           *IN32
     C*
     C                   ENDSR
     C*************************************************************************
     C     PREPSFLDTA    BEGSR
     C* Prepare Data before inserting into the SFL: Set INxx for color, shorten
     C*  Strings or stuff like that.
     C*
     C* Pre-Calculate length for one field-to-be-shortened.
     C                   EVAL      STRLEN_MAX=%LEN(INV$SERNO$)
     C     STRLEN_MAX    SUB       3             STRLEN_MIN
     C* Cut string and optionally add ellipse (if DB field is larger).
     C                   MOVEL     *BLANK        INV$SERNO$
     C                   EVAL      STRLEN_CUR=%LEN(%TRIMR(INV$SERNO))
     C     STRLEN_CUR    IFGT      STRLEN_MAX
     C     STRLEN_MIN    SUBST     INV$SERNO:1   INV$SERNO$
     C                   CAT       '...':0       INV$SERNO$
     C                   ELSE
     C     STRLEN_MAX    SUBST     INV$SERNO:1   INV$SERNO$
     C                   ENDIF
     C*
     C* Pre-Calculate length for one field-to-be-shortened.
     C                   EVAL      STRLEN_MAX=%LEN(HOSTNAME$)
     C     STRLEN_MAX    SUB       3             STRLEN_MIN
     C* Cut string and optionally add ellipse (if DB field is larger).
     C                   MOVEL     *BLANK        HOSTNAME$
     C                   EVAL      STRLEN_CUR=%LEN(%TRIMR(HOSTNAME))
     C     STRLEN_CUR    IFGT      STRLEN_MAX
     C     STRLEN_MIN    SUBST     HOSTNAME:1    HOSTNAME$
     C                   CAT       '...':0       HOSTNAME$
     C                   ELSE
     C     STRLEN_MAX    SUBST     HOSTNAME:1    HOSTNAME$
     C                   ENDIF
     C*
     C* Pre-Calculate length for one field-to-be-shortened.
     C                   EVAL      STRLEN_MAX=%LEN(INV$NAME$)
     C     STRLEN_MAX    SUB       3             STRLEN_MIN
     C* Cut string and optionally add ellipse (if DB field is larger).
     C                   MOVEL     *BLANK        INV$NAME$
     C                   EVAL      STRLEN_CUR=%LEN(%TRIMR(INV$NAME))
     C     STRLEN_CUR    IFGT      STRLEN_MAX
     C     STRLEN_MIN    SUBST     INV$NAME:1    INV$NAME$
     C                   CAT       '...':0       INV$NAME$
     C                   ELSE
     C     STRLEN_MAX    SUBST     INV$NAME:1    INV$NAME$
     C                   ENDIF
     C*
     C                   ENDSR
     C*========================================================================
     C* Scroll handling/positioning SFL Subroutines
     C*========================================================================
     C     GOFIRST       BEGSR
     C* Reset file pointer as we were run for the first time.
     C     *LOVAL        SETLL     FWDPOS
     C*
     C                   EXSR      LOADDSPSFL
     C                   MOVE      *ON           *IN35
     C*
     C                   ENDSR
     C*************************************************************************
     C     PAGEDOWN      BEGSR
     C* What to do if user pressed pagedown: Blindly switch off BOF indicator
     C*  and start another iteration of load-from-here-into-SFL.
     C* Can be called only without EOF being set (prohibited by DSPF cond.)
     C                   MOVE      *OFF          *IN35
     C*
     C                   EXSR      LOADDSPSFL
     C*
     C                   ENDSR
     C*************************************************************************
     C     PAGEUP        BEGSR
     C* What to do if user pressed pageup: Calculate proper count of backward
     C*  reads and do it.
     C     *IN34         IFEQ      *OFF
     C     SFLSIZ        MULT      2             READPVAL
     C                   ELSE
     C     SFLSIZ        ADD       SFLRCDCNT     READPVAL
     C                   ENDIF
     C*
     C                   EXSR      READPSR
     C*
     C                   ENDSR
     C*************************************************************************
     C     READPSR       BEGSR
     C* Common SR for handling relative backward-reading.
     C*
     C* Handle EOF condition from LF: Reposition positioning aid. After EOF
     C*  (or BOF) we MUST reposition the DB pointer according to IBM docs.
     C     *IN34         IFEQ      *ON
     C     *HIVAL        SETGT     BCKPOS
     C                   MOVEA     '10'          *IN(34)
     C                   ENDIF
     C*
     C* Now, skip the appropriate number of records backwards blindly. If BOF
     C*  occurs, just start from scratch to have a sane beginning.
     C     1             DO        READPVAL
     C                   READP     BCKPOS                                 35
     C     *IN35         IFEQ      *ON
     C                   EXSR      GOFIRST
     C                   LEAVESR
     C                   ENDIF
     C                   ENDDO
     C*
     C* Try to find out if another READP will hit BOF or not. This updates the
     C* appropriate indicator for the SFL-Show-Beginning-String.
     C                   READP     BCKPOS                                 35
     C     *IN35         IFEQ      *ON
     C                   EXSR      GOFIRST
     C                   LEAVESR
     C                   ELSE
     C                   READ      BCKPOS
     C* And refill the SFL starting with the current LF pointer position.
     C                   EXSR      LOADDSPSFL
     C                   ENDIF
     C*
     C                   ENDSR
     C*========================================================================
     C* Some useful general Subroutines
     C*========================================================================
     C     *INZSR        BEGSR
     C* Stuff to do before the main routine starts.
     C*
     C* Force Cursor into search field.
     C                   MOVE      *ON           *IN41
     C*
     C* Load Subfile.
     C                   EXSR      GOFIRST
     C*
     C                   ENDSR
     C*************************************************************************
     C* vim: syntax=rpgle colorcolumn=81 autoindent noignorecase
