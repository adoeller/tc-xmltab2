unit uXmlCellEdit;

{$mode delphi}{$H+}

interface

uses DOM;

type
  TXmlCellKind = (xckReadOnly, xckAttribute, xckText, xckComment, xckCData,
    xckProcessingInstruction, xckElementText);
  TXmlCellRef = record
    Kind: TXmlCellKind;
    Node: TDOMNode;
  end;

function EditableCell(Node: TDOMNode): TXmlCellRef;
function CellRefValue(const Cell: TXmlCellRef): UnicodeString;
function ApplyCellValue(const Cell: TXmlCellRef;
  const Value: UnicodeString): Boolean;

implementation

function EditableCell(Node: TDOMNode): TXmlCellRef;
var
  Child, TextChild: TDOMNode;
begin
  Result.Kind := xckReadOnly;
  Result.Node := nil;
  if not Assigned(Node) then Exit;
  case Node.NodeType of
    ATTRIBUTE_NODE: Result.Kind := xckAttribute;
    TEXT_NODE: Result.Kind := xckText;
    COMMENT_NODE: Result.Kind := xckComment;
    CDATA_SECTION_NODE: Result.Kind := xckCData;
    PROCESSING_INSTRUCTION_NODE: Result.Kind := xckProcessingInstruction;
    ELEMENT_NODE:
      begin
        TextChild := nil;
        Child := Node.FirstChild;
        while Assigned(Child) do
        begin
          if Child.NodeType in [TEXT_NODE, CDATA_SECTION_NODE] then
          begin
            if Assigned(TextChild) then Exit;
            TextChild := Child;
          end
          else Exit;
          Child := Child.NextSibling;
        end;
        if not Assigned(TextChild) then Exit;
        Result.Kind := xckElementText;
        Node := TextChild;
      end;
  else
    Exit;
  end;
  Result.Node := Node;
end;

function CellRefValue(const Cell: TXmlCellRef): UnicodeString;
begin
  if Assigned(Cell.Node) then Result := UnicodeString(Cell.Node.NodeValue)
  else Result := '';
end;

function ApplyCellValue(const Cell: TXmlCellRef;
  const Value: UnicodeString): Boolean;
begin
  Result := (Cell.Kind <> xckReadOnly) and Assigned(Cell.Node);
  if Result then Cell.Node.NodeValue := DOMString(Value);
end;

end.
