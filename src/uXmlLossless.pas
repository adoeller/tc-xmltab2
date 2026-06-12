unit uXmlLossless;

{$mode delphi}{$H+}

interface

uses DOM, uXmlSource, uXmlCellEdit;

function PatchCellSource(const Source: UnicodeString; const Nodes: TXmlNodeSpans;
  const Cell: TXmlCellRef; const Value: UnicodeString;
  out Patched: UnicodeString): Boolean;

implementation

uses SysUtils;

function ReplaceAll(const Source, OldValue, NewValue: UnicodeString): UnicodeString;
var
  P, StartPos: Integer;
begin
  Result := '';
  StartPos := 1;
  P := Pos(OldValue, Source);
  while P > 0 do
  begin
    Result := Result + Copy(Source, StartPos, P - StartPos) + NewValue;
    StartPos := P + Length(OldValue);
    P := Pos(OldValue, Source, StartPos);
  end;
  Result := Result + Copy(Source, StartPos, MaxInt);
end;

function ReplaceRange(const Source: UnicodeString; StartPos, EndPos: Integer;
  const Value: UnicodeString): UnicodeString;
begin
  Result := Copy(Source, 1, StartPos) + Value +
    Copy(Source, EndPos + 1, MaxInt);
end;

function EscapeText(const Value: UnicodeString): UnicodeString;
begin
  Result := ReplaceAll(Value, '&', '&amp;');
  Result := ReplaceAll(Result, '<', '&lt;');
  Result := ReplaceAll(Result, '>', '&gt;');
end;

function EscapeAttribute(const Value: UnicodeString; Quote: WideChar): UnicodeString;
begin
  Result := EscapeText(Value);
  if Quote = '"' then Result := ReplaceAll(Result, '"', '&quot;')
  else Result := ReplaceAll(Result, '''', '&apos;');
end;

function AttributeValueRange(const Source: UnicodeString; const Nodes: TXmlNodeSpans;
  Attr: TDOMAttr; out StartPos, EndPos: Integer; out Quote: WideChar): Boolean;
var
  OwnerStart, OwnerEnd, I, NameStart: Integer;
  Owner: TDOMElement;
  Name: UnicodeString;
begin
  Result := False;
  Owner := Attr.OwnerElement;
  if not Assigned(Owner) or not FindNodeSpan(Nodes, Owner, OwnerStart, OwnerEnd) then Exit;
  Name := UnicodeString(Attr.NodeName);
  I := OwnerStart + 1;
  while (I < OwnerEnd) and (Source[I + 1] <> '>') do
  begin
    while (I < OwnerEnd) and (Source[I + 1] in [' ', #9, #10, #13, '/', '<']) do Inc(I);
    NameStart := I;
    while (I < OwnerEnd) and not (Source[I + 1] in
      [' ', #9, #10, #13, '=', '/', '>']) do Inc(I);
    if Copy(Source, NameStart + 1, I - NameStart) = Name then
    begin
      while (I < OwnerEnd) and (Source[I + 1] in [' ', #9, #10, #13]) do Inc(I);
      if (I >= OwnerEnd) or (Source[I + 1] <> '=') then Continue;
      Inc(I);
      while (I < OwnerEnd) and (Source[I + 1] in [' ', #9, #10, #13]) do Inc(I);
      if (I >= OwnerEnd) or not (Source[I + 1] in ['"', '''']) then Exit;
      Quote := Source[I + 1];
      StartPos := I + 1;
      Inc(I);
      while (I < OwnerEnd) and (Source[I + 1] <> Quote) do Inc(I);
      EndPos := I;
      Exit(True);
    end;
    while (I < OwnerEnd) and not (Source[I + 1] in [' ', #9, #10, #13, '>']) do Inc(I);
  end;
end;

function PatchCellSource(const Source: UnicodeString; const Nodes: TXmlNodeSpans;
  const Cell: TXmlCellRef; const Value: UnicodeString;
  out Patched: UnicodeString): Boolean;
var
  StartPos, EndPos: Integer;
  Quote: WideChar;
  Replacement: UnicodeString;
begin
  Result := False;
  Patched := Source;
  if not Assigned(Cell.Node) or (Source = '') then Exit;
  case Cell.Kind of
    xckAttribute:
      begin
        if not AttributeValueRange(Source, Nodes, TDOMAttr(Cell.Node),
          StartPos, EndPos, Quote) then Exit;
        Replacement := EscapeAttribute(Value, Quote);
      end;
    xckText, xckElementText:
      begin
        if not FindNodeSpan(Nodes, Cell.Node, StartPos, EndPos) then Exit;
        if Cell.Node.NodeType = CDATA_SECTION_NODE then
        begin
          if Pos(']]>', Value) > 0 then Exit;
          Inc(StartPos, 9);
          Dec(EndPos, 3);
          Replacement := Value;
        end
        else Replacement := EscapeText(Value);
      end;
    xckComment:
      begin
        if (Pos('--', Value) > 0) or
          ((Value <> '') and (Value[Length(Value)] = '-')) then Exit;
        if not FindNodeSpan(Nodes, Cell.Node, StartPos, EndPos) then Exit;
        Inc(StartPos, 4);
        Dec(EndPos, 3);
        Replacement := Value;
      end;
    xckCData:
      begin
        if Pos(']]>', Value) > 0 then Exit;
        if not FindNodeSpan(Nodes, Cell.Node, StartPos, EndPos) then Exit;
        Inc(StartPos, 9);
        Dec(EndPos, 3);
        Replacement := Value;
      end;
    xckProcessingInstruction:
      begin
        if Pos('?>', Value) > 0 then Exit;
        if not FindNodeSpan(Nodes, Cell.Node, StartPos, EndPos) then Exit;
        StartPos := StartPos + 2 + Length(Cell.Node.NodeName);
        while (StartPos < EndPos) and (Source[StartPos + 1] in [' ', #9]) do Inc(StartPos);
        Dec(EndPos, 2);
        Replacement := Value;
      end;
  else
    Exit;
  end;
  Patched := ReplaceRange(Source, StartPos, EndPos, Replacement);
  Result := True;
end;

end.
