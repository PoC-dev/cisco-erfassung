     HCOPYRIGHT('Patrik Schindler <poc@pocnet.net>, 2024-07-27')
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
     HDFTACTGRP(*NO) ACTGRP(*NEW) ALWNULL(*USRCTL)
     H*
     H* Tweak default compiler output: Don't be too verbose.
     HOPTION(*NOXREF : *NOSECLVL : *NOSHOWCPY : *NOEXT : *NOSHOWSKP)
     H*
     H* When going prod, enable this for more speed.
     HOPTIMIZE(*FULL)
     H*
     H**************************************************************************
     H* List of INxx, we use:
     H*- Keys:
     H* 01..24: Command Attn Keys (DSPF)
     H*     29: Valid Command Key pressed. (DSPF)
     H*- SFL Handling:
     H*     31: SFLDSP (Orphans)
     H*     32: SFLDSPCTL (Orphans)
     H*     33: SFLCLR (Orphans)
     H*     34: SFLEND (Orphans), EOF from Database file for SFL.
     H*     41: SFLDSP (Missing)
     H*     42: SFLDSPCTL (Missing)
     H*     43: SFLCLR (Missing)
     H*     44: SFLEND (Missing), EOF from Database file for SFL.
     H*- Other Stuff:
     H*     71: READC from Subfile EOF.
     H*     81: Orphans should be handled.
     H*     82: Missings should be handled.
     H*     83: Reload once after handling deletes/adds.
     H*- Error Conditions:
     H*     91: Record was not found (deleted?). (ERR0012)
     H*     92: Tried to insert duplicate record. (ERR1021)
     H*     93: Locked record is not available for change/deletion. (ERR1218)
     H*     98: Generic File Error Flag, always set when FSTAT > 0.
     H*     99: Set Reverse Video for SFL OPT entry.
     H*
     H***************************************************************************
     F* File descriptors. Unfortunately, we're bound to handle files by file
     F*  name or record name. We can't use variables to make this more dynamic.
     F* Restriction of RPG.
     F*
     F* Main/primary file, used mainly for writing into.
     FOSMATCHWLFUF A E           K DISK
     F*
     F* For quick find of maximum ID.
     FOSMATCHMAXIF   E           K DISK    USROPN
     F*
     F* Select/Omit LFs for our list view.
     FOSMRPTMLF IF   E           K DISK
     FOSMRPTOLF IF   E           K DISK
     F*
     F* Display File.
     FOSMRPTDF  CF   E             WORKSTN
     F                                     SFILE(ORPHSFL:ORPHRCDNBR)
     F                                     SFILE(MISSSFL:MISSRCDNBR)
     F                                     SFILE(ORPHDLTSFL:SFLDLTNBR)
     F                                     SFILE(MISSADDSFL:SFLADDNBR)
     F***************************************************************************
     D* Global Variables (additional to autocreated ones by referenced files).
     D*
     D* String for getting current date into.
     DSTAMP            S               Z
     D*
     D* Save point for SFL Indicators, to not interfere with deletion logic.
     DSAVIND           S              1A   DIM(9) INZ('0')
     D*
     D* File Error status variable to track READ/WRITE/UPDATE/DELETE.
     DFSTAT            S              5S 0
     D*
     D* Intermediate save point for elimitating duplicates ending up in the SFL.
     DFLASH_PRV        S                   LIKE(FLASH_IST) INZ
     DMODEL_PRV        S                   LIKE(MODEL_IST) INZ
     DRAM_PRV          S                   LIKE(RAM_IST) INZ
     DVERS_PRV         S                   LIKE(VERS_IST) INZ
     D*
     D***************************************************************************
     C* Start the main loop: Write SFLCTL and wait for keypress to read.
     C* This will be handled after *INZSR was implicitly called by RPG.
     C*
     C* We need to handle No-Data-Display in here, because we share one display
     C*  with two subfiles.
     C*
     C     *ZERO         DOWEQ     *ZERO
     C                   WRITE     HEADING
     C*
     C     *IN31         IFEQ      *OFF
     C                   WRITE     ORPHND
     C                   ENDIF
     C                   WRITE     ORPHCTL
     C*
     C     *IN41         IFEQ      *OFF
     C                   WRITE     MISSND
     C                   ENDIF
     C                   WRITE     MISSCTL
     C*
     C                   WRITE     SCRBTM
     C                   READ      OSMRPTDF
     C*
     C* Jump out immediately if user pressed F3. We need this additionally
     C*  to the DOUEQ-Loop to prevent another loop-cycle and thus late exit.
     C     *IN03         IFEQ      *ON
     C     *IN12         OREQ      *ON
     C                   MOVE      *OFF          *IN03
     C                   MOVE      *OFF          *IN12
     C                   RETURN
     C                   ENDIF
     C*
     C* Reset global SFL Error State from last loop iteration.
     C                   MOVE      *OFF          *IN99
     C*
     C*------------------------------------------------------------------------
     C* Handle Returned F-Keys. These are usually defined as CA in the DSPF and
     C*  return no data to handle. IN29 indicates any valid key has been
     C*  pressed. Watching IN29 here might save a few CPU cycles.
     C     *IN29         IFEQ      *ON
     C                   SELECT
     C*
     C*------------------------------------------------------------------------
     C* Handle SFL Reload with data from database.
     C     *IN05         WHENEQ    *ON
     C*
     C                   EXSR      LOADDSPSFL
     C*
     C*-------------------------------------------------------------------------
     C                   ENDSL
     C                   ITER
     C* If no F-Keys were pressed, handle OPT choices.
     C                   ELSE
     C*----------------------------
     C* Only read if there's actual content in the SFL.
     C     *IN31         IFEQ      *ON
     C* Loop and read changed records from the SFL. This implicitly affects the
     C*  SFL RRN variable!
     C     *ZERO         DOWEQ     *ZERO
     C                   READC     ORPHSFL                                71
     C     *IN71         IFEQ      *ON
     C* If there was an error one loop-iteration before, leave loop immediately.
     C* Aka, locked record or the like; so the user can see where we stopped.
     C     *IN99         OREQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Better use SELECT/WHENxx than CASExx: There's no "OTHER" with CASExx
     C*  but we need to ignore a blank/invalid selection with a new loop
     C*  iteration to prevent UPDATEing RRN 1 with the last READ/WRITE-Cycle
     C*  from LOADDSPSFL.
     C                   SELECT
     C     OPT           WHENEQ    '4'
     C                   EXSR      DLTPREP
     C*
     C     OPT           WHENEQ    ' '
     C* Reset Error State for that one entry. Remember, we're still in READC.
     C                   MOVE      *OFF          *IN99
     C*
     C                   OTHER
     C                   ITER
     C                   ENDSL
     C*
     C* *BLANK out OPT to show to the user we're finished with that one. Keep
     C*  entry active if error occured within a EXSR call.
     C     *IN99         IFEQ      *ON
     C                   MOVE      *BLANK        OPT
     C                   ENDIF
     C*
     C* Finally, update the record in the SFL.
     C                   UPDATE    ORPHSFL
     C*
     C* User may interrupt current READC-loop.
     C     *IN12         IFEQ      *ON
     C                   MOVE      *OFF          *IN12
     C                   LEAVE
     C                   ENDIF
     C*
     C* End of readc-loop!
     C                   ENDDO
     C                   ENDIF
     C*
     C                   MOVE      *ZERO         ID
     C*----------------------------
     C* Only read if there's actual content in the SFL.
     C     *IN41         IFEQ      *ON
     C* Loop and read changed records from the SFL. This implicitly affects the
     C*  SFL RRN variable!
     C     *ZERO         DOWEQ     *ZERO
     C                   READC     MISSSFL                                71
     C     *IN71         IFEQ      *ON
     C* If there was an error one loop-iteration before, leave loop immediately.
     C* Aka, locked record or the like; so the user can see where we stopped.
     C     *IN99         OREQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Better use SELECT/WHENxx than CASExx: There's no "OTHER" with CASExx
     C*  but we need to ignore a blank/invalid selection with a new loop
     C*  iteration to prevent UPDATEing RRN 1 with the last READ/WRITE-Cycle
     C*  from LOADDSPSFL.
     C                   SELECT
     C     OPT           WHENEQ    '1'
     C     OPT           OREQ      '2'
     C                   EXSR      ADDPREP
     C*
     C     OPT           WHENEQ    ' '
     C* Reset Error State for that one entry. Remember, we're still in READC.
     C                   MOVE      *OFF          *IN99
     C*
     C                   OTHER
     C                   ITER
     C                   ENDSL
     C*
     C* *BLANK out OPT to show to the user we're finished with that one. Keep
     C*  entry active if error occured within a EXSR call.
     C     *IN99         IFEQ      *ON
     C                   MOVE      *BLANK        OPT
     C                   ENDIF
     C*
     C* Finally, update the record in the SFL.
     C                   UPDATE    MISSSFL
     C*
     C* User may interrupt current READC-loop.
     C     *IN12         IFEQ      *ON
     C                   MOVE      *OFF          *IN12
     C                   LEAVE
     C                   ENDIF
     C*
     C* End of readc-loop!
     C                   ENDDO
     C                   ENDIF
     C*
     C* End of OPT-Handling (IN29 = OFF). Yes, this far down, because we have
     C*  a common handler for FKeys.
     C                   ENDIF
     C*
     C                   MOVE      *ZERO         ID
     C*-------------------------------------------------------------------------
     C* FIXME: IN12-Handler correct?
     C* If we have records to delete, do now.
     C     *IN81         IFEQ      *ON
     C*
     C* Save current SFL *INs so we can freely set ours for deletion.
     C                   MOVEA     *IN(31)       SAVIND(1)
     C* Since we have previously collected all records to delete,
     C*  set *IN34 for SFLEND.
     C                   MOVE      *ON           *IN34
     C                   EXSR      DODLTSFL
     C* If user exited with *IN12 before, just unset and redisplay.
     C     *IN12         IFEQ      *ON
     C                   MOVE      *OFF          *IN12
     C* Restore previous SFL *INs. They got deleted by clearing DLTSFL.
     C                   MOVEA     SAVIND(1)     *IN(31)
     C                   ENDIF
     C*
     C* After deletion, completely reload.
     C                   MOVE      *ON           *IN83
     C*
     C                   ENDIF
     C*----------------------------
     C* If we have records to add, do now.
     C     *IN82         IFEQ      *ON
     C*
     C* Save current SFL *INs so we can freely set ours for deletion.
     C                   MOVEA     *IN(41)       SAVIND(1)
     C* Since we have previously collected all records to delete,
     C*  set *IN44 for SFLEND.
     C                   MOVE      *ON           *IN44
     C                   EXSR      DOADDSFL
     C* If user exited with *IN12 before, just unset and redisplay.
     C     *IN12         IFEQ      *ON
     C                   MOVE      *OFF          *IN12
     C* Restore previous SFL *INs. They got deleted by clearing DLTSFL.
     C                   MOVEA     SAVIND(1)     *IN(41)
     C                   ENDIF
     C*
     C* After addition, completely reload.
     C                   MOVE      *ON           *IN83
     C*
     C                   ENDIF
     C*----------------------------
     C* After addition/deletion, completely reload.
     C     *IN83         IFEQ      *ON
     C                   MOVE      *OFF          *IN83
     C                   EXSR      LOADDSPSFL
     C                   ENDIF
     C*
     C*-------------------------------------------------------------------------
     C* End of main loop.
     C                   ENDDO
     C*
     C                   RETURN
     C**************************************************************************
     C* Some useful Subroutines
     C**************************************************************************
     C     *INZSR        BEGSR
     C* Stuff to do before the main routine starts...
     C*
     C* Start by loading data into the sfl and afterwards displaying it.
     C* Since we let OS/400 do all the clumsy key handling, there's not
     C* much to do besides loading data and jump to the first record.
     C                   EXSR      LOADDSPSFL
     C*
     C                   ENDSR
     C**************************************************************************
     C     INCLASTID     BEGSR
     C* Last-ID-Handler.
     C                   OPEN      OSMATCHMAX
     C     *HIVAL        SETGT     MAXID
     C                   READP     MAXID
     C                   ADD       1             ID
     C                   CLOSE     OSMATCHMAX
     C*
     C                   ENDSR
     C**************************************************************************
     C* SFL subroutines
     C**************************************************************************
     C     LOADDSPSFL    BEGSR
     C* Read over all records provided by LFs, and write them into the SFL.
     C*  Increment SFLRCDNBR which determines the line of the SFL where the
     C*  record is to be be inserted. Stop when SFL is full or EOF happens.
     C*
     C*-------------------------------------------------------------------------
     C* Reset SFL state to default.
     C                   MOVEA     '0110'        *IN(31)
     C                   MOVE      *ZEROS        ORPHRCDNBR
     C                   WRITE     ORPHCTL
     C                   MOVE      *OFF          *IN33
     C*
     C* Rewind file pointer.
     C     *LOVAL        SETLL     ORPHANS
     C*
     C* Read loop start.
     C     *ZERO         DOWEQ     *ZERO
     C*
     C                   READ      ORPHANS                                34
     C     *IN34         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Reset opt to blank.
     C                   MOVE      *BLANK        OPT
     C*
     C* Write ready-made records into the SFL.
     C                   ADD       1             ORPHRCDNBR
     C*
     C* Make sure we know if the SFL is full.
     C     ORPHRCDNBR    IFGE      999
     C                   MOVE      *ON           *IN96
     C                   LEAVE
     C                   ENDIF
     C*
     C                   WRITE     ORPHSFL
     C                   ENDDO
     C*
     C* Loop ended. Display the subfile- and subfile control records or
     C*  indicate an empty SFL by (not) setting IN31.
     C     ORPHRCDNBR    IFGT      *ZERO
     C                   MOVE      *ON           *IN31
     C                   Z-ADD     1             ORPHRCDNBR
     C                   ELSE
     C* If SFL is empty, don't try to show: We'll crash! Instead show excuse.
     C                   MOVE      *OFF          *IN31
     C                   ENDIF
     C*
     C*-------------------------------------------------------------------------
     C*
     C* Reset SFL state to default.
     C                   MOVEA     '0110'        *IN(41)
     C                   MOVE      *ZEROS        MISSRCDNBR
     C                   WRITE     MISSCTL
     C                   MOVE      *OFF          *IN43
     C*
     C* Rewind file pointer.
     C     *LOVAL        SETLL     MISSING
     C*
     C* Read loop start.
     C     *ZERO         DOWEQ     *ZERO
     C*
     C                   READ      MISSING                                44
     C     *IN44         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Skip records with duplicate field values.
     C     FLASH_IST     IFEQ      FLASH_PRV
     C     MODEL_IST     ANDEQ     MODEL_PRV
     C     RAM_IST       ANDEQ     RAM_PRV
     C     VERS_IST      ANDEQ     VERS_PRV
     C                   ITER
     C                   ENDIF
     C*
     C* Reset opt to blank.
     C                   MOVE      *BLANK        OPT
     C*
     C* Write ready-made records into the SFL.
     C                   ADD       1             MISSRCDNBR
     C                   MOVE      *ZERO         ID
     C*
     C* Make sure we know if the SFL is full.
     C     MISSRCDNBR    IFGE      999
     C                   MOVE      *ON           *IN96
     C                   LEAVE
     C                   ENDIF
     C*
     C                   WRITE     MISSSFL
     C*
     C* Copy data for next run.
     C                   MOVE      FLASH_IST     FLASH_PRV
     C                   MOVE      MODEL_IST     MODEL_PRV
     C                   MOVE      RAM_IST       RAM_PRV
     C                   MOVE      VERS_IST      VERS_PRV
     C*
     C                   ENDDO
     C*
     C* Loop ended. Display the subfile- and subfile control records or
     C*  indicate an empty SFL by (not) setting IN41.
     C     MISSRCDNBR    IFGT      *ZERO
     C                   MOVE      *ON           *IN41
     C                   Z-ADD     1             MISSRCDNBR
     C                   ELSE
     C* If SFL is empty, don't try to show: We'll crash! Instead show excuse.
     C                   MOVE      *OFF          *IN41
     C                   ENDIF
     C*
     C                   ENDSR
     C*************************************************************************
     C*************************************************************************
     C     DLTPREP       BEGSR
     C* For every record selected (OPT 4, see above) copy entry into the
     C*  secondary subfile screen (not yet shown) and blindly set flag IN81.
     C* This implicitly requires displayed fields in DLTSFL not being a
     C*  superset of fields in regular SFL!
     C                   MOVE      OPT           DOPT
     C                   ADD       1             SFLDLTNBR
     C                   WRITE     ORPHDLTSFL
     C                   MOVE      *ON           *IN81
     C*
     C                   ENDSR
     C*************************************************************************
     C     CLEARDLTSFL   BEGSR
     C* Reset stuff to before the first load.
     C                   MOVEA     '0110'        *IN(31)
     C                   MOVE      *ZERO         SFLDLTNBR
     C                   WRITE     ORPHDLTCTL
     C                   MOVE      *OFF          *IN33
     C                   MOVE      *OFF          *IN81
     C*
     C                   ENDSR
     C*************************************************************************
     C     DODLTSFL      BEGSR
     C* Show may-i-delete-SFL and wait for keypress. Handle deletions if still
     C*  selected with '4'. Note: The SFL has SFLNXTCHG set on permanently to
     C*  enable reading the whole SFL, even without user changes.
     C                   MOVE      *OFF          *IN81
     C*
     C* Prevent Crashing with empty SFL. Should not happen, but who knows.
     C     SFLDLTNBR     IFGT      *ZERO
     C                   MOVE      *ON           *IN31
     C                   ELSE
     C                   MOVE      *OFF          *IN31
     C                   WRITE     ORPHND
     C                   ENDIF
     C*
     C* Finally show all the data on the display, beginning line 1.
     C                   MOVE      1             SFLDLTNBR
     C*
     C     DLTREENTRY    TAG
     C                   WRITE     SCRPROMBTM
     C                   EXFMT     ORPHDLTCTL
     C*
     C     *IN12         IFEQ      *ON
     C                   EXSR      CLEARDLTSFL
     C                   LEAVESR
     C                   ENDIF
     C*
     C* READC loop start.
     C     *ZERO         DOWEQ     *ZERO
     C                   READC     ORPHDLTSFL                             71
     C     *IN71         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Delete only if record is preselected with '4'. Note, we need the field
     C*  designation in DDS to be both Input/Output for this to work!
     C     DOPT          IFEQ      '4'
     C*
     C* Delete if record found. If not, silently ignore. Has probably been
     C*  deleted from someone else, meanwhile.
     C     ID            DELETE(E) WRITEMATCH
     C                   EVAL      FSTAT=%STATUS(OSMATCHWLF)
     C*
     C     FSTAT         IFGT      *ZERO
     C                   MOVE      *ON           *IN98
     C                   SELECT
     C     FSTAT         WHENEQ    12
     C* Record-not-found. Perhaps someone deleted meanwhile?
     C                   MOVE      *ON           *IN91
     C     FSTAT         WHENEQ    1218
     C* Desired record is locked. Can't continue here, so show error with *IN93
     C*  and redisplay.
     C                   MOVE      *ON           *IN93
     C                   ENDSL
     C*
     C                   MOVE      *ON           *IN99
     C                   GOTO      DLTREENTRY
     C*
     C                   ENDIF
     C* At this point, we most likely successfully deleted a record.
     C                   MOVE      *BLANK        DOPT
     C                   MOVE      *OFF          *IN98
     C                   ENDIF
     C                   ENDDO
     C*
     C* Clear SFL for next run.
     C                   EXSR      CLEARDLTSFL
     C*
     C                   ENDSR
     C*************************************************************************
     C*************************************************************************
     C     ADDPREP       BEGSR
     C* For every record selected (OPT 1, see above) copy entry into the
     C*  secondary subfile screen (not yet shown) and blindly set flag IN82.
     C* This implicitly requires displayed fields in DLTSFL not being a
     C*  superset of fields in regular SFL!
     C                   MOVE      OPT           AOPT
     C                   ADD       1             SFLADDNBR
     C                   WRITE     MISSADDSFL
     C                   MOVE      *ON           *IN82
     C*
     C                   ENDSR
     C*************************************************************************
     C     CLEARADDSFL   BEGSR
     C* Reset stuff to before the first load.
     C                   MOVEA     '0110'        *IN(41)
     C                   MOVE      *ZERO         SFLADDNBR
     C                   WRITE     MISSADDCTL
     C                   MOVE      *OFF          *IN43
     C                   MOVE      *OFF          *IN82
     C*
     C                   ENDSR
     C*************************************************************************
     C     DOADDSFL      BEGSR
     C* Show may-i-add-SFL and wait for keypress. Handle additions if still
     C*  selected with '1'. Note: The SFL has SFLNXTCHG set on permanently to
     C*  enable reading the whole SFL, even without user changes.
     C                   MOVE      *OFF          *IN82
     C*
     C* Prevent Crashing with empty SFL. Should not happen, but who knows.
     C     SFLADDNBR     IFGT      *ZERO
     C                   MOVE      *ON           *IN41
     C                   ELSE
     C                   MOVE      *OFF          *IN41
     C                   WRITE     MISSND
     C                   ENDIF
     C*
     C* Finally show all the data on the display, beginning line 1.
     C                   MOVE      1             SFLADDNBR
     C*
     C     ADDREENTRY    TAG
     C                   WRITE     SCRPROMBTM
     C                   EXFMT     MISSADDCTL
     C*
     C     *IN12         IFEQ      *ON
     C                   EXSR      CLEARADDSFL
     C                   LEAVESR
     C                   ENDIF
     C*
     C* READC loop start.
     C     *ZERO         DOWEQ     *ZERO
     C                   READC     MISSADDSFL                             71
     C     *IN71         IFEQ      *ON
     C                   LEAVE
     C                   ENDIF
     C*
     C* Add only if record is preselected with '1'. Note, we need the field
     C*  designation in DDS to be both Input/Output for this to work!
     C     AOPT          IFEQ      '1'
     C     AOPT          OREQ      '2'
     C*
     C* Use '2' for addition with ZUORDNEN as version string.
     C     AOPT          IFEQ      '2'
     C     VERS_IST      OREQ      *BLANK
     C                   MOVEL     *BLANK        VERSION
     C                   MOVEL     'ZUORDNEN'    VERSION
     C                   ELSE
     C                   MOVE      VERS_IST      VERSION
     C                   ENDIF
     C*
     C* Fill all other fields (or set to NULL, if needed).
     C                   MOVE      MODEL_IST     MODEL
     C                   MOVE      RAM_IST       RAM
     C                   MOVE      FLASH_IST     FLASH
     C                   EVAL      %NULLIND(EOS) = *ON
     C*
     C* Generate new ID for record.
     C                   EXSR      INCLASTID
     C*
     C* Prepare time stamp for addition. See DCAPG.
     C                   TIME                    STAMP
     C                   MOVEL     STAMP         CHANGED
     C*
     C* Write record.
     C                   WRITE(E)  WRITEMATCH
     C                   EVAL      FSTAT=%STATUS(OSMATCHWLF)
     C*
     C     FSTAT         IFGT      *ZERO
     C                   MOVE      *ON           *IN98
     C                   SELECT
     C     FSTAT         WHENEQ    1021
     C* Tried to insert dup.
     C                   MOVE      *ON           *IN92
     C                   ENDSL
     C*
     C                   MOVE      *ON           *IN99
     C                   GOTO      ADDREENTRY
     C*
     C                   ENDIF
     C* At this point, we most likely successfully inserted a record.
     C                   MOVE      *BLANK        AOPT
     C                   MOVE      *OFF          *IN98
     C                   ENDIF
     C                   ENDDO
     C*
     C* Clear SFL for next run.
     C                   EXSR      CLEARADDSFL
     C*
     C                   ENDSR
     C**************************************************************************
     C* vim: syntax=rpgle colorcolumn=81 autoindent noignorecase
