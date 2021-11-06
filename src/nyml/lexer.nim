import os, lexbase, streams, json, tables, re
from strutils import Whitespace, `%`, replace, indent

type
    TokenKind* = enum
        TK_NONE
        TK_KEY
        TK_INTEGER
        TK_STRING
        TK_BOOLEAN
        TK_ARRAY
        TK_ARRAY_BLOCK
        TK_OBJECT
        TK_COMMENT
        TK_END_OF_INPUT = "End_of_input",
        TK_INVALID
        TK_SKIPPABLE

    Lexer* = object of BaseLexer
        kind*: TokenKind
        token*, error*: string
        startPos*: int
        whitespaces: int


template setError(l: var Lexer; err: string): untyped =
    l.kind = TK_INVALID
    if l.error.len == 0:
        l.error = err
 
proc hasError[T: Lexer](self: T): bool = self.error.len > 0
 
proc open*[T: Lexer](lex: var T; input: Stream) {.inline.} =
    ## Initialize a new Lexer instance with given Stream
    lexbase.open(lex, input)
    lex.startPos = 0
    lex.kind = TK_INVALID
    lex.token = ""
    lex.error = ""

proc nextToEOL[T: Lexer](lex: var T): tuple[pos: int, token: string] =
    # Get entire buffer starting from given position to the end of line
    while true:
        if lex.buf[lex.bufpos] in NewLines:
            return
        add lex.token, lex.buf[lex.bufpos]
        inc lex.bufpos
    return (pos: lex.bufpos, token: lex.token)

proc handleNewLine[T: Lexer](lex: var T) =
    ## Handle new lines
    case lex.buf[lex.bufpos]
    of '\c': lex.bufpos = lex.handleCR(lex.bufpos)
    of '\n': lex.bufpos = lex.handleLF(lex.bufpos)
    else: discard
 
proc skip[T: Lexer](lex: var T) =
    ## Procedure for skipping/offset between columns/positions 
    var wsno: int
    while true:
        case lex.buf[lex.bufpos]
        of Whitespace:
            if lex.buf[lex.bufpos] notin NewLines:
                inc lex.bufpos
                inc wsno
            else:
                lex.handleNewLine()
        else:
            lex.whitespaces = wsno
            break
 
proc handleSpecial[T: Lexer](lex: var T): char =
    ## Procedure for for handling special escaping tokens
    assert lex.buf[lex.bufpos] == '\\'
    inc lex.bufpos
    case lex.buf[lex.bufpos]
    of 'n':
        lex.token.add "\\n"
        result = '\n'
        inc lex.bufpos
    of '\\':
        lex.token.add "\\\\"
        result = '\\'
        inc lex.bufpos
    else:
        lex.setError("Unknown escape sequence: '\\" & lex.buf[lex.bufpos] & "'")
        result = '\0'
 
proc handleChar[T: Lexer](lex: var T) =
    assert lex.buf[lex.bufpos] == '\''
    lex.startPos = lex.getColNumber(lex.bufpos)
    lex.kind = TK_INVALID
    inc lex.bufpos
    if lex.buf[lex.bufpos] == '\\':
        lex.token = $ord(lex.handleSpecial())
        if lex.hasError(): return
    elif lex.buf[lex.bufpos] == '\'':
        lex.setError("Empty character constant")
        return
    else:
        lex.token = $ord(lex.buf[lex.bufpos])
        inc lex.bufpos
    if lex.buf[lex.bufpos] == '\'':
        lex.kind = TK_INTEGER
        inc lex.bufpos
    else:
        lex.setError("Multi-character constant")
 
proc handleString[T: Lexer](lex: var T) =
    ## Handle string values wrapped in single or double quotes
    lex.startPos = lex.getColNumber(lex.bufpos)
    # lex.token = "\""    # no need to add quotes
    lex.token = ""
    inc lex.bufpos
    while true:
        case lex.buf[lex.bufpos]
        of '\\':
            discard lex.handleSpecial()
            if lex.hasError(): return
        of '"', '\'':
            lex.kind = TK_STRING
            # add lex.token, '"' # no need to close with quotes
            inc lex.bufpos
            break
        of NewLines:
            lex.setError("EOL reached before end of string")
            return
        of EndOfFile:
            lex.setError("EOF reached before end of string")
            return
        else:
            add lex.token, lex.buf[lex.bufpos]
            inc lex.bufpos

proc handleSequence[T: Lexer](lex: var T) =
    lex.startPos = lex.getColNumber(lex.bufpos)
    lex.token = "["
    inc lex.bufpos
    var errorMessage = "$1 reached before closing the array"
    while true:
        case lex.buf[lex.bufpos]
        of '\\':
            discard lex.handleSpecial()
            if lex.hasError(): return
        of ']':
            lex.kind = TK_ARRAY
            add lex.token, ']'
            inc lex.bufpos
            break
        of NewLines:
            lex.setError(errorMessage % ["EOL"])
            return
        of EndOfFile:
            lex.setError(errorMessage % ["EOF"])
            return
        else:
            add lex.token, lex.buf[lex.bufpos]
            inc lex.bufpos

proc handleNumber[T: Lexer](lex: var T) =
    lex.startPos = lex.getColNumber(lex.bufpos)
    lex.token = "0"
    while lex.buf[lex.bufpos] == '0':
        inc lex.bufpos
    while true:
        case lex.buf[lex.bufpos]
        of '0'..'9':
            if lex.token == "0":
                setLen(lex.token, 0)
            add lex.token, lex.buf[lex.bufpos]
            inc lex.bufpos
        of 'a'..'z', 'A'..'Z', '_':
            lex.setError("Invalid number")
            return
        else:
            lex.setTokenMeta(TK_INTEGER)
            break

proc handleIdent[T: Lexer](lex: var T) =
    ## Procedure for handling identations
    # assert lex.buf[lex.bufpos] in {'a'..'z'}
    lex.startPos = lex.getColNumber(lex.bufpos)
    setLen(lex.token, 0)
    while true:
        if lex.buf[lex.bufpos] in {'a'..'z', 'A'..'Z', '0'..'9', '_', ':'}:
            add lex.token, lex.buf[lex.bufpos]
            inc lex.bufpos
        else: break

    if lex.token =~ re"\w+\:":
        lex.token = lex.token.replace(":", "")      # Remove punctuation character
        lex.setTokenMeta(TK_KEY)
    else:
        lex.kind = case lex.token
            of "true", "false", "yes", "no", "y", "n", "True",
               "False", "Yes", "No", "TRUE", "FALSE", "YES", "NO": TK_BOOLEAN
            else: TK_INVALID

proc setTokenMeta*[T: Lexer](lex: var T, tokenKind: TokenKind, offset:int = 0) =
    ## Set meta data for current token
    lex.kind = tokenKind
    lex.startPos = lex.getColNumber(lex.bufpos)
    inc(lex.bufpos, offset)

proc getToken*[T: Lexer](lex: var T): TokenKind =
    ## Parsing through available tokens
    lex.kind = TK_INVALID
    setLen(lex.token, 0)
    skip lex
    case lex.buf[lex.bufpos]
    of '#':
        lex.setTokenMeta(TK_COMMENT, lex.nextToEOL().pos)
    # of '\'': lex.handleChar()
    of '0'..'9': lex.handleNumber()
    of 'a'..'z', 'A'..'Z', ':', '_': lex.handleIdent()
    of '-':
        lex.setTokenMeta(TK_ARRAY_BLOCK, 1)
    of '[':
        lex.handleSequence()
    of '"', '\'': lex.handleString()
    of EndOfFile:
        lex.startPos = lex.getColNumber(lex.bufpos)
        lex.kind = TK_END_OF_INPUT
    else:
        lex.setError("Unrecognized character")
    result = lex.kind

proc tokenizeIt*(yamlContents: string): seq[tuple[kind: TokenKind, value: string, line, indent: int]] =
    var lex: Lexer
    var toknized: seq[tuple[kind: TokenKind, value: string, line, indent: int]]
    lex.open(newStringStream(yamlContents))

    while lex.getToken() notin {TK_INVALID}:
        if lex.kind in {TK_END_OF_INPUT}: break
        # debug
        # let tknized = "$1(value: $2, indent: $3, line: $4)" % [$lex.kind, $lex.token, $lex.whitespaces, $lex.lineNumber]
        toknized.add((kind: lex.kind, value: lex.token, line: lex.lineNumber, indent: lex.whitespaces))
    lex.close()

    # Raise error if any, highlighting the line and col number
    if lex.hasError():
        echo "($1, $2) {lex.error}" % [$lex.lineNumber, $(lex.getColNumber lex.bufpos + 1)]
    else: return toknized
