unit uXmlModel;

{$mode delphi}{$H+}

interface

uses Classes, SysUtils, DOM;

type
  TXmlEncodingInfo = record
    Name: UnicodeString;
    HasBom: Boolean;
    SourceText: UnicodeString;
  end;

function LoadXmlFile(const FileName: UnicodeString; MaxSize: Int64;
  out Doc: TXMLDocument; out Encoding: TXmlEncodingInfo): Boolean;
function LoadXmlSourceText(const FileName: UnicodeString; MaxSize: Int64;
  out SourceText: UnicodeString): Boolean;
function SaveXmlFile(const FileName: UnicodeString; Doc: TXMLDocument;
  const Encoding: TXmlEncodingInfo): Boolean;
function SaveXmlSourceAtomic(const FileName, SourceText: UnicodeString;
  const Encoding: TXmlEncodingInfo): Boolean;
function XmlNodeCaption(Node: TDOMNode): UnicodeString;
function XmlNodeValue(Node: TDOMNode): UnicodeString;
function XmlNodePath(Node: TDOMNode): UnicodeString;
function XmlNodeText(Node: TDOMNode): UnicodeString;

implementation

uses Windows, XMLRead, XMLWrite;

const
  XML_REPLACEFILE_WRITE_THROUGH = $00000001;
  XML_MOVEFILE_REPLACE_EXISTING = $00000001;
  XML_MOVEFILE_WRITE_THROUGH = $00000008;

function ReplaceFileW(lpReplacedFileName, lpReplacementFileName,
  lpBackupFileName: PWideChar; dwReplaceFlags: DWORD;
  lpExclude, lpReserved: Pointer): BOOL; stdcall; external 'kernel32.dll';

function SourceToBytes(const SourceText: UnicodeString;
  const Encoding: TXmlEncodingInfo; out B: TBytes): Boolean;
var
  U: UTF8String;
  Count, I, Start: Integer;
  UsedDefault: BOOL;
begin
  Result := False;
  SetLength(B, 0);
  if Encoding.Name = 'UTF-8' then
  begin
    U := UTF8Encode(SourceText);
    Start := Ord(Encoding.HasBom) * 3;
    SetLength(B, Start + Length(U));
    if Encoding.HasBom then begin B[0] := $EF; B[1] := $BB; B[2] := $BF; end;
    if Length(U) > 0 then Move(PAnsiChar(U)^, B[Start], Length(U));
    Exit(True);
  end;
  if (Encoding.Name = 'UTF-16LE') or (Encoding.Name = 'UTF-16BE') then
  begin
    Start := Ord(Encoding.HasBom) * 2;
    SetLength(B, Start + Length(SourceText) * 2);
    if Encoding.HasBom then
      if Encoding.Name = 'UTF-16LE' then begin B[0] := $FF; B[1] := $FE; end
      else begin B[0] := $FE; B[1] := $FF; end;
    for I := 1 to Length(SourceText) do
      if Encoding.Name = 'UTF-16LE' then
      begin
        B[Start + (I - 1) * 2] := Ord(SourceText[I]) and $FF;
        B[Start + (I - 1) * 2 + 1] := Ord(SourceText[I]) shr 8;
      end
      else
      begin
        B[Start + (I - 1) * 2] := Ord(SourceText[I]) shr 8;
        B[Start + (I - 1) * 2 + 1] := Ord(SourceText[I]) and $FF;
      end;
    Exit(True);
  end;
  UsedDefault := False;
  Count := WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS,
    PWideChar(SourceText), Length(SourceText), nil, 0, nil, @UsedDefault);
  if (Count < 0) or UsedDefault then Exit;
  SetLength(B, Count);
  UsedDefault := False;
  if Count > 0 then
    WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, PWideChar(SourceText),
      Length(SourceText), PAnsiChar(@B[0]), Count, nil, @UsedDefault);
  Result := not UsedDefault;
end;

function NormalizeXmlDeclaration(const S: UTF8String): UTF8String;
var
  P, Q, E: Integer;
  Quote: AnsiChar;
begin
  Result := S;
  P := Pos('<?xml', LowerCase(Copy(S, 1, 256)));
  if P = 0 then Exit;
  E := Pos('?>', Copy(S, P, 256));
  if E = 0 then Exit;
  Q := Pos('encoding', LowerCase(Copy(S, P, E)));
  if Q = 0 then Exit;
  Q := P + Q - 1;
  while (Q <= Length(Result)) and (Result[Q] <> '=') do Inc(Q);
  if Q > Length(Result) then Exit;
  Inc(Q);
  while (Q <= Length(Result)) and (Result[Q] in [' ', #9]) do Inc(Q);
  if (Q > Length(Result)) or not (Result[Q] in ['"', '''']) then Exit;
  Quote := Result[Q];
  E := Q + 1;
  while (E <= Length(Result)) and (Result[E] <> Quote) do Inc(E);
  if E > Length(Result) then Exit;
  Result := Copy(Result, 1, Q) + 'UTF-8' + Copy(Result, E, MaxInt);
end;

function IsValidUtf8(const B: TBytes): Boolean;
var
  I, N, J: Integer;
begin
  I := 0;
  while I < Length(B) do
  begin
    if B[I] < $80 then N := 0
    else if (B[I] and $E0) = $C0 then N := 1
    else if (B[I] and $F0) = $E0 then N := 2
    else if (B[I] and $F8) = $F0 then N := 3
    else Exit(False);
    if I + N >= Length(B) then Exit(False);
    for J := 1 to N do if (B[I + J] and $C0) <> $80 then Exit(False);
    Inc(I, N + 1);
  end;
  Result := True;
end;

function BytesToUtf8(const B: TBytes; out Enc: TXmlEncodingInfo): UTF8String;
var
  I, Start: Integer;
  W: UnicodeString;
  A: AnsiString;
begin
  Enc.HasBom := False;
  Start := 0;
  if (Length(B) >= 3) and (B[0] = $EF) and (B[1] = $BB) and (B[2] = $BF) then
  begin Enc.Name := 'UTF-8'; Enc.HasBom := True; Start := 3; end
  else if (Length(B) >= 2) and (B[0] = $FF) and (B[1] = $FE) then
  begin Enc.Name := 'UTF-16LE'; Enc.HasBom := True; Start := 2; end
  else if (Length(B) >= 2) and (B[0] = $FE) and (B[1] = $FF) then
  begin Enc.Name := 'UTF-16BE'; Enc.HasBom := True; Start := 2; end
  else if (Length(B) >= 2) and (B[0] = 0) and (B[1] = Ord('<')) then Enc.Name := 'UTF-16BE'
  else if (Length(B) >= 2) and (B[1] = 0) and (B[0] = Ord('<')) then Enc.Name := 'UTF-16LE'
  else if IsValidUtf8(B) then Enc.Name := 'UTF-8'
  else Enc.Name := 'ANSI';
  if (Enc.Name = 'UTF-16LE') or (Enc.Name = 'UTF-16BE') then
  begin
    SetLength(W, (Length(B) - Start) div 2);
    for I := 1 to Length(W) do
      if Enc.Name = 'UTF-16LE' then
        W[I] := WideChar(B[Start + (I - 1) * 2] or (B[Start + (I - 1) * 2 + 1] shl 8))
      else
        W[I] := WideChar((B[Start + (I - 1) * 2] shl 8) or B[Start + (I - 1) * 2 + 1]);
    Exit(UTF8Encode(W));
  end;
  if Enc.Name = 'ANSI' then
  begin
    if Length(B) = 0 then Exit('');
    SetString(A, PAnsiChar(@B[0]), Length(B));
    SetLength(W, MultiByteToWideChar(CP_ACP, 0, PAnsiChar(A), Length(A), nil, 0));
    if Length(W) > 0 then
      MultiByteToWideChar(CP_ACP, 0, PAnsiChar(A), Length(A), PWideChar(W), Length(W));
    Exit(UTF8Encode(W));
  end;
  if Length(B) > Start then SetString(Result, PAnsiChar(@B[Start]), Length(B) - Start)
  else Result := '';
end;

function LoadXmlFile(const FileName: UnicodeString; MaxSize: Int64;
  out Doc: TXMLDocument; out Encoding: TXmlEncodingInfo): Boolean;
var
  F: TFileStream;
  B: TBytes;
  S: UTF8String;
  M: TMemoryStream;
begin
  Result := False;
  Doc := nil;
  try
    F := TFileStream.Create(UTF8Encode(FileName), fmOpenRead or fmShareDenyNone);
    try
      if (MaxSize > 0) and (F.Size > MaxSize) then Exit;
      SetLength(B, F.Size);
      if F.Size > 0 then F.ReadBuffer(B[0], F.Size);
    finally F.Free; end;
    S := BytesToUtf8(B, Encoding);
    Encoding.SourceText := UTF8Decode(S);
    S := NormalizeXmlDeclaration(S);
    M := TMemoryStream.Create;
    if Length(S) > 0 then M.WriteBuffer(PAnsiChar(S)^, Length(S));
    M.Position := 0;
    try ReadXMLFile(Doc, M); finally M.Free; end;
    Result := Assigned(Doc);
  except
    FreeAndNil(Doc);
  end;
end;

function LoadXmlSourceText(const FileName: UnicodeString; MaxSize: Int64;
  out SourceText: UnicodeString): Boolean;
var
  F: TFileStream;
  B: TBytes;
  Encoding: TXmlEncodingInfo;
begin
  Result := False;
  SourceText := '';
  try
    F := TFileStream.Create(UTF8Encode(FileName), fmOpenRead or fmShareDenyNone);
    try
      if (MaxSize > 0) and (F.Size > MaxSize) then Exit;
      SetLength(B, F.Size);
      if F.Size > 0 then F.ReadBuffer(B[0], F.Size);
    finally
      F.Free;
    end;
    SourceText := UTF8Decode(BytesToUtf8(B, Encoding));
    Result := True;
  except
    SourceText := '';
  end;
end;

function SaveXmlFile(const FileName: UnicodeString; Doc: TXMLDocument;
  const Encoding: TXmlEncodingInfo): Boolean;
var
  M: TStringStream;
  F: TFileStream;
begin
  Result := False;
  if not Assigned(Doc) then Exit;
  try
    M := TStringStream.Create('');
    try
      WriteXMLFile(Doc, M);
      F := TFileStream.Create(UTF8Encode(FileName), fmCreate);
      try M.Position := 0; F.CopyFrom(M, M.Size); finally F.Free; end;
    finally M.Free; end;
    Result := True;
  except
    Result := False;
  end;
end;

function SaveXmlSourceAtomic(const FileName, SourceText: UnicodeString;
  const Encoding: TXmlEncodingInfo): Boolean;
var
  B: TBytes;
  Dir, TempName: UnicodeString;
  TempBuf: array[0..MAX_PATH] of WideChar;
  H: THandle;
  Written: DWORD;
  CheckDoc: TXMLDocument;
  CheckEncoding: TXmlEncodingInfo;
begin
  Result := False;
  CheckDoc := nil;
  if not SourceToBytes(SourceText, Encoding, B) then Exit;
  Dir := ExtractFilePath(FileName);
  if Dir = '' then Dir := GetCurrentDir;
  if GetTempFileNameW(PWideChar(Dir), 'xlt', 0, @TempBuf[0]) = 0 then Exit;
  TempName := TempBuf;
  try
    H := CreateFileW(PWideChar(TempName), GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if H = INVALID_HANDLE_VALUE then Exit;
    try
      if Length(B) > 0 then
      begin
        Written := 0;
        if not WriteFile(H, B[0], Length(B), Written, nil) or
          (Written <> DWORD(Length(B))) then Exit;
      end;
      if not FlushFileBuffers(H) then Exit;
    finally
      CloseHandle(H);
    end;
    if not LoadXmlFile(TempName, 0, CheckDoc, CheckEncoding) then Exit;
    FreeAndNil(CheckDoc);
    if not ReplaceFileW(PWideChar(FileName), PWideChar(TempName), nil,
      XML_REPLACEFILE_WRITE_THROUGH, nil, nil) then
      if not MoveFileExW(PWideChar(TempName), PWideChar(FileName),
        XML_MOVEFILE_REPLACE_EXISTING or XML_MOVEFILE_WRITE_THROUGH) then Exit;
    TempName := '';
    Result := True;
  finally
    CheckDoc.Free;
    if TempName <> '' then DeleteFileW(PWideChar(TempName));
  end;
end;

function XmlNodeCaption(Node: TDOMNode): UnicodeString;
begin
  if not Assigned(Node) then Exit('');
  case Node.NodeType of
    DOCUMENT_NODE: Result := '#DOCUMENT';
    TEXT_NODE: Result := '#TEXT';
    COMMENT_NODE: Result := '#COMMENT';
    CDATA_SECTION_NODE: Result := '#CDATA';
  else Result := UnicodeString(Node.NodeName);
  end;
end;

function XmlNodeValue(Node: TDOMNode): UnicodeString;
begin
  if not Assigned(Node) then Exit('');
  if Node.NodeType in [TEXT_NODE, COMMENT_NODE, CDATA_SECTION_NODE, ATTRIBUTE_NODE] then
    Result := UnicodeString(Node.NodeValue)
  else Result := UnicodeString(Node.TextContent);
end;

function XmlNodePath(Node: TDOMNode): UnicodeString;
var
  P, N: TDOMNode;
  Index, Count: Integer;
begin
  Result := '';
  while Assigned(Node) and (Node.NodeType <> DOCUMENT_NODE) do
  begin
    if Node.NodeType = ATTRIBUTE_NODE then
    begin
      Result := '/@' + UnicodeString(Node.NodeName) + Result;
      Node := TDOMAttr(Node).OwnerElement;
      Continue;
    end
    else if Node.NodeType = TEXT_NODE then
      Result := '/text()' + Result
    else
    begin
      Index := 1; Count := 0; P := Node.ParentNode;
      if Assigned(P) then
      begin
        N := P.FirstChild;
        while Assigned(N) do
        begin
          if (N.NodeType = Node.NodeType) and (N.NodeName = Node.NodeName) then
          begin Inc(Count); if N = Node then Index := Count; end;
          N := N.NextSibling;
        end;
      end;
      if Count > 1 then Result := '/' + UnicodeString(Node.NodeName) + '[' + IntToStr(Index) + ']' + Result
      else Result := '/' + UnicodeString(Node.NodeName) + Result;
    end;
    Node := Node.ParentNode;
  end;
end;

function XmlNodeText(Node: TDOMNode): UnicodeString;
var
  M: TStringStream;
  D: TXMLDocument;
begin
  Result := '';
  if not Assigned(Node) then Exit;
  M := TStringStream.Create('');
  try
    if Node.NodeType = DOCUMENT_NODE then WriteXMLFile(TXMLDocument(Node), M)
    else
    begin
      D := TXMLDocument.Create;
      try D.AppendChild(D.ImportNode(Node, True)); WriteXMLFile(D, M); finally D.Free; end;
    end;
    Result := UTF8Decode(M.DataString);
  finally M.Free; end;
end;

end.
