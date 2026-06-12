unit uXmlSource;

{$mode delphi}{$H+}

interface

uses DOM;

type
  TXmlSyntaxKind = (xskTag, xskString, xskValue, xskCData, xskComment);
  TXmlSyntaxSpan = record
    StartPos, EndPos: Integer;
    Kind: TXmlSyntaxKind;
  end;
  TXmlSyntaxSpans = array of TXmlSyntaxSpan;

  TXmlNodeSpan = record
    Node: TDOMNode;
    StartPos, EndPos: Integer;
  end;
  TXmlNodeSpans = array of TXmlNodeSpan;

procedure BuildXmlSourceMap(const Source: UnicodeString; Doc: TXMLDocument;
  out Syntax: TXmlSyntaxSpans; out Nodes: TXmlNodeSpans);
function FindNodeSpan(const Nodes: TXmlNodeSpans; Node: TDOMNode;
  out StartPos, EndPos: Integer): Boolean;
function FindNodeAt(const Nodes: TXmlNodeSpans; Position: Integer): TDOMNode;

implementation

uses SysUtils;

type
  TNodeArray = array of TDOMNode;
  TOpenSpan = record
    Name: UnicodeString;
    SpanIndex: Integer;
  end;
  TOpenSpans = array of TOpenSpan;

procedure AddSyntax(var Spans: TXmlSyntaxSpans; var Count, Capacity: Integer;
  StartPos, EndPos: Integer; Kind: TXmlSyntaxKind);
begin
  if EndPos <= StartPos then Exit;
  if Count >= Capacity then
  begin
    if Capacity = 0 then Capacity := 256 else Capacity := Capacity * 2;
    SetLength(Spans, Capacity);
  end;
  Spans[Count].StartPos := StartPos;
  Spans[Count].EndPos := EndPos;
  Spans[Count].Kind := Kind;
  Inc(Count);
end;

procedure AddDomNodes(Node: TDOMNode; var Nodes: TNodeArray;
  var Count, Capacity: Integer);
var
  Child: TDOMNode;
begin
  if not Assigned(Node) then Exit;
  if Node.NodeType <> DOCUMENT_NODE then
  begin
    if Count >= Capacity then
    begin
      if Capacity = 0 then Capacity := 256 else Capacity := Capacity * 2;
      SetLength(Nodes, Capacity);
    end;
    Nodes[Count] := Node;
    Inc(Count);
  end;
  Child := Node.FirstChild;
  while Assigned(Child) do
  begin
    AddDomNodes(Child, Nodes, Count, Capacity);
    Child := Child.NextSibling;
  end;
end;

function Compatible(Node: TDOMNode; NodeType: Integer;
  const Name: UnicodeString): Boolean;
begin
  Result := Assigned(Node) and (Node.NodeType = NodeType);
  if Result and (NodeType in [ELEMENT_NODE, PROCESSING_INSTRUCTION_NODE]) then
    Result := UnicodeString(Node.NodeName) = Name;
end;

function NextNode(const Flat: TNodeArray; var Index: Integer; NodeType: Integer;
  const Name: UnicodeString): TDOMNode;
begin
  Result := nil;
  while Index < Length(Flat) do
  begin
    if Compatible(Flat[Index], NodeType, Name) then
    begin
      Result := Flat[Index];
      Inc(Index);
      Exit;
    end;
    Inc(Index);
  end;
end;

function AddNodeSpan(var Spans: TXmlNodeSpans; var Count, Capacity: Integer;
  Node: TDOMNode; StartPos, EndPos: Integer): Integer;
begin
  Result := -1;
  if not Assigned(Node) then Exit;
  if Count >= Capacity then
  begin
    if Capacity = 0 then Capacity := 256 else Capacity := Capacity * 2;
    SetLength(Spans, Capacity);
  end;
  Result := Count;
  Spans[Result].Node := Node;
  Spans[Result].StartPos := StartPos;
  Spans[Result].EndPos := EndPos;
  Inc(Count);
end;

function StartsAt(const S, Prefix: UnicodeString; Position: Integer): Boolean;
begin
  Result := Copy(S, Position, Length(Prefix)) = Prefix;
end;

function FindEnd(const S, Marker: UnicodeString; Position: Integer): Integer;
var
  P: Integer;
begin
  P := Pos(Marker, Copy(S, Position, MaxInt));
  if P = 0 then Exit(Length(S) + 1);
  Result := Position + P - 1 + Length(Marker);
end;

function ReadName(const S: UnicodeString; var Position: Integer): UnicodeString;
var
  StartPos: Integer;
begin
  while (Position <= Length(S)) and (S[Position] in [' ', #9, #10, #13, '/']) do
    Inc(Position);
  StartPos := Position;
  while (Position <= Length(S)) and
    not (S[Position] in [' ', #9, #10, #13, '/', '>', '=']) do Inc(Position);
  Result := Copy(S, StartPos, Position - StartPos);
end;

procedure ColorTag(const Source: UnicodeString; StartPos, EndPos: Integer;
  var Syntax: TXmlSyntaxSpans; var SyntaxCount, SyntaxCapacity: Integer);
var
  I, QStart: Integer;
  Quote: WideChar;
begin
  AddSyntax(Syntax, SyntaxCount, SyntaxCapacity, StartPos - 1, EndPos - 1, xskTag);
  I := StartPos;
  while I < EndPos do
  begin
    if Source[I] in ['"', ''''] then
    begin
      Quote := Source[I];
      QStart := I;
      Inc(I);
      while (I < EndPos) and (Source[I] <> Quote) do Inc(I);
      if I < EndPos then Inc(I);
      AddSyntax(Syntax, SyntaxCount, SyntaxCapacity, QStart - 1, I - 1, xskString);
    end
    else Inc(I);
  end;
end;

procedure BuildXmlSourceMap(const Source: UnicodeString; Doc: TXMLDocument;
  out Syntax: TXmlSyntaxSpans; out Nodes: TXmlNodeSpans);
var
  Flat: TNodeArray;
  Open: TOpenSpans;
  FlatIndex, FlatCount, FlatCapacity, SyntaxCount, SyntaxCapacity,
    NodeCount, NodeCapacity, I, J, StartPos, EndPos, NamePos, SpanIndex,
    BracketDepth: Integer;
  Name: UnicodeString;
  Node: TDOMNode;
  IsClosing, IsEmpty: Boolean;
  Quote: WideChar;
begin
  SetLength(Syntax, 0);
  SetLength(Nodes, 0);
  SetLength(Flat, 0);
  SetLength(Open, 0);
  FlatCount := 0; FlatCapacity := 0;
  SyntaxCount := 0; SyntaxCapacity := 0;
  NodeCount := 0; NodeCapacity := 0;
  AddDomNodes(Doc, Flat, FlatCount, FlatCapacity);
  SetLength(Flat, FlatCount);
  AddNodeSpan(Nodes, NodeCount, NodeCapacity, Doc, 0, Length(Source));
  FlatIndex := 0;
  I := 1;
  while I <= Length(Source) do
  begin
    if Source[I] <> '<' then
    begin
      StartPos := I;
      while (I <= Length(Source)) and (Source[I] <> '<') do Inc(I);
      if Trim(Copy(Source, StartPos, I - StartPos)) <> '' then
      begin
        AddSyntax(Syntax, SyntaxCount, SyntaxCapacity, StartPos - 1, I - 1, xskValue);
        Node := NextNode(Flat, FlatIndex, TEXT_NODE, '');
        AddNodeSpan(Nodes, NodeCount, NodeCapacity, Node, StartPos - 1, I - 1);
      end;
      Continue;
    end;

    StartPos := I;
    if StartsAt(Source, '<!--', I) then
    begin
      EndPos := FindEnd(Source, '-->', I + 4);
      AddSyntax(Syntax, SyntaxCount, SyntaxCapacity, StartPos - 1, EndPos - 1, xskComment);
      Node := NextNode(Flat, FlatIndex, COMMENT_NODE, '');
      AddNodeSpan(Nodes, NodeCount, NodeCapacity, Node, StartPos - 1, EndPos - 1);
      I := EndPos;
      Continue;
    end;
    if StartsAt(Source, '<![CDATA[', I) then
    begin
      EndPos := FindEnd(Source, ']]>', I + 9);
      AddSyntax(Syntax, SyntaxCount, SyntaxCapacity, StartPos - 1, EndPos - 1, xskCData);
      Node := NextNode(Flat, FlatIndex, CDATA_SECTION_NODE, '');
      AddNodeSpan(Nodes, NodeCount, NodeCapacity, Node, StartPos - 1, EndPos - 1);
      I := EndPos;
      Continue;
    end;
    if StartsAt(Source, '<?', I) then
    begin
      EndPos := FindEnd(Source, '?>', I + 2);
      ColorTag(Source, StartPos, EndPos, Syntax, SyntaxCount, SyntaxCapacity);
      NamePos := I + 2;
      Name := ReadName(Source, NamePos);
      if LowerCase(Name) <> 'xml' then
      begin
        Node := NextNode(Flat, FlatIndex, PROCESSING_INSTRUCTION_NODE, Name);
        AddNodeSpan(Nodes, NodeCount, NodeCapacity, Node, StartPos - 1, EndPos - 1);
      end;
      I := EndPos;
      Continue;
    end;
    if StartsAt(Source, '<!', I) then
    begin
      J := I + 2;
      BracketDepth := 0;
      Quote := #0;
      while J <= Length(Source) do
      begin
        if Quote <> #0 then
        begin
          if Source[J] = Quote then Quote := #0;
        end
        else if Source[J] in ['"', ''''] then Quote := Source[J]
        else if Source[J] = '[' then Inc(BracketDepth)
        else if Source[J] = ']' then Dec(BracketDepth)
        else if (Source[J] = '>') and (BracketDepth <= 0) then Break;
        Inc(J);
      end;
      EndPos := J + Ord(J <= Length(Source));
      ColorTag(Source, StartPos, EndPos, Syntax, SyntaxCount, SyntaxCapacity);
      if StartsAt(Source, '<!DOCTYPE', StartPos) then
      begin
        Node := NextNode(Flat, FlatIndex, DOCUMENT_TYPE_NODE, '');
        AddNodeSpan(Nodes, NodeCount, NodeCapacity, Node, StartPos - 1, EndPos - 1);
      end;
      I := EndPos;
      Continue;
    end;

    J := I + 1;
    IsClosing := (J <= Length(Source)) and (Source[J] = '/');
    Name := ReadName(Source, J);
    while (J <= Length(Source)) and (Source[J] <> '>') do
    begin
      if Source[J] in ['"', ''''] then
      begin
        NamePos := J;
        Inc(J);
        while (J <= Length(Source)) and (Source[J] <> Source[NamePos]) do Inc(J);
      end;
      Inc(J);
    end;
    EndPos := J + Ord(J <= Length(Source));
    ColorTag(Source, StartPos, EndPos, Syntax, SyntaxCount, SyntaxCapacity);
    IsEmpty := (J > 1) and (Source[J - 1] = '/');
    if IsClosing then
    begin
      for J := High(Open) downto 0 do
        if Open[J].Name = Name then
        begin
          Nodes[Open[J].SpanIndex].EndPos := EndPos - 1;
          SetLength(Open, J);
          Break;
        end;
    end
    else
    begin
      Node := NextNode(Flat, FlatIndex, ELEMENT_NODE, Name);
      SpanIndex := AddNodeSpan(Nodes, NodeCount, NodeCapacity, Node,
        StartPos - 1, EndPos - 1);
      if not IsEmpty and (SpanIndex >= 0) then
      begin
        J := Length(Open);
        SetLength(Open, J + 1);
        Open[J].Name := Name;
        Open[J].SpanIndex := SpanIndex;
      end;
    end;
    I := EndPos;
  end;
  SetLength(Syntax, SyntaxCount);
  SetLength(Nodes, NodeCount);
end;

function FindNodeSpan(const Nodes: TXmlNodeSpans; Node: TDOMNode;
  out StartPos, EndPos: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Nodes) do
    if Nodes[I].Node = Node then
    begin
      StartPos := Nodes[I].StartPos;
      EndPos := Nodes[I].EndPos;
      Exit(True);
    end;
  StartPos := 0;
  EndPos := 0;
  Result := False;
end;

function FindNodeAt(const Nodes: TXmlNodeSpans; Position: Integer): TDOMNode;
var
  I, BestLength, L: Integer;
begin
  Result := nil;
  BestLength := MaxInt;
  for I := 0 to High(Nodes) do
    if (Position >= Nodes[I].StartPos) and (Position < Nodes[I].EndPos) then
    begin
      L := Nodes[I].EndPos - Nodes[I].StartPos;
      if L < BestLength then
      begin
        Result := Nodes[I].Node;
        BestLength := L;
      end;
    end;
end;

end.
