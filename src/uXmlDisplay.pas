unit uXmlDisplay;

{$mode delphi}{$H+}

interface

type
  TIntegerArray = array of Integer;

procedure FormatXmlDisplay(const Source: UnicodeString; RangeStart, RangeEnd: Integer;
  out Display: UnicodeString; out DisplayToSource, SourceToDisplay: TIntegerArray);

implementation

uses SysUtils;

function StartsAt(const S, Prefix: UnicodeString; Position: Integer): Boolean;
begin
  Result := Copy(S, Position, Length(Prefix)) = Prefix;
end;

function TagEnd(const Source: UnicodeString; StartPos, RangeEnd: Integer): Integer;
var
  I, BracketDepth: Integer;
  Quote: WideChar;
  Marker: UnicodeString;
begin
  if StartsAt(Source, '<!--', StartPos + 1) then Marker := '-->'
  else if StartsAt(Source, '<![CDATA[', StartPos + 1) then Marker := ']]>'
  else if StartsAt(Source, '<?', StartPos + 1) then Marker := '?>'
  else Marker := '';
  if Marker <> '' then
  begin
    I := Pos(Marker, Copy(Source, StartPos + 1, RangeEnd - StartPos));
    if I = 0 then Exit(RangeEnd);
    Result := StartPos + I - 1 + Length(Marker);
    if Result > RangeEnd then Result := RangeEnd;
    Exit;
  end;
  I := StartPos;
  Quote := #0;
  BracketDepth := 0;
  while I < RangeEnd do
  begin
    Inc(I);
    if Quote <> #0 then
    begin
      if Source[I] = Quote then Quote := #0;
    end
    else if Source[I] in ['"', ''''] then Quote := Source[I]
    else if Source[I] = '[' then Inc(BracketDepth)
    else if Source[I] = ']' then Dec(BracketDepth)
    else if (Source[I] = '>') and (BracketDepth <= 0) then Exit(I);
  end;
  Result := RangeEnd;
end;

procedure FormatXmlDisplay(const Source: UnicodeString; RangeStart, RangeEnd: Integer;
  out Display: UnicodeString; out DisplayToSource, SourceToDisplay: TIntegerArray);
var
  I, J, K, Depth, TokenEnd, DisplayLength, PositionLength, Capacity,
    PositionCapacity: Integer;
  LastWasText, Closing, Special, EmptyTag: Boolean;

  procedure EnsureCapacity(Required: Integer);
  begin
    if Required <= Capacity then Exit;
    if Capacity = 0 then Capacity := 1024;
    while Capacity < Required do Capacity := Capacity * 2;
    SetLength(Display, Capacity);
    SetLength(DisplayToSource, Capacity);
  end;

  procedure EnsurePositionCapacity(Required: Integer);
  begin
    if Required <= PositionCapacity then Exit;
    if PositionCapacity = 0 then PositionCapacity := 1024;
    while PositionCapacity < Required do PositionCapacity := PositionCapacity * 2;
    SetLength(DisplayToSource, PositionCapacity);
  end;

  procedure AppendChar(Ch: WideChar; SourcePos: Integer);
  var
    IsCrLfTail: Boolean;
  begin
    IsCrLfTail := (Ch = #10) and (DisplayLength > 0) and
      (Display[DisplayLength] = #13);
    Inc(DisplayLength);
    EnsureCapacity(DisplayLength);
    Display[DisplayLength] := Ch;
    if not IsCrLfTail then
    begin
      Inc(PositionLength);
      EnsurePositionCapacity(PositionLength);
      DisplayToSource[PositionLength - 1] := SourcePos;
    end;
    if (SourcePos >= RangeStart) and (SourcePos < RangeEnd) then
      SourceToDisplay[SourcePos - RangeStart] := PositionLength - 1;
  end;

  procedure AppendIndent(SourcePos: Integer);
  var
    N: Integer;
  begin
    if DisplayLength > 0 then
    begin
      AppendChar(#13, SourcePos);
      AppendChar(#10, SourcePos);
    end;
    for N := 1 to Depth * 2 do AppendChar(' ', SourcePos);
  end;

  procedure AppendSource(FirstPos, LastPos: Integer);
  var
    N: Integer;
  begin
    for N := FirstPos to LastPos do AppendChar(Source[N + 1], N);
  end;

begin
  Display := '';
  SetLength(DisplayToSource, 0);
  if RangeStart < 0 then RangeStart := 0;
  if RangeEnd > Length(Source) then RangeEnd := Length(Source);
  if RangeEnd < RangeStart then RangeEnd := RangeStart;
  SetLength(SourceToDisplay, RangeEnd - RangeStart + 1);
  for I := 0 to High(SourceToDisplay) do SourceToDisplay[I] := -1;
  DisplayLength := 0;
  PositionLength := 0;
  Capacity := 0;
  PositionCapacity := 0;
  Depth := 0;
  LastWasText := False;
  I := RangeStart;
  while I < RangeEnd do
  begin
    if Source[I + 1] <> '<' then
    begin
      J := I;
      while (J < RangeEnd) and (Source[J + 1] <> '<') do Inc(J);
      if Trim(Copy(Source, I + 1, J - I)) <> '' then
      begin
        AppendSource(I, J - 1);
        LastWasText := True;
      end;
      I := J;
      Continue;
    end;
    TokenEnd := TagEnd(Source, I, RangeEnd);
    Closing := StartsAt(Source, '</', I + 1);
    Special := StartsAt(Source, '<?', I + 1) or StartsAt(Source, '<!', I + 1);
    K := TokenEnd - 2;
    while (K > I) and (Source[K + 1] in [' ', #9, #10, #13]) do Dec(K);
    EmptyTag := (K > I) and (Source[K + 1] = '/');
    if Closing and (Depth > 0) then Dec(Depth);
    if not LastWasText then AppendIndent(I);
    AppendSource(I, TokenEnd - 1);
    if not Closing and not Special and not EmptyTag then Inc(Depth);
    LastWasText := False;
    I := TokenEnd;
  end;
  SetLength(Display, DisplayLength);
  SetLength(DisplayToSource, PositionLength);
  SourceToDisplay[High(SourceToDisplay)] := PositionLength;
end;

end.
