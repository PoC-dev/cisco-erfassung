     /*
      * This file is part of cisco-erfassung, an application conglomerate for
      *  management of Cisco devices on AS/400, i5/OS and IBM i.
      *
      * This is free software; you can redistribute it and/or modify it
      *  under the terms of the GNU General Public License as published by the
      *  Free Software Foundation; either version 2 of the License, or (at your
      *  option) any later version.
      *
      * It is distributed in the hope that it will be useful, but WITHOUT
      *  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
      *  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
      *  for more details.
      *
      * You should have received a copy of the GNU General Public License along
      *  with it; if not, write to the Free Software Foundation, Inc., 59
      *  Temple Place, Suite 330, Boston, MA 02111-1307 USA or get it at
      *  http://www.gnu.org/licenses/gpl.html
      */
             PGM        PARM(&EXTPGM)
             DCL        VAR(&EXTPGM) TYPE(*CHAR) LEN(10)
             CALL       PGM(&EXTPGM)
             SNDPGMMSG  MSGID(CPF9898) MSGF(QCPFMSG) +
                          MSGDTA('Druckausgabe an Standarddrucker +
                          gesendet') TOPGMQ(*PRV)
             ENDPGM
             /* vim: syntax=clp colorcolumn=81 autoindent noignorecase
              */
