unit uViewer;

{$mode delphi}{$H+}

interface

uses Windows;

function CreateXmlViewer(ParentWin: HWND; const FileName: UnicodeString;
  ShowFlags: Integer): HWND;
procedure CloseXmlViewer(Wnd: HWND);
function SearchXmlViewer(Wnd: HWND; const SearchText: UnicodeString;
  SearchFlags: Integer): Integer;

implementation

uses Messages, CommCtrl, RichEdit, SysUtils, Classes, DOM, uXmlModel,
  uXmlSource, uXmlCellEdit, uXmlLossless, uXmlDisplay, uNaturalSort, uColumnSample,
  uDecimalAlign, uSettings, listplug;

const
  IDC_TREE = 101;
  IDC_TAB = 102;
  IDC_GRID = 103;
  IDC_TEXT = 104;
  IDC_STATUS = 105;
  SPLITTER_WIDTH = 5;
  IDC_FILTER_BASE = 2000;
  IDM_COPY_CELL = 3001;
  IDM_COPY_ROWS = 3002;
  IDM_COPY_XPATH = 3003;
  IDM_SHOW_SAME = 3004;
  IDM_FILTERS = 3005;
  IDM_DARK_THEME = 3006;
  IDM_FORMAT = 3007;
  IDM_LOCATE = 3008;
  IDM_SELECT_ALL = 3009;
  IDM_COPY_COLUMN = 3010;
  IDM_HIDE_COLUMN = 3011;
  IDM_SHOW_COLUMNS = 3012;
  IDM_EDIT_MODE = 3013;
  IDM_SAVE = 3014;
  IDC_CELL_EDITOR = 4000;

type
  TXmlCellRefRow = array of TXmlCellRef;
  TXmlCellRefRows = array of TXmlCellRefRow;

  TXmlViewer = class
  private
    FWnd, FTree, FTab, FGrid, FText, FStatus, FCellEditor: HWND;
    FTabOldProc, FTreeOldProc, FGridOldProc, FTextOldProc,
      FEditorOldProc, FFilterOldProc: WNDPROC;
    FFont, FHeaderFont: HFONT;
    FFilterBrush: HBRUSH;
    FDoc: TXMLDocument;
    FEncoding: TXmlEncodingInfo;
    FFileName: UnicodeString;
    FSourceText: UnicodeString;
    FSyntaxSpans: TXmlSyntaxSpans;
    FNodeSpans: TXmlNodeSpans;
    FTextSourceStart: Integer;
    FTextSourceMapped, FSourceMapReady, FTextDirty: Boolean;
    FTextDisplayToSource, FTextSourceToDisplay: TIntegerArray;
    FNodes: array of TDOMNode;
    FRows: array of array of UnicodeString;
    FCellRefs: TXmlCellRefRows;
    FRowNodes: array of TDOMNode;
    FVisibleRows: array of Integer;
    FSortColumn: Integer;
    FSortDescending: Boolean;
    FDecimalAlign: Boolean;
    FDecimalAnchors: array of Integer;
    FDecimalColumns: array of Boolean;
    FCurrentRow: Integer;
    FCurrentColumn: Integer;
    FSearchText: UnicodeString;
    FSearchFlags, FSearchRow, FSearchColumn, FSearchCellPos: Integer;
    FSplitter: Integer;
    FDragging: Boolean;
    FFontSize: Integer;
    FDark, FFilterVisible, FFormatText, FSelectingTree, FEditMode, FDirty,
      FClosingEditor, FConfirmingClose: Boolean;
    FEditorRow, FEditorColumn: Integer;
    FSameName, FGridMode: UnicodeString;
    FFilterEdits: array of HWND;
    FTextColor, FBackColor, FBackColor2, FHeaderTextColor, FHeaderBackColor,
      FFilterTextColor, FFilterBackColor,
      FCurrentCellColor, FSelectionTextColor, FSelectionBackColor,
      FSplitterColor: COLORREF;
    procedure BuildTree;
    function AddNode(Parent: HTREEITEM; Node: TDOMNode): HTREEITEM;
    procedure AddChildren(Item: HTREEITEM; Node: TDOMNode);
    procedure ExpandTreeItem(Item: HTREEITEM);
    function SelectedNode: TDOMNode;
    function FindTreeItem(Node: TDOMNode): HTREEITEM;
    procedure SelectTreeNode(Node: TDOMNode);
    procedure NavigateGridRowToTree(Row: Integer);
    procedure ShowSameSiblings;
    procedure CopyXPath;
    procedure CopySelectedCell;
    procedure CopySelectedColumn;
    procedure CopyRows;
    procedure CopyColumn;
    procedure HideColumn(Column: Integer);
    procedure ShowAllColumns;
    procedure LocateText;
    function SourcePositionAtTextCursor(TextPosition: Integer): Integer;
    procedure EnsureSourceMap;
    function FindSourceRange(Node: TDOMNode; out StartPos, EndPos: Integer): Boolean;
    procedure UpdateStatus;
    procedure UpdatePositionStatus;
    procedure UpdateSelection;
    procedure BuildGrid(Node: TDOMNode);
    procedure CreateFilterEdits;
    procedure LayoutFilters;
    procedure ApplyFilters;
    procedure ApplyTheme;
    function CustomDraw(Draw: PNMLVCUSTOMDRAW): LRESULT;
    procedure UpdateDecimalAnchors;
    procedure SetFontSize(NewSize: Integer);
    procedure UpdateText(Node: TDOMNode);
    procedure HighlightVisibleText;
    procedure Layout;
    procedure SortGrid(Column: Integer);
    procedure AutoSizeColumns;
    function CellRef(Row, Column: Integer): TXmlCellRef;
    procedure BeginCellEdit(Row, Column: Integer);
    procedure CloseCellEdit(Accept: Boolean);
    function ApplyCellEdit(Row, Column: Integer;
      const Value: UnicodeString): Boolean;
    function SaveChanges: Boolean;
    function ConfirmClose: Boolean;
    procedure UpdateEditStatus(const MessageText: UnicodeString = '');
    function ForwardHostHotKey(Key: WPARAM): Boolean;
    function HandleHotKey(Key: WPARAM): Boolean;
    function Search(const S: UnicodeString; Flags: Integer): Integer;
  public
    constructor Create(ParentWin: HWND; const FileName: UnicodeString);
    destructor Destroy; override;
  end;

var
  ViewerClass: ATOM;

function ViewerFromWnd(Wnd: HWND): TXmlViewer;
begin
  Result := TXmlViewer(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
end;

function TreeItemParam(Tree: HWND; Item: HTREEITEM): LPARAM;
var
  TV: TVItemW;
begin
  Result := -1;
  FillChar(TV, SizeOf(TV), 0);
  TV.mask := TVIF_PARAM;
  TV.hItem := Item;
  if SendMessageW(Tree, TVM_GETITEMW, 0, LPARAM(@TV)) <> 0 then Result := TV.lParam;
end;

function IsVisibleTreeNode(Node: TDOMNode): Boolean;
begin
  Result := Assigned(Node);
  if Result and (Node.NodeType = TEXT_NODE) then
    Result := Trim(UnicodeString(Node.NodeValue)) <> '';
end;

function FirstVisibleChild(Node: TDOMNode): TDOMNode;
begin
  Result := nil;
  if not Assigned(Node) then Exit;
  Result := Node.FirstChild;
  while Assigned(Result) and not IsVisibleTreeNode(Result) do
    Result := Result.NextSibling;
end;

function NextVisibleSibling(Node: TDOMNode): TDOMNode;
begin
  Result := nil;
  if not Assigned(Node) then Exit;
  Result := Node.NextSibling;
  while Assigned(Result) and not IsVisibleTreeNode(Result) do
    Result := Result.NextSibling;
end;

procedure SetClipboardText(const S: UnicodeString);
var
  H: HGLOBAL;
  P: Pointer;
begin
  H := GlobalAlloc(GMEM_MOVEABLE, (Length(S) + 1) * SizeOf(WideChar));
  if H = 0 then Exit;
  P := GlobalLock(H);
  Move(PWideChar(S)^, P^, (Length(S) + 1) * SizeOf(WideChar));
  GlobalUnlock(H);
  if OpenClipboard(0) then
  try
    EmptyClipboard;
    SetClipboardData(CF_UNICODETEXT, H);
    H := 0;
  finally
    CloseClipboard;
  end;
  if H <> 0 then GlobalFree(H);
end;

function MatchesFilter(const Value, Filter: UnicodeString;
  CaseSensitive: Boolean): Boolean;
var
  V, F: UnicodeString;
  DV, DF: Double;
  FS: TFormatSettings;
begin
  if Filter = '' then Exit(True);
  V := Value; F := Filter;
  if not CaseSensitive then begin V := LowerCase(V); F := LowerCase(F); end;
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  if (Length(F) > 1) and (F[1] = '=') then Exit(V = Copy(F, 2, MaxInt));
  if (Length(F) > 1) and (F[1] = '!') then Exit(Pos(Copy(F, 2, MaxInt), V) = 0);
  if (Length(F) > 1) and (F[1] in ['<', '>']) and
    TryStrToFloat(Copy(F, 2, MaxInt), DF, FS) and TryStrToFloat(V, DV, FS) then
  begin
    if F[1] = '<' then Exit(DV < DF) else Exit(DV > DF);
  end;
  if (Length(F) > 1) and (F[1] = '<') then Exit(V < Copy(F, 2, MaxInt));
  if (Length(F) > 1) and (F[1] = '>') then Exit(V > Copy(F, 2, MaxInt));
  Result := Pos(F, V) > 0;
end;

function MainWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TXmlViewer;
  N: PNMHDR;
  Item: PLVDispInfoW;
  HeaderDraw: PNMCustomDraw;
  HeaderItem: HDItemW;
  HeaderText: array[0..4095] of WideChar;
  HeaderBrush: HBRUSH;
  HeaderRect: TRect;
  PaintRect: TRect;
  R, C, Cmd: Integer;
  P: TPoint;
  Menu: HMENU;
  Target: HWND;
  Hit: TVHitTestInfo;
  TreeItem: HTREEITEM;
begin
  V := ViewerFromWnd(Wnd);
  case Msg of
    WM_SIZE: if Assigned(V) then begin V.Layout; Exit(0); end;
    WM_ERASEBKGND:
      if Assigned(V) then
      begin
        GetClientRect(Wnd, PaintRect);
        HeaderBrush := CreateSolidBrush(V.FSplitterColor);
        FillRect(HDC(WParam), PaintRect, HeaderBrush);
        DeleteObject(HeaderBrush);
        Exit(1);
      end;
    WM_LBUTTONDOWN:
      if Assigned(V) and (SmallInt(LoWord(LParam)) >= V.FSplitter) and
        (SmallInt(LoWord(LParam)) <= V.FSplitter + SPLITTER_WIDTH) then
      begin
        V.FDragging := True;
        SetCapture(Wnd);
        Exit(0);
      end;
    WM_MOUSEMOVE:
      if Assigned(V) and V.FDragging then
      begin
        V.FSplitter := SmallInt(LoWord(LParam));
        V.Layout;
        Exit(0);
      end;
    WM_LBUTTONUP:
      if Assigned(V) and V.FDragging then
      begin
        V.FDragging := False;
        ReleaseCapture;
        Exit(0);
      end;
    WM_SETCURSOR:
      if Assigned(V) then
      begin
        GetCursorPos(P);
        ScreenToClient(Wnd, P);
        if (P.X >= V.FSplitter) and (P.X <= V.FSplitter + SPLITTER_WIDTH) then
        begin
          SetCursor(LoadCursor(0, IDC_SIZEWE));
          Exit(1);
        end;
      end;
    WM_NOTIFY:
      if Assigned(V) then
      begin
        N := PNMHDR(LParam);
        if (N^.hwndFrom = V.FTree) and (Integer(N^.code) = TVN_SELCHANGEDW) then
        begin
          if not V.FSelectingTree then begin V.CloseCellEdit(True); V.UpdateSelection; end;
          Exit(0);
        end;
        if (N^.hwndFrom = V.FTree) and
          ((Integer(N^.code) = TVN_ITEMEXPANDINGA) or
           (Integer(N^.code) = TVN_ITEMEXPANDINGW)) then
        begin V.ExpandTreeItem(PNMTreeViewW(LParam)^.itemNew.hItem); Exit(0); end;
        if (N^.hwndFrom = V.FGrid) and (Integer(N^.code) = LVN_GETDISPINFOW) then
        begin
          Item := PLVDispInfoW(LParam);
          R := Item^.item.iItem; C := Item^.item.iSubItem;
          if (R >= 0) and (R < Length(V.FVisibleRows)) and
            (C >= 0) and (C < Length(V.FRows[V.FVisibleRows[R]])) then
            lstrcpynW(Item^.item.pszText, PWideChar(V.FRows[V.FVisibleRows[R]][C]),
              Item^.item.cchTextMax);
          Exit(0);
        end;
        if (N^.hwndFrom = V.FGrid) and (Integer(N^.code) = NM_DBLCLK) then
        begin
          V.FCurrentRow := PNMItemActivate(LParam)^.iItem;
          V.FCurrentColumn := PNMItemActivate(LParam)^.iSubItem;
          V.UpdatePositionStatus;
          if V.FEditMode then
            V.BeginCellEdit(V.FCurrentRow, V.FCurrentColumn)
          else
            V.NavigateGridRowToTree(V.FCurrentRow);
          Exit(0);
        end;
        if (N^.hwndFrom = V.FGrid) and
          ((Integer(N^.code) = NM_CLICK) or (Integer(N^.code) = NM_RCLICK)) then
        begin
          V.CloseCellEdit(True);
          R := PNMItemActivate(LParam)^.iItem;
          V.FCurrentRow := R;
          V.FCurrentColumn := PNMItemActivate(LParam)^.iSubItem;
          V.UpdatePositionStatus;
          if R >= 0 then ListView_SetItemState(V.FGrid, R,
            LVIS_SELECTED or LVIS_FOCUSED, LVIS_SELECTED or LVIS_FOCUSED);
        end;
        if (N^.hwndFrom = V.FGrid) and (Integer(N^.code) = LVN_ITEMCHANGED) then
        begin
          if (PNMListView(LParam)^.uNewState and LVIS_SELECTED) <> 0 then
          begin
            V.FCurrentRow := PNMListView(LParam)^.iItem;
            V.UpdatePositionStatus;
          end;
        end;
        if (N^.hwndFrom = V.FGrid) and (Integer(N^.code) = NM_CUSTOMDRAW) then
          Exit(V.CustomDraw(PNMLVCUSTOMDRAW(LParam)));
        if (N^.hwndFrom = ListView_GetHeader(V.FGrid)) and
          (Integer(N^.code) = NM_CUSTOMDRAW) then
        begin
          HeaderDraw := PNMCustomDraw(LParam);
          if HeaderDraw^.dwDrawStage = CDDS_PREPAINT then
            Exit(CDRF_NOTIFYITEMDRAW);
          if HeaderDraw^.dwDrawStage = CDDS_ITEMPREPAINT then
          begin
            HeaderBrush := CreateSolidBrush(V.FHeaderBackColor);
            FillRect(HeaderDraw^.hdc, HeaderDraw^.rc, HeaderBrush);
            DeleteObject(HeaderBrush);
            FillChar(HeaderText, SizeOf(HeaderText), 0);
            FillChar(HeaderItem, SizeOf(HeaderItem), 0);
            HeaderItem.mask := HDI_TEXT;
            HeaderItem.pszText := @HeaderText[0];
            HeaderItem.cchTextMax := Length(HeaderText);
            SendMessageW(ListView_GetHeader(V.FGrid), HDM_GETITEMW,
              PtrUInt(HeaderDraw^.dwItemSpec), PtrInt(@HeaderItem));
            SetTextColor(HeaderDraw^.hdc, V.FHeaderTextColor);
            SetBkMode(HeaderDraw^.hdc, TRANSPARENT);
            HeaderRect := HeaderDraw^.rc;
            Inc(HeaderRect.Left, 6);
            DrawTextW(HeaderDraw^.hdc, @HeaderText[0], -1, HeaderRect,
              DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
            DrawEdge(HeaderDraw^.hdc, HeaderDraw^.rc, BDR_SUNKENOUTER,
              BF_RIGHT or BF_BOTTOM);
            Exit(CDRF_SKIPDEFAULT);
          end;
        end;
        if (N^.hwndFrom = ListView_GetHeader(V.FGrid)) and (Integer(N^.code) = HDN_ITEMCLICKW) then
        begin V.SortGrid(PNMHeaderW(LParam)^.iItem); Exit(0); end;
        if (N^.hwndFrom = V.FTab) and (Integer(N^.code) = TCN_SELCHANGE) then
        begin
          V.CloseCellEdit(True);
          if TabCtrl_GetCurSel(V.FTab) = 0 then
          begin ShowWindow(V.FGrid, SW_SHOW); ShowWindow(V.FText, SW_HIDE); end
          else
          begin
            ShowWindow(V.FGrid, SW_HIDE);
            ShowWindow(V.FText, SW_SHOW);
            if V.FTextDirty then V.UpdateText(V.SelectedNode);
            V.HighlightVisibleText;
          end;
          V.Layout; Exit(0);
        end;
      end;
    WM_MOUSEWHEEL:
      if Assigned(V) and ((GetKeyState(VK_CONTROL) and $8000) <> 0) then
      begin
        if SmallInt(HiWord(WParam)) > 0 then V.SetFontSize(V.FFontSize - 1)
        else V.SetFontSize(V.FFontSize + 1);
        Exit(0);
      end;
    WM_KEYDOWN:
      if Assigned(V) and V.HandleHotKey(WParam) then Exit(0);
    WM_CONTEXTMENU:
      if Assigned(V) then
      begin
        if LParam = -1 then GetCursorPos(P)
        else begin P.X := SmallInt(LoWord(LParam)); P.Y := SmallInt(HiWord(LParam)); end;
        Target := WindowFromPoint(P);
        Menu := CreatePopupMenu;
        try
          if Target = V.FTree then
          begin
            SetFocus(V.FTree);
            ScreenToClient(V.FTree, P);
            FillChar(Hit, SizeOf(Hit), 0);
            Hit.pt := P;
            TreeItem := TreeView_HitTest(V.FTree, Hit);
            if TreeItem <> nil then TreeView_SelectItem(V.FTree, TreeItem);
            ClientToScreen(V.FTree, P);
            AppendMenuW(Menu, MF_STRING, IDM_COPY_XPATH, 'Copy XPath');
            AppendMenuW(Menu, MF_STRING, IDM_SHOW_SAME, 'Show same siblings');
          end
          else if Target = V.FText then
          begin
            SetFocus(V.FText);
            AppendMenuW(Menu, MF_STRING, IDM_COPY_CELL, 'Copy');
            AppendMenuW(Menu, MF_STRING, IDM_SELECT_ALL, 'Select all');
            AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
            AppendMenuW(Menu, MF_STRING or Ord(V.FFormatText) * MF_CHECKED,
              IDM_FORMAT, 'Format');
            AppendMenuW(Menu, MF_STRING, IDM_LOCATE, 'Locate');
          end
          else
          begin
            SetFocus(V.FGrid);
            AppendMenuW(Menu, MF_STRING, IDM_COPY_CELL, 'Copy cell');
            AppendMenuW(Menu, MF_STRING, IDM_COPY_ROWS, 'Copy row(s)');
            AppendMenuW(Menu, MF_STRING, IDM_COPY_COLUMN, 'Copy column');
            AppendMenuW(Menu, MF_STRING, IDM_COPY_XPATH, 'Copy XPath');
            AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
            AppendMenuW(Menu, MF_STRING, IDM_HIDE_COLUMN, 'Hide column');
            AppendMenuW(Menu, MF_STRING, IDM_SHOW_COLUMNS, 'Show all columns');
            AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
            AppendMenuW(Menu, MF_STRING or Ord(V.FFilterVisible) * MF_CHECKED,
              IDM_FILTERS, 'Filters');
            AppendMenuW(Menu, MF_STRING or Ord(V.FEditMode) * MF_CHECKED,
              IDM_EDIT_MODE, 'Edit mode (Ctrl+R)');
          end;
          AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
          AppendMenuW(Menu, MF_STRING, IDM_SAVE, 'Save (Ctrl+S)');
          AppendMenuW(Menu, MF_SEPARATOR, 0, nil);
          AppendMenuW(Menu, MF_STRING or Ord(V.FDark) * MF_CHECKED,
            IDM_DARK_THEME, 'Dark theme');
          TrackPopupMenu(Menu, TPM_RIGHTBUTTON, P.X, P.Y, 0, Wnd, nil);
        finally DestroyMenu(Menu); end;
        Exit(0);
      end;
    WM_COMMAND:
      if Assigned(V) then
      begin
        Cmd := LoWord(WParam);
        if (Cmd >= IDC_FILTER_BASE) and
          (Cmd < IDC_FILTER_BASE + Length(V.FFilterEdits)) and
          (HiWord(WParam) = EN_CHANGE) then begin V.ApplyFilters; Exit(0); end;
        case Cmd of
          IDM_COPY_CELL: V.CopySelectedCell;
          IDM_COPY_ROWS: V.CopyRows;
          IDM_COPY_COLUMN: V.CopyColumn;
          IDM_COPY_XPATH: V.CopyXPath;
          IDM_SHOW_SAME: V.ShowSameSiblings;
          IDM_FILTERS: begin V.FFilterVisible := not V.FFilterVisible; V.Layout; end;
          IDM_EDIT_MODE:
            begin
              V.CloseCellEdit(True);
              V.FEditMode := not V.FEditMode;
              V.UpdateEditStatus;
            end;
          IDM_SAVE: V.SaveChanges;
          IDM_HIDE_COLUMN: V.HideColumn(V.FCurrentColumn);
          IDM_SHOW_COLUMNS: V.ShowAllColumns;
          IDM_DARK_THEME: begin V.FDark := not V.FDark; V.ApplyTheme; end;
          IDM_FORMAT: begin V.FFormatText := not V.FFormatText; V.UpdateText(V.SelectedNode); end;
          IDM_LOCATE: V.LocateText;
          IDM_SELECT_ALL: SendMessageW(V.FText, EM_SETSEL, 0, -1);
        end;
        Exit(0);
      end;
    WM_CTLCOLOREDIT:
      if Assigned(V) then
      begin
        SetTextColor(HDC(WParam), V.FFilterTextColor);
        SetBkColor(HDC(WParam), V.FFilterBackColor);
        Exit(LRESULT(V.FFilterBrush));
      end;
    WM_CLOSE:
      if Assigned(V) then
      begin
        if V.ConfirmClose then DestroyWindow(Wnd);
        Exit(0);
      end;
    WM_NCDESTROY:
      begin
        SetWindowLongPtrW(Wnd, GWLP_USERDATA, 0);
        if Assigned(V) then V.Free;
      end;
  end;
  Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function TreeWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TXmlViewer;
  Hit: TVHitTestInfo;
  Item: HTREEITEM;
begin
  V := ViewerFromWnd(GetParent(Wnd));
  if Assigned(V) then
  begin
    if (Msg = WM_KEYDOWN) and V.HandleHotKey(WParam) then Exit(0);
    if (Msg = TVM_EXPAND) and ((WParam and TVE_EXPAND) <> 0) then
      V.ExpandTreeItem(HTREEITEM(LParam))
    else if Msg = WM_LBUTTONDOWN then
    begin
      FillChar(Hit, SizeOf(Hit), 0);
      Hit.pt.X := SmallInt(LoWord(LParam));
      Hit.pt.Y := SmallInt(HiWord(LParam));
      Item := TreeView_HitTest(Wnd, Hit);
      if (Item <> nil) and ((Hit.flags and TVHT_ONITEMBUTTON) <> 0) then
        V.ExpandTreeItem(Item);
    end
    else if (Msg = WM_KEYDOWN) and
      ((WParam = VK_RIGHT) or (WParam = VK_ADD)) then
    begin
      Item := TreeView_GetSelection(Wnd);
      if Item <> nil then V.ExpandTreeItem(Item);
    end;
  end;
  if Assigned(V) and Assigned(V.FTreeOldProc) then
    Result := CallWindowProcW(V.FTreeOldProc, Wnd, Msg, WParam, LParam)
  else Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function TabWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TXmlViewer;
  Cmd: Integer;
begin
  V := ViewerFromWnd(GetParent(Wnd));
  if Assigned(V) and (Msg = WM_NOTIFY) then
    Exit(SendMessageW(V.FWnd, WM_NOTIFY, WParam, LParam));
  if Assigned(V) and (Msg = WM_CTLCOLOREDIT) then
  begin
    SetTextColor(HDC(WParam), V.FFilterTextColor);
    SetBkColor(HDC(WParam), V.FFilterBackColor);
    Exit(LRESULT(V.FFilterBrush));
  end;
  if Assigned(V) and (Msg = WM_KEYDOWN) and V.HandleHotKey(WParam) then Exit(0);
  if Assigned(V) and (Msg = WM_COMMAND) then
  begin
    Cmd := LoWord(WParam);
    if (Cmd >= IDC_FILTER_BASE) and
      (Cmd < IDC_FILTER_BASE + Length(V.FFilterEdits)) and
      (HiWord(WParam) = EN_CHANGE) then
    begin
      V.ApplyFilters;
      Exit(0);
    end;
  end;
  if Assigned(V) and Assigned(V.FTabOldProc) then
    Result := CallWindowProcW(V.FTabOldProc, Wnd, Msg, WParam, LParam)
  else Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function ChildWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  V: TXmlViewer;
  OldProc: WNDPROC;
  N: PNMHDR;
begin
  V := ViewerFromWnd(GetParent(GetParent(Wnd)));
  if not Assigned(V) then V := ViewerFromWnd(GetParent(Wnd));
  if Assigned(V) and (Wnd = V.FGrid) and (Msg = WM_NOTIFY) then
  begin
    N := PNMHDR(LParam);
    if (N^.hwndFrom = ListView_GetHeader(V.FGrid)) and
      (Integer(N^.code) = NM_CUSTOMDRAW) then
      Exit(SendMessageW(V.FWnd, WM_NOTIFY, WParam, LParam));
  end;
  if Assigned(V) and (Msg = WM_KEYDOWN) and V.HandleHotKey(WParam) then Exit(0);
  if Assigned(V) and (Wnd = V.FGrid) and
    ((Msg = WM_HSCROLL) or (Msg = WM_MOUSEWHEEL)) then V.LayoutFilters;
  OldProc := nil;
  if Assigned(V) then
  begin
    if Wnd = V.FGrid then OldProc := V.FGridOldProc
    else if Wnd = V.FText then OldProc := V.FTextOldProc;
  end;
  if Assigned(OldProc) then Result := CallWindowProcW(OldProc, Wnd, Msg, WParam, LParam)
  else Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
  if Assigned(V) and (Wnd = V.FText) and
    ((Msg = WM_VSCROLL) or (Msg = WM_MOUSEWHEEL) or (Msg = WM_SIZE)) then
    V.HighlightVisibleText;
end;

function FilterWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM;
  LParam: LPARAM): LRESULT; stdcall;
var
  V: TXmlViewer;
begin
  V := ViewerFromWnd(GetParent(GetParent(Wnd)));
  if Assigned(V) and (Msg = WM_KEYDOWN) then
  begin
    if WParam = VK_ESCAPE then
    begin
      SetFocus(V.FGrid);
      Exit(0);
    end;
    if V.HandleHotKey(WParam) then Exit(0);
  end;
  if Assigned(V) and Assigned(V.FFilterOldProc) then
    Result := CallWindowProcW(V.FFilterOldProc, Wnd, Msg, WParam, LParam)
  else
    Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

function EditorWndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM;
  LParam: LPARAM): LRESULT; stdcall;
var
  V: TXmlViewer;
begin
  V := ViewerFromWnd(GetParent(GetParent(GetParent(Wnd))));
  if Assigned(V) then
  begin
    if Msg = WM_KEYDOWN then
    begin
      if WParam = VK_RETURN then begin V.CloseCellEdit(True); Exit(0); end;
      if WParam = VK_ESCAPE then begin V.CloseCellEdit(False); Exit(0); end;
    end;
    if Msg = WM_KILLFOCUS then V.CloseCellEdit(True);
  end;
  if Assigned(V) and Assigned(V.FEditorOldProc) then
    Result := CallWindowProcW(V.FEditorOldProc, Wnd, Msg, WParam, LParam)
  else Result := DefWindowProcW(Wnd, Msg, WParam, LParam);
end;

procedure RegisterViewerClass;
var
  WC: WNDCLASSEXW;
begin
  if ViewerClass <> 0 then Exit;
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize := SizeOf(WC);
  WC.lpfnWndProc := @MainWndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := COLOR_WINDOW + 1;
  WC.lpszClassName := 'XmlTabPascalViewer';
  ViewerClass := RegisterClassExW(WC);
end;

constructor TXmlViewer.Create(ParentWin: HWND; const FileName: UnicodeString);
var
  Init: TInitCommonControlsEx;
  T: TCItemW;
  MaxSize, GridStyles: Integer;
  ParentRect: TRect;
  StatusParts: array[0..4] of Integer;
begin
  inherited Create;
  FFileName := FileName;
  MaxSize := ReadSettingInt('max-file-size', 100000000);
  if not LoadXmlFile(FileName, MaxSize, FDoc, FEncoding) then
    raise Exception.Create('Cannot parse XML');
  if not LoadXmlSourceText(FileName, MaxSize, FSourceText) then
    FSourceText := FEncoding.SourceText;
  FSourceMapReady := False;
  FTextDirty := True;
  FSplitter := ReadSettingInt('splitter-position', 200);
  if FSplitter < 110 then FSplitter := 200;
  FDragging := False;
  FFontSize := ReadSettingInt('font-size', -14);
  if FFontSize > -10 then FFontSize := -14;
  FDark := ReadSettingInt('dark-theme', 0) <> 0;
  FFilterVisible := ReadSettingInt('filter-row', 1) <> 0;
  FFormatText := ReadSettingInt('format-text', 1) <> 0;
  FDecimalAlign := ReadSettingInt('decimal-align', 1) <> 0;
  FEditMode := False;
  FDirty := False;
  FCellEditor := 0;
  FFilterOldProc := nil;
  FSortColumn := -1;
  FCurrentRow := 0;
  FCurrentColumn := 0;
  FSearchText := '';
  FSearchFlags := 0;
  FSearchRow := 0;
  FSearchColumn := 0;
  FSearchCellPos := 1;
  LoadLibraryW('Msftedit.dll');
  Init.dwSize := SizeOf(Init);
  Init.dwICC := ICC_TREEVIEW_CLASSES or ICC_LISTVIEW_CLASSES or ICC_TAB_CLASSES or ICC_BAR_CLASSES;
  InitCommonControlsEx(Init);
  RegisterViewerClass;
  GetClientRect(ParentWin, ParentRect);
  FWnd := CreateWindowExW(WS_EX_CONTROLPARENT, 'XmlTabPascalViewer', 'xmltab',
    WS_CHILD or WS_VISIBLE or WS_CLIPCHILDREN or WS_CLIPSIBLINGS, 0, 0,
    ParentRect.Right - ParentRect.Left, ParentRect.Bottom - ParentRect.Top,
    ParentWin, 0, HInstance, nil);
  if FWnd = 0 then raise Exception.Create('Cannot create viewer');
  SetWindowLongPtrW(FWnd, GWLP_USERDATA, PtrInt(Self));
  FTree := CreateWindowExW(0, WC_TREEVIEWW, nil, WS_CHILD or WS_VISIBLE or
    TVS_HASBUTTONS or TVS_HASLINES or TVS_SHOWSELALWAYS, 0, 0, 100, 100,
    FWnd, IDC_TREE, HInstance, nil);
  FTreeOldProc := WNDPROC(SetWindowLongPtrW(FTree, GWLP_WNDPROC, PtrInt(@TreeWndProc)));
  FTab := CreateWindowExW(0, WC_TABCONTROLW, nil, WS_CHILD or WS_VISIBLE,
    0, 0, 100, 100, FWnd, IDC_TAB, HInstance, nil);
  FTabOldProc := WNDPROC(SetWindowLongPtrW(FTab, GWLP_WNDPROC, PtrInt(@TabWndProc)));
  FillChar(T, SizeOf(T), 0); T.mask := TCIF_TEXT; T.pszText := 'Grid';
  SendMessageW(FTab, TCM_INSERTITEMW, 0, LPARAM(@T));
  T.pszText := 'Text';
  SendMessageW(FTab, TCM_INSERTITEMW, 1, LPARAM(@T));
  TabCtrl_SetCurSel(FTab, 0);
  FGrid := CreateWindowExW(0, WC_LISTVIEWW, nil, WS_CHILD or WS_VISIBLE or
    LVS_REPORT or LVS_OWNERDATA or LVS_SHOWSELALWAYS, 0, 0, 100, 100,
    FTab, IDC_GRID, HInstance, nil);
  FGridOldProc := WNDPROC(SetWindowLongPtrW(FGrid, GWLP_WNDPROC, PtrInt(@ChildWndProc)));
  GridStyles := LVS_EX_FULLROWSELECT or LVS_EX_DOUBLEBUFFER or LVS_EX_HEADERDRAGDROP;
  if ReadSettingInt('disable-grid-lines', 0) = 0 then
    GridStyles := GridStyles or LVS_EX_GRIDLINES;
  ListView_SetExtendedListViewStyle(FGrid, GridStyles);
  FText := CreateWindowExW(WS_EX_CLIENTEDGE, 'RICHEDIT50W', nil, WS_CHILD or
    ES_MULTILINE or ES_AUTOVSCROLL or ES_AUTOHSCROLL or WS_VSCROLL or
    WS_HSCROLL or ES_READONLY, 0, 0, 100, 100, FTab, IDC_TEXT, HInstance, nil);
  FTextOldProc := WNDPROC(SetWindowLongPtrW(FText, GWLP_WNDPROC, PtrInt(@ChildWndProc)));
  FStatus := CreateStatusWindowW(WS_CHILD or WS_VISIBLE, nil, FWnd, IDC_STATUS);
  StatusParts[0] := 70;
  StatusParts[1] := 135;
  StatusParts[2] := 300;
  StatusParts[3] := 365;
  StatusParts[4] := -1;
  SendMessageW(FStatus, SB_SETPARTS, 5, LPARAM(@StatusParts[0]));
  FFont := CreateFontW(FFontSize, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
    DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI');
  FHeaderFont := CreateFontW(FFontSize, 0, 0, 0, FW_BOLD, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
    DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI');
  SendMessageW(FTree, WM_SETFONT, FFont, 1);
  SendMessageW(FGrid, WM_SETFONT, FFont, 1);
  SendMessageW(ListView_GetHeader(FGrid), WM_SETFONT, FHeaderFont, 1);
  SendMessageW(FText, WM_SETFONT, FFont, 1);
  SendMessageW(FTab, WM_SETFONT, FFont, 1);
  SendMessageW(FStatus, WM_SETFONT, FFont, 1);
  ShowWindow(FGrid, SW_SHOW);
  ShowWindow(FText, SW_HIDE);
  ApplyTheme;
  BuildTree;
  UpdateSelection;
  Layout;
  ShowWindow(FGrid, SW_SHOW);
  ShowWindow(FText, SW_HIDE);
  InvalidateRect(FTree, nil, True);
  InvalidateRect(FGrid, nil, True);
  SetFocus(FTree);
end;

destructor TXmlViewer.Destroy;
var
  I: Integer;
begin
  CloseCellEdit(False);
  if FSplitter >= 110 then WriteSettingInt('splitter-position', FSplitter);
  WriteSettingInt('font-size', FFontSize);
  WriteSettingInt('dark-theme', Ord(FDark));
  WriteSettingInt('filter-row', Ord(FFilterVisible));
  WriteSettingInt('format-text', Ord(FFormatText));
  for I := 0 to High(FFilterEdits) do
    if IsWindow(FFilterEdits[I]) then DestroyWindow(FFilterEdits[I]);
  if FFilterBrush <> 0 then DeleteObject(FFilterBrush);
  if FHeaderFont <> 0 then DeleteObject(FHeaderFont);
  if FFont <> 0 then DeleteObject(FFont);
  FDoc.Free;
  inherited Destroy;
end;

function TXmlViewer.AddNode(Parent: HTREEITEM; Node: TDOMNode): HTREEITEM;
var
  Ins: TVInsertStructW;
  Child: TDOMNode;
  I: Integer;
  Caption: UnicodeString;
begin
  I := Length(FNodes); SetLength(FNodes, I + 1); FNodes[I] := Node;
  Caption := XmlNodeCaption(Node);
  if Node.NodeType = DOCUMENT_NODE then
    Caption := '?xml version="' + UnicodeString(FDoc.XMLVersion) +
      '" encoding="' + FEncoding.Name + '"?';
  FillChar(Ins, SizeOf(Ins), 0);
  Ins.hParent := Parent; Ins.hInsertAfter := TVI_LAST;
  Ins.item.mask := TVIF_TEXT or TVIF_PARAM or TVIF_CHILDREN;
  Ins.item.pszText := PWideChar(Caption); Ins.item.lParam := I;
  Ins.item.cChildren := Ord(Assigned(FirstVisibleChild(Node)));
  Result := HTREEITEM(SendMessageW(FTree, TVM_INSERTITEMW, 0, LPARAM(@Ins)));
end;

procedure TXmlViewer.ExpandTreeItem(Item: HTREEITEM);
var
  TV: TVItemW;
  Node: TDOMNode;
begin
  if TreeView_GetChild(FTree, Item) <> nil then Exit;
  FillChar(TV, SizeOf(TV), 0);
  TV.mask := TVIF_PARAM; TV.hItem := Item;
  if (SendMessageW(FTree, TVM_GETITEMW, 0, LPARAM(@TV)) = 0) or
    (TV.lParam < 0) or (TV.lParam >= Length(FNodes)) then Exit;
  Node := FNodes[TV.lParam];
  AddChildren(Item, Node);
end;

procedure TXmlViewer.AddChildren(Item: HTREEITEM; Node: TDOMNode);
var
  Child: TDOMNode;
begin
  if TreeView_GetChild(FTree, Item) <> nil then Exit;
  Child := FirstVisibleChild(Node);
  while Assigned(Child) do
  begin
    AddNode(Item, Child);
    Child := NextVisibleSibling(Child);
  end;
end;

procedure TXmlViewer.BuildTree;
var
  Root, ElementItem: HTREEITEM;
begin
  SetLength(FNodes, 0);
  Root := AddNode(nil, FDoc);
  AddChildren(Root, FDoc);
  TreeView_Expand(FTree, Root, TVE_EXPAND);
  ElementItem := TreeView_GetChild(FTree, Root);
  while ElementItem <> nil do
  begin
    if (TreeItemParam(FTree, ElementItem) >= 0) and
      (FNodes[TreeItemParam(FTree, ElementItem)].NodeType = ELEMENT_NODE) then Break;
    ElementItem := TreeView_GetNextSibling(FTree, ElementItem);
  end;
  if ElementItem <> nil then
  begin
    TreeView_SelectItem(FTree, ElementItem);
    ExpandTreeItem(ElementItem);
    TreeView_Expand(FTree, ElementItem, TVE_EXPAND);
  end
  else TreeView_SelectItem(FTree, Root);
end;

function TXmlViewer.SelectedNode: TDOMNode;
var
  TV: TVItemW;
begin
  Result := nil; FillChar(TV, SizeOf(TV), 0);
  TV.mask := TVIF_PARAM; TV.hItem := TreeView_GetSelection(FTree);
  if (TV.hItem <> nil) and (SendMessageW(FTree, TVM_GETITEMW, 0, LPARAM(@TV)) <> 0) and
    (TV.lParam >= 0) and (TV.lParam < Length(FNodes)) then Result := FNodes[TV.lParam];
end;

function TXmlViewer.FindTreeItem(Node: TDOMNode): HTREEITEM;
var
  Item: HTREEITEM;
  P: LPARAM;
begin
  Result := nil;
  Item := TreeView_GetRoot(FTree);
  while Item <> nil do
  begin
    P := TreeItemParam(FTree, Item);
    if (P >= 0) and (P < Length(FNodes)) and (FNodes[P] = Node) then Exit(Item);
    Item := TreeView_GetNextItem(FTree, Item, TVGN_NEXTVISIBLE);
  end;
end;

procedure TXmlViewer.SelectTreeNode(Node: TDOMNode);
var
  ParentItem, Item: HTREEITEM;
begin
  if not Assigned(Node) then Exit;
  if Node.NodeType = ATTRIBUTE_NODE then Node := TDOMAttr(Node).OwnerElement;
  if not Assigned(Node) then Exit;
  if Assigned(Node.ParentNode) then SelectTreeNode(Node.ParentNode);
  Item := FindTreeItem(Node);
  if Item = nil then
  begin
    ParentItem := FindTreeItem(Node.ParentNode);
    if ParentItem <> nil then
    begin
      ExpandTreeItem(ParentItem);
      TreeView_Expand(FTree, ParentItem, TVE_EXPAND);
      Item := FindTreeItem(Node);
    end;
  end;
  if Item <> nil then
  begin
    TreeView_SelectItem(FTree, Item);
    TreeView_EnsureVisible(FTree, Item);
  end;
end;

procedure TXmlViewer.NavigateGridRowToTree(Row: Integer);
var
  SourceRow: Integer;
begin
  if (Row < 0) or (Row >= Length(FVisibleRows)) then Exit;
  SourceRow := FVisibleRows[Row];
  if (SourceRow >= 0) and (SourceRow < Length(FRowNodes)) then
  begin
    FSelectingTree := True;
    try
      SelectTreeNode(FRowNodes[SourceRow]);
    finally
      FSelectingTree := False;
    end;
    UpdateSelection;
    SetFocus(FTree);
  end;
end;

procedure TXmlViewer.ShowSameSiblings;
var
  Node: TDOMNode;
  Item: HTREEITEM;
begin
  Node := SelectedNode;
  if not Assigned(Node) or not Assigned(Node.ParentNode) or
    (Node.NodeType <> ELEMENT_NODE) then Exit;
  FSameName := UnicodeString(Node.NodeName);
  Item := FindTreeItem(Node.ParentNode);
  if Item <> nil then TreeView_SelectItem(FTree, Item);
end;

procedure TXmlViewer.CopyXPath;
var
  Row, SourceRow: Integer;
  Node: TDOMNode;
begin
  Node := nil;
  if GetFocus = FGrid then
  begin
    Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
    if (Row >= 0) and (Row < Length(FVisibleRows)) then
    begin
      SourceRow := FVisibleRows[Row];
      if (SourceRow >= 0) and (SourceRow < Length(FRowNodes)) then
        Node := FRowNodes[SourceRow];
    end;
  end;
  if not Assigned(Node) then Node := SelectedNode;
  if Assigned(Node) then SetClipboardText(XmlNodePath(Node));
end;

procedure TXmlViewer.CopySelectedCell;
var
  Row, SourceRow: Integer;
begin
  if GetFocus = FText then begin SendMessageW(FText, WM_COPY, 0, 0); Exit; end;
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  if (Row < 0) or (Row >= Length(FVisibleRows)) then Exit;
  SourceRow := FVisibleRows[Row];
  if (SourceRow >= 0) and (SourceRow < Length(FRows)) and
    (FCurrentColumn >= 0) and (FCurrentColumn < Length(FRows[SourceRow])) then
    SetClipboardText(FRows[SourceRow][FCurrentColumn]);
end;

procedure TXmlViewer.CopySelectedColumn;
var
  Row, SourceRow: Integer;
  S: UnicodeString;
begin
  if FCurrentColumn < 0 then Exit;
  S := '';
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  while Row >= 0 do
  begin
    SourceRow := FVisibleRows[Row];
    if FCurrentColumn < Length(FRows[SourceRow]) then
      S := S + FRows[SourceRow][FCurrentColumn] + #13#10;
    Row := ListView_GetNextItem(FGrid, Row, LVNI_SELECTED);
  end;
  if S <> '' then SetClipboardText(S);
end;

procedure TXmlViewer.CopyRows;
var
  Row, SourceRow, C: Integer;
  S, Delimiter: UnicodeString;
begin
  S := '';
  Delimiter := ReadSetting('column-delimiter', #9);
  if Delimiter = '' then Delimiter := #9
  else Delimiter := Delimiter[1];
  Row := ListView_GetNextItem(FGrid, -1, LVNI_SELECTED);
  while Row >= 0 do
  begin
    SourceRow := FVisibleRows[Row];
    for C := 0 to High(FRows[SourceRow]) do
    begin
      if C > 0 then S := S + Delimiter;
      S := S + FRows[SourceRow][C];
    end;
    S := S + #13#10;
    Row := ListView_GetNextItem(FGrid, Row, LVNI_SELECTED);
  end;
  if S <> '' then SetClipboardText(S);
end;

procedure TXmlViewer.CopyColumn;
var
  Row, SourceRow: Integer;
  S: UnicodeString;
begin
  if FCurrentColumn < 0 then Exit;
  S := '';
  for Row := 0 to High(FVisibleRows) do
  begin
    SourceRow := FVisibleRows[Row];
    if FCurrentColumn < Length(FRows[SourceRow]) then
      S := S + FRows[SourceRow][FCurrentColumn] + #13#10;
  end;
  if S <> '' then SetClipboardText(S);
end;

procedure TXmlViewer.HideColumn(Column: Integer);
begin
  if (Column < 0) or
    (Column >= Header_GetItemCount(ListView_GetHeader(FGrid))) then Exit;
  ListView_SetColumnWidth(FGrid, Column, 0);
  LayoutFilters;
end;

procedure TXmlViewer.ShowAllColumns;
var
  I: Integer;
begin
  for I := 0 to Header_GetItemCount(ListView_GetHeader(FGrid)) - 1 do
    ListView_SetColumnWidth(FGrid, I, 1);
  AutoSizeColumns;
end;

procedure TXmlViewer.LocateText;
var
  StartPos, EndPos, I: Integer;
  Needle, Text: UnicodeString;
  Node: TDOMNode;
begin
  SendMessageW(FText, EM_GETSEL, WPARAM(@StartPos), LPARAM(@EndPos));
  if FFormatText and FTextSourceMapped then
  begin
    Node := FindNodeAt(FNodeSpans, SourcePositionAtTextCursor(StartPos));
    if Assigned(Node) then
    begin
      FSelectingTree := True;
      try
        SelectTreeNode(Node);
      finally
        FSelectingTree := False;
      end;
      UpdateSelection;
      Exit;
    end;
  end;
  if EndPos > StartPos then
  begin
    SetLength(Needle, EndPos - StartPos);
    SendMessageW(FText, EM_GETSELTEXT, 0, LPARAM(PWideChar(Needle)));
    for I := High(FNodes) downto 0 do
    begin
      Text := XmlNodeText(FNodes[I]);
      if Pos(Needle, Text) > 0 then
      begin
        SelectTreeNode(FNodes[I]);
        Exit;
      end;
    end;
  end
  else
  begin
    MessageBeep(MB_ICONWARNING);
    Exit;
  end;
  MessageBeep(MB_ICONWARNING);
end;

function TXmlViewer.SourcePositionAtTextCursor(TextPosition: Integer): Integer;
begin
  if Length(FTextDisplayToSource) = 0 then Exit(FTextSourceStart);
  if TextPosition < 0 then TextPosition := 0;
  if TextPosition >= Length(FTextDisplayToSource) then
    TextPosition := High(FTextDisplayToSource);
  Result := FTextDisplayToSource[TextPosition];
end;

function TXmlViewer.FindSourceRange(Node: TDOMNode;
  out StartPos, EndPos: Integer): Boolean;
var
  I: Integer;
  Path: UnicodeString;
begin
  EnsureSourceMap;
  if FindNodeSpan(FNodeSpans, Node, StartPos, EndPos) then Exit(True);
  Path := XmlNodePath(Node);
  for I := 0 to High(FNodeSpans) do
    if Assigned(FNodeSpans[I].Node) and
      (FNodeSpans[I].Node.NodeType = Node.NodeType) and
      (XmlNodePath(FNodeSpans[I].Node) = Path) then
    begin
      StartPos := FNodeSpans[I].StartPos;
      EndPos := FNodeSpans[I].EndPos;
      Exit(True);
    end;
  StartPos := 0;
  EndPos := 0;
  Result := False;
end;

procedure TXmlViewer.EnsureSourceMap;
begin
  if FSourceMapReady then Exit;
  BuildXmlSourceMap(FSourceText, FDoc, FSyntaxSpans, FNodeSpans);
  FSourceMapReady := True;
end;

procedure AddColumn(Grid: HWND; Index: Integer; const Caption: UnicodeString);
var
  Col: LVCOLUMNW;
begin
  FillChar(Col, SizeOf(Col), 0); Col.mask := LVCF_TEXT or LVCF_WIDTH;
  Col.pszText := PWideChar(Caption); Col.cx := 100;
  SendMessageW(Grid, LVM_INSERTCOLUMNW, Index, LPARAM(@Col));
end;

procedure TXmlViewer.BuildGrid(Node: TDOMNode);
var
  C, R, I, J: Integer;
  Child, N: TDOMNode;
  Names: TStringList;
  Row: array of UnicodeString;
  RefRow: TXmlCellRefRow;
begin
  ListView_SetItemCount(FGrid, 0);
  while Header_GetItemCount(ListView_GetHeader(FGrid)) > 0 do ListView_DeleteColumn(FGrid, 0);
  SetLength(FRows, 0); SetLength(FCellRefs, 0); SetLength(FRowNodes, 0);
  SetLength(FVisibleRows, 0);
  if not Assigned(Node) then Exit;
  Names := TStringList.Create;
  try
    Child := Node.FirstChild;
    while Assigned(Child) do
    begin
      if (Child.NodeType = ELEMENT_NODE) and
        ((FSameName = '') or (UnicodeString(Child.NodeName) = FSameName)) then
      begin
        if Child.HasAttributes then for I := 0 to Child.Attributes.Length - 1 do
          if Names.IndexOf('@' + Child.Attributes.Item[I].NodeName) < 0 then Names.Add('@' + Child.Attributes.Item[I].NodeName);
        N := Child.FirstChild;
        while Assigned(N) do begin if (N.NodeType = ELEMENT_NODE) and (Names.IndexOf(N.NodeName) < 0) then Names.Add(N.NodeName); N := N.NextSibling; end;
      end;
      Child := Child.NextSibling;
    end;
    if Names.Count > 0 then
    begin
      if FSameName <> '' then FGridMode := 'SAME'
      else FGridMode := 'TABLE';
      for C := 0 to Names.Count - 1 do AddColumn(FGrid, C, UnicodeString(Names[C]));
      Child := Node.FirstChild;
      while Assigned(Child) do
      begin
        if (Child.NodeType = ELEMENT_NODE) and
          ((FSameName = '') or (UnicodeString(Child.NodeName) = FSameName)) then
        begin
          SetLength(Row, Names.Count);
          SetLength(RefRow, Names.Count);
          for C := 0 to Names.Count - 1 do
          begin
            Row[C] := '';
            RefRow[C].Kind := xckReadOnly;
            RefRow[C].Node := nil;
          end;
          for C := 0 to Names.Count - 1 do
            if Names[C][1] = '@' then
            begin
              N := Child.Attributes.GetNamedItem(Copy(Names[C], 2, MaxInt));
              if Assigned(N) then begin Row[C] := UnicodeString(N.NodeValue); RefRow[C] := EditableCell(N); end;
            end
            else
            begin
              N := Child.FindNode(Names[C]);
              if Assigned(N) then begin Row[C] := UnicodeString(N.TextContent); RefRow[C] := EditableCell(N); end;
            end;
          R := Length(FRows); SetLength(FRows, R + 1); FRows[R] := Copy(Row);
          SetLength(FCellRefs, R + 1); FCellRefs[R] := Copy(RefRow);
          SetLength(FRowNodes, R + 1); FRowNodes[R] := Child;
        end;
        Child := Child.NextSibling;
      end;
    end
    else
    begin
      if FSameName <> '' then FGridMode := 'SAME'
      else FGridMode := 'SINGLE';
      AddColumn(FGrid, 0, 'Key'); AddColumn(FGrid, 1, 'Value');
      if Node.HasAttributes then for I := 0 to Node.Attributes.Length - 1 do
      begin
        R := Length(FRows); SetLength(FRows, R + 1); SetLength(FRows[R], 2);
        FRows[R][0] := '@' + UnicodeString(Node.Attributes.Item[I].NodeName);
        FRows[R][1] := UnicodeString(Node.Attributes.Item[I].NodeValue);
        SetLength(FCellRefs, R + 1); SetLength(FCellRefs[R], 2);
        FCellRefs[R][1] := EditableCell(Node.Attributes.Item[I]);
        SetLength(FRowNodes, R + 1); FRowNodes[R] := Node.Attributes.Item[I];
      end;
      Child := Node.FirstChild;
      while Assigned(Child) do
      begin
        R := Length(FRows); SetLength(FRows, R + 1); SetLength(FRows[R], 2);
        FRows[R][0] := XmlNodeCaption(Child); FRows[R][1] := XmlNodeValue(Child);
        SetLength(FCellRefs, R + 1); SetLength(FCellRefs[R], 2);
        FCellRefs[R][1] := EditableCell(Child);
        SetLength(FRowNodes, R + 1); FRowNodes[R] := Child; Child := Child.NextSibling;
      end;
    end;
    CreateFilterEdits;
    ApplyFilters;
    FSameName := '';
  finally Names.Free; end;
end;

procedure TXmlViewer.UpdateSelection;
var
  N: TDOMNode;
begin
  N := SelectedNode;
  BuildGrid(N);
  FTextDirty := True;
  if IsWindowVisible(FText) then UpdateText(N);
  UpdateStatus;
end;

procedure TXmlViewer.UpdateStatus;
var
  S: UnicodeString;
begin
  S := ' ' + FEncoding.Name;
  SendMessageW(FStatus, SB_SETTEXTW, 0, LPARAM(PWideChar(S)));
  S := ' ' + FGridMode;
  SendMessageW(FStatus, SB_SETTEXTW, 1, LPARAM(PWideChar(S)));
  S := Format(' Rows: %d/%d', [Length(FVisibleRows), Length(FRows)]);
  SendMessageW(FStatus, SB_SETTEXTW, 2, LPARAM(PWideChar(S)));
  UpdatePositionStatus;
  UpdateEditStatus;
end;

procedure TXmlViewer.UpdatePositionStatus;
var
  S: UnicodeString;
begin
  if (FCurrentRow >= 0) and (FCurrentRow < Length(FVisibleRows)) and
    (FCurrentColumn >= 0) and
    (FCurrentColumn < Header_GetItemCount(ListView_GetHeader(FGrid))) then
    S := Format(' %d:%d', [FCurrentRow + 1, FCurrentColumn + 1])
  else
    S := '';
  SendMessageW(FStatus, SB_SETTEXTW, 3, LPARAM(PWideChar(S)));
end;

procedure TXmlViewer.CreateFilterEdits;
var
  I, Count, Align, EditStyle: Integer;
begin
  for I := 0 to High(FFilterEdits) do
    if IsWindow(FFilterEdits[I]) then DestroyWindow(FFilterEdits[I]);
  Count := Header_GetItemCount(ListView_GetHeader(FGrid));
  SetLength(FFilterEdits, Count);
  Align := ReadSettingInt('filter-align', 0);
  if Align < 0 then EditStyle := ES_LEFT
  else if Align > 0 then EditStyle := ES_RIGHT
  else EditStyle := ES_CENTER;
  for I := 0 to Count - 1 do
  begin
    FFilterEdits[I] := CreateWindowExW(WS_EX_CLIENTEDGE, 'EDIT', nil,
      WS_CHILD or WS_VISIBLE or WS_TABSTOP or ES_AUTOHSCROLL or EditStyle,
      0, 0, 10, 22, FTab, IDC_FILTER_BASE + I, HInstance, nil);
    if not Assigned(FFilterOldProc) then
      FFilterOldProc := WNDPROC(SetWindowLongPtrW(FFilterEdits[I],
        GWLP_WNDPROC, PtrInt(@FilterWndProc)))
    else
      SetWindowLongPtrW(FFilterEdits[I], GWLP_WNDPROC, PtrInt(@FilterWndProc));
    SendMessageW(FFilterEdits[I], WM_SETFONT, FFont, 1);
  end;
  LayoutFilters;
end;

procedure TXmlViewer.LayoutFilters;
var
  I, X, W: Integer;
  Visible: Boolean;
begin
  if not IsWindow(FGrid) then Exit;
  X := 3;
  Visible := FFilterVisible and (TabCtrl_GetCurSel(FTab) = 0);
  for I := 0 to High(FFilterEdits) do
  begin
    W := ListView_GetColumnWidth(FGrid, I);
    MoveWindow(FFilterEdits[I], X, 26, W, 23, True);
    if Visible and (W > 0) then ShowWindow(FFilterEdits[I], SW_SHOW)
    else ShowWindow(FFilterEdits[I], SW_HIDE);
    InvalidateRect(FFilterEdits[I], nil, True);
    Inc(X, W);
  end;
end;

procedure TXmlViewer.ApplyFilters;
var
  I, J, N: Integer;
  Filters: array of UnicodeString;
  Buf: array[0..4095] of WideChar;
  Match, CaseSensitive: Boolean;
begin
  CloseCellEdit(True);
  FSearchText := '';
  SetLength(Filters, Length(FFilterEdits));
  for J := 0 to High(FFilterEdits) do
  begin
    Buf[0] := #0;
    GetWindowTextW(FFilterEdits[J], Buf, Length(Buf));
    Filters[J] := Buf;
  end;
  CaseSensitive := ReadSettingInt('filter-case-sensitive', 0) <> 0;
  SetLength(FVisibleRows, Length(FRows));
  N := 0;
  for I := 0 to High(FRows) do
  begin
    Match := True;
    for J := 0 to High(Filters) do
      Match := Match and MatchesFilter(FRows[I][J], Filters[J], CaseSensitive);
    if Match then begin FVisibleRows[N] := I; Inc(N); end;
  end;
  SetLength(FVisibleRows, N);
  ListView_SetItemCount(FGrid, N);
  UpdateDecimalAnchors;
  InvalidateRect(FGrid, nil, True);
  AutoSizeColumns;
  UpdateStatus;
end;

procedure TXmlViewer.ApplyTheme;
var
  ActiveTab: Integer;
  CF: CHARFORMAT2W;
begin
  ActiveTab := TabCtrl_GetCurSel(FTab);
  if FDark then
  begin
    FTextColor := ReadSettingInt('text-color-dark', RGB(220, 220, 220));
    FBackColor := ReadSettingInt('back-color-dark', RGB(32, 32, 32));
    FBackColor2 := ReadSettingInt('back-color2-dark', RGB(52, 52, 52));
    FHeaderTextColor := ReadSettingInt('header-text-color-dark', RGB(255, 255, 255));
    FHeaderBackColor := ReadSettingInt('header-back-color-dark', RGB(64, 64, 64));
    FFilterTextColor := ReadSettingInt('filter-text-color-dark', RGB(255, 255, 255));
    FFilterBackColor := ReadSettingInt('filter-back-color-dark', RGB(60, 60, 60));
    FCurrentCellColor := ReadSettingInt('current-cell-back-color-dark', RGB(32, 62, 62));
    FSelectionTextColor := ReadSettingInt('selection-text-color-dark', RGB(220, 220, 220));
    FSelectionBackColor := ReadSettingInt('selection-back-color-dark', RGB(72, 102, 102));
    FSplitterColor := ReadSettingInt('splitter-color-dark', RGB(64, 64, 64));
  end
  else
  begin
    FTextColor := ReadSettingInt('text-color', RGB(0, 0, 0));
    FBackColor := ReadSettingInt('back-color', RGB(255, 255, 255));
    FBackColor2 := ReadSettingInt('back-color2', RGB(240, 240, 240));
    FHeaderTextColor := ReadSettingInt('header-text-color', RGB(0, 0, 0));
    FHeaderBackColor := ReadSettingInt('header-back-color', RGB(220, 220, 220));
    FFilterTextColor := ReadSettingInt('filter-text-color', RGB(0, 0, 0));
    FFilterBackColor := ReadSettingInt('filter-back-color', RGB(240, 240, 240));
    FCurrentCellColor := ReadSettingInt('current-cell-back-color', RGB(70, 96, 166));
    FSelectionTextColor := ReadSettingInt('selection-text-color', RGB(255, 255, 255));
    FSelectionBackColor := ReadSettingInt('selection-back-color', RGB(10, 36, 106));
    FSplitterColor := ReadSettingInt('splitter-color', RGB(240, 240, 240));
  end;
  if FFilterBrush <> 0 then DeleteObject(FFilterBrush);
  FFilterBrush := CreateSolidBrush(FFilterBackColor);
  TreeView_SetBkColor(FTree, FBackColor);
  TreeView_SetTextColor(FTree, FTextColor);
  ListView_SetBkColor(FGrid, FBackColor);
  ListView_SetTextBkColor(FGrid, FBackColor);
  ListView_SetTextColor(FGrid, FTextColor);
  SendMessageW(FText, EM_SETBKGNDCOLOR, 0, FBackColor);
  FillChar(CF, SizeOf(CF), 0);
  CF.cbSize := SizeOf(CF);
  CF.dwMask := CFM_COLOR or CFM_BOLD;
  if FDark then CF.crTextColor := ReadSettingInt('xml-text-color-dark', RGB(220, 220, 220))
  else CF.crTextColor := ReadSettingInt('xml-text-color', RGB(0, 0, 0));
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_DEFAULT, LPARAM(@CF));
  if (ActiveTab = 1) and not FTextDirty then HighlightVisibleText;
  TabCtrl_SetCurSel(FTab, ActiveTab);
  if ActiveTab = 0 then
  begin
    ShowWindow(FGrid, SW_SHOW);
    ShowWindow(FText, SW_HIDE);
  end
  else
  begin
    ShowWindow(FGrid, SW_HIDE);
    ShowWindow(FText, SW_SHOW);
  end;
  LayoutFilters;
  RedrawWindow(ListView_GetHeader(FGrid), nil, 0,
    RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
  RedrawWindow(FGrid, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
  InvalidateRect(FTree, nil, True);
  InvalidateRect(FTab, nil, True);
  InvalidateRect(FStatus, nil, True);
  InvalidateRect(FWnd, nil, True);
end;

procedure TXmlViewer.SetFontSize(NewSize: Integer);
var
  I: Integer;
begin
  if (NewSize > -10) or (NewSize < -48) or (NewSize = FFontSize) then Exit;
  FFontSize := NewSize;
  if FFont <> 0 then DeleteObject(FFont);
  if FHeaderFont <> 0 then DeleteObject(FHeaderFont);
  FFont := CreateFontW(FFontSize, 0, 0, 0, FW_NORMAL, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
    DEFAULT_PITCH or FF_DONTCARE, PWideChar(ReadSetting('font', 'Segoe UI')));
  FHeaderFont := CreateFontW(FFontSize, 0, 0, 0, FW_BOLD, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
    DEFAULT_PITCH or FF_DONTCARE, PWideChar(ReadSetting('font', 'Segoe UI')));
  SendMessageW(FTree, WM_SETFONT, FFont, 1);
  SendMessageW(FGrid, WM_SETFONT, FFont, 1);
  SendMessageW(ListView_GetHeader(FGrid), WM_SETFONT, FHeaderFont, 1);
  SendMessageW(FText, WM_SETFONT, FFont, 1);
  for I := 0 to High(FFilterEdits) do SendMessageW(FFilterEdits[I], WM_SETFONT, FFont, 1);
  AutoSizeColumns;
  Layout;
end;

function MeasureTextWidth(DC: HDC; const S: UnicodeString): Integer;
var
  Size: TSize;
begin
  Result := 0;
  if (S = '') or not GetTextExtentPoint32W(DC, PWideChar(S), Length(S), Size) then
    Exit;
  Result := Size.cx;
end;

procedure TXmlViewer.UpdateDecimalAnchors;
var
  DC: HDC;
  OldFont: HGDIOBJ;
  Column, Row, SourceRow, Width: Integer;
  S, IntegerPart, FractionPart: UnicodeString;
  Separator: WideChar;
begin
  SetLength(FDecimalAnchors, Header_GetItemCount(ListView_GetHeader(FGrid)));
  SetLength(FDecimalColumns, Length(FDecimalAnchors));
  if not FDecimalAlign or not IsWindow(FGrid) then Exit;
  DC := GetDC(FGrid);
  if DC = 0 then Exit;
  OldFont := SelectObject(DC, FFont);
  try
    for Column := 0 to High(FDecimalAnchors) do
      for Row := 0 to High(FVisibleRows) do
      begin
        SourceRow := FVisibleRows[Row];
        if (SourceRow < 0) or (SourceRow >= Length(FRows)) or
          (Column >= Length(FRows[SourceRow])) then Continue;
        S := FRows[SourceRow][Column];
        if SplitDecimalText(S, IntegerPart, FractionPart, Separator) then
        begin
          FDecimalColumns[Column] := True;
          Width := MeasureTextWidth(DC, IntegerPart);
          if Width > FDecimalAnchors[Column] then FDecimalAnchors[Column] := Width;
        end;
        if IsIntegerText(S) then
        begin
          Width := MeasureTextWidth(DC, Trim(S));
          if Width > FDecimalAnchors[Column] then FDecimalAnchors[Column] := Width;
        end;
      end;
  finally
    SelectObject(DC, OldFont);
    ReleaseDC(FGrid, DC);
  end;
end;

function TXmlViewer.CustomDraw(Draw: PNMLVCUSTOMDRAW): LRESULT;
var
  Row, Column, SourceRow, Anchor, SavedDC: Integer;
  Selected, CurrentCell: Boolean;
  R, TextRect: TRect;
  Brush: HBRUSH;
  S, IntegerPart, FractionPart, DecimalText: UnicodeString;
  Separator: WideChar;
  OldTextColor: COLORREF;
  OldBkMode: Integer;
  OldFont: HGDIOBJ;
  Pen, OldPen: HPEN;
begin
  Result := CDRF_DODEFAULT;
  if not Assigned(Draw) then Exit;
  if Draw^.nmcd.dwDrawStage = CDDS_PREPAINT then Exit(CDRF_NOTIFYITEMDRAW);
  if Draw^.nmcd.dwDrawStage = CDDS_ITEMPREPAINT then
  begin
    Row := Integer(Draw^.nmcd.dwItemSpec);
    Selected := (ListView_GetItemState(FGrid, Row, LVIS_SELECTED) and
      LVIS_SELECTED) <> 0;
    if Selected then Draw^.nmcd.uItemState := Draw^.nmcd.uItemState and not CDIS_SELECTED;
    Exit(CDRF_NOTIFYSUBITEMDRAW);
  end;
  if Draw^.nmcd.dwDrawStage <> (CDDS_ITEMPREPAINT or CDDS_SUBITEM) then Exit;
  Row := Integer(Draw^.nmcd.dwItemSpec);
  Selected := (ListView_GetItemState(FGrid, Row, LVIS_SELECTED) and
    LVIS_SELECTED) <> 0;
  if Selected then
  begin
    CurrentCell := (Row = FCurrentRow) and (Draw^.iSubItem = FCurrentColumn);
    Draw^.clrText := FSelectionTextColor;
    if CurrentCell then Draw^.clrTextBk := FCurrentCellColor
    else Draw^.clrTextBk := FSelectionBackColor;
  end
  else
  begin
    Draw^.clrText := FTextColor;
    if Odd(Row) then Draw^.clrTextBk := FBackColor2 else Draw^.clrTextBk := FBackColor;
  end;
  Column := Draw^.iSubItem;
  if not FDecimalAlign or (Column < 0) or (Column >= Length(FDecimalAnchors)) or
    (Row < 0) or (Row >= Length(FVisibleRows)) then Exit;
  SourceRow := FVisibleRows[Row];
  if (SourceRow < 0) or (SourceRow >= Length(FRows)) or
    (Column >= Length(FRows[SourceRow])) then Exit;
  S := FRows[SourceRow][Column];
  if not SplitDecimalText(S, IntegerPart, FractionPart, Separator) and
    not IsIntegerText(S) then Exit;
  FillChar(R, SizeOf(R), 0);
  R.Top := Column;
  R.Left := LVIR_BOUNDS;
  if SendMessageW(FGrid, LVM_GETSUBITEMRECT, Row, LPARAM(@R)) = 0 then
    R := Draw^.nmcd.rc;
  if Column = 0 then R.Right := R.Left + ListView_GetColumnWidth(FGrid, 0);
  Brush := CreateSolidBrush(Draw^.clrTextBk);
  FillRect(Draw^.nmcd.hdc, R, Brush);
  DeleteObject(Brush);
  SavedDC := SaveDC(Draw^.nmcd.hdc);
  IntersectClipRect(Draw^.nmcd.hdc, R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1);
  OldFont := SelectObject(Draw^.nmcd.hdc, FFont);
  OldTextColor := SetTextColor(Draw^.nmcd.hdc, Draw^.clrText);
  OldBkMode := SetBkMode(Draw^.nmcd.hdc, TRANSPARENT);
  TextRect := R;
  if Separator = #0 then
  begin
    TextRect.Left := R.Left + 6;
    TextRect.Right := IntegerTextRightEdge(R.Left, R.Right, 6,
      FDecimalAnchors[Column], (Column < Length(FDecimalColumns)) and
      FDecimalColumns[Column]);
    DrawTextW(Draw^.nmcd.hdc, PWideChar(S), -1, TextRect,
      DT_RIGHT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
  end
  else
  begin
    Anchor := R.Left + 6 + FDecimalAnchors[Column];
    TextRect.Left := R.Left + 6;
    TextRect.Right := Anchor;
    DrawTextW(Draw^.nmcd.hdc, PWideChar(IntegerPart), -1, TextRect,
      DT_RIGHT or DT_VCENTER or DT_SINGLELINE);
    DecimalText := Separator + FractionPart;
    TextRect.Left := Anchor;
    TextRect.Right := R.Right - 6;
    DrawTextW(Draw^.nmcd.hdc, PWideChar(DecimalText), -1, TextRect,
      DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
  end;
  SetBkMode(Draw^.nmcd.hdc, OldBkMode);
  SetTextColor(Draw^.nmcd.hdc, OldTextColor);
  SelectObject(Draw^.nmcd.hdc, OldFont);
  RestoreDC(Draw^.nmcd.hdc, SavedDC);
  if (ListView_GetExtendedListViewStyle(FGrid) and LVS_EX_GRIDLINES) <> 0 then
  begin
    Pen := CreatePen(PS_SOLID, 1, GetSysColor(COLOR_3DFACE));
    OldPen := SelectObject(Draw^.nmcd.hdc, Pen);
    MoveToEx(Draw^.nmcd.hdc, R.Right - 1, R.Top, nil);
    LineTo(Draw^.nmcd.hdc, R.Right - 1, R.Bottom);
    MoveToEx(Draw^.nmcd.hdc, R.Left, R.Bottom - 1, nil);
    LineTo(Draw^.nmcd.hdc, R.Right, R.Bottom - 1);
    SelectObject(Draw^.nmcd.hdc, OldPen);
    DeleteObject(Pen);
  end;
  Result := CDRF_SKIPDEFAULT;
end;

procedure TXmlViewer.UpdateText(Node: TDOMNode);
var
  S: UnicodeString;
  CF: CHARFORMAT2W;
  StartPos, EndPos: Integer;
begin
  FTextDirty := False;
  FTextSourceStart := 0;
  FTextSourceMapped := False;
  SetLength(FTextDisplayToSource, 0);
  SetLength(FTextSourceToDisplay, 0);
  if not Assigned(Node) then S := ''
  else if FFormatText and FindSourceRange(Node, StartPos, EndPos) then
  begin
    FTextSourceStart := StartPos;
    FTextSourceMapped := True;
    FormatXmlDisplay(FSourceText, StartPos, EndPos, S,
      FTextDisplayToSource, FTextSourceToDisplay);
  end
  else if FFormatText then S := XmlNodeText(Node)
  else S := XmlNodeValue(Node);
  FillChar(CF, SizeOf(CF), 0);
  CF.cbSize := SizeOf(CF);
  CF.dwMask := CFM_COLOR or CFM_BOLD;
  if FDark then CF.crTextColor := ReadSettingInt('xml-text-color-dark', RGB(220, 220, 220))
  else CF.crTextColor := ReadSettingInt('xml-text-color', RGB(0, 0, 0));
  CF.dwEffects := 0;
  SendMessageW(FText, WM_SETREDRAW, 0, 0);
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_DEFAULT, LPARAM(@CF));
  SetWindowTextW(FText, PWideChar(S));
  SendMessageW(FText, EM_SETSEL, 0, 0);
  SendMessageW(FText, WM_SETREDRAW, 1, 0);
  InvalidateRect(FText, nil, True);
  if IsWindowVisible(FText) then HighlightVisibleText;
end;

procedure TXmlViewer.HighlightVisibleText;
var
  CF: CHARFORMAT2W;
  I, FirstLine, VisibleLines, ViewStart, ViewEnd, SpanStart, SpanEnd,
    LocalStart, LocalEnd, SelectionStart, SelectionEnd, SourceViewStart,
    SourceViewEnd, LowIndex, HighIndex, MiddleIndex, FirstSpan: Integer;
  Color: COLORREF;
  Client: TRect;
  ScrollPosition: TPoint;
  DC: HDC;
  OldFont: HGDIOBJ;
  Metrics: TTextMetricW;
begin
  if not FFormatText or not FTextSourceMapped or
    (Length(FTextSourceToDisplay) = 0) then Exit;
  FirstLine := SendMessageW(FText, EM_GETFIRSTVISIBLELINE, 0, 0);
  ViewStart := SendMessageW(FText, EM_LINEINDEX, FirstLine, 0);
  if ViewStart < 0 then ViewStart := 0;
  GetClientRect(FText, Client);
  VisibleLines := 1;
  DC := GetDC(FText);
  if DC <> 0 then
  begin
    OldFont := SelectObject(DC, FFont);
    FillChar(Metrics, SizeOf(Metrics), 0);
    if GetTextMetricsW(DC, @Metrics) and (Metrics.tmHeight > 0) then
      VisibleLines := (Client.Bottom + Metrics.tmHeight - 1) div Metrics.tmHeight;
    SelectObject(DC, OldFont);
    ReleaseDC(FText, DC);
  end;
  ViewEnd := SendMessageW(FText, EM_LINEINDEX, FirstLine + VisibleLines, 0);
  if ViewEnd < 0 then ViewEnd := GetWindowTextLengthW(FText);
  if ViewEnd <= ViewStart then Exit;
  SourceViewStart := SourcePositionAtTextCursor(ViewStart);
  SourceViewEnd := SourcePositionAtTextCursor(ViewEnd - 1) + 1;
  LowIndex := 0;
  HighIndex := Length(FSyntaxSpans);
  while LowIndex < HighIndex do
  begin
    MiddleIndex := LowIndex + (HighIndex - LowIndex) div 2;
    if FSyntaxSpans[MiddleIndex].StartPos < SourceViewStart then
      LowIndex := MiddleIndex + 1
    else
      HighIndex := MiddleIndex;
  end;
  FirstSpan := LowIndex;
  while (FirstSpan > 0) and
    (FSyntaxSpans[FirstSpan - 1].EndPos > SourceViewStart) do Dec(FirstSpan);
  SendMessageW(FText, EM_GETSEL, WPARAM(@SelectionStart), LPARAM(@SelectionEnd));
  FillChar(ScrollPosition, SizeOf(ScrollPosition), 0);
  SendMessageW(FText, EM_GETSCROLLPOS, 0, LPARAM(@ScrollPosition));
  SendMessageW(FText, WM_SETREDRAW, 0, 0);
  FillChar(CF, SizeOf(CF), 0);
  CF.cbSize := SizeOf(CF);
  CF.dwMask := CFM_COLOR or CFM_BOLD;
  if FDark then CF.crTextColor := ReadSettingInt('xml-text-color-dark', RGB(220, 220, 220))
  else CF.crTextColor := ReadSettingInt('xml-text-color', RGB(0, 0, 0));
  CF.dwEffects := 0;
  SendMessageW(FText, EM_SETSEL, ViewStart, ViewEnd);
  SendMessageW(FText, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(@CF));
  for I := FirstSpan to High(FSyntaxSpans) do
  begin
    SpanStart := FSyntaxSpans[I].StartPos;
    SpanEnd := FSyntaxSpans[I].EndPos;
    if SpanStart >= SourceViewEnd then Break;
    if SpanStart < FTextSourceStart then SpanStart := FTextSourceStart;
    if SpanEnd > FTextSourceStart + High(FTextSourceToDisplay) then
      SpanEnd := FTextSourceStart + High(FTextSourceToDisplay);
    if SpanEnd <= SpanStart then Continue;
    LocalStart := FTextSourceToDisplay[SpanStart - FTextSourceStart];
    LocalEnd := FTextSourceToDisplay[SpanEnd - 1 - FTextSourceStart] + 1;
    if (LocalStart < 0) or (LocalEnd <= LocalStart) or
      (LocalEnd <= ViewStart) or (LocalStart >= ViewEnd) then Continue;
    if LocalStart < ViewStart then LocalStart := ViewStart;
    if LocalEnd > ViewEnd then LocalEnd := ViewEnd;
    Color := FTextColor;
    case FSyntaxSpans[I].Kind of
      xskTag:
        if FDark then Color := ReadSettingInt('xml-tag-color-dark', RGB(0, 0, 255))
        else Color := ReadSettingInt('xml-tag-color', RGB(0, 0, 128));
      xskString:
        if FDark then Color := ReadSettingInt('xml-string-color-dark', RGB(0, 196, 0))
        else Color := ReadSettingInt('xml-string-color', RGB(0, 128, 0));
      xskValue:
        if FDark then Color := ReadSettingInt('xml-value-color-dark', RGB(0, 196, 128))
        else Color := ReadSettingInt('xml-value-color', RGB(0, 128, 128));
      xskCData:
        if FDark then Color := ReadSettingInt('xml-cdata-color-dark', RGB(220, 220, 220))
        else Color := ReadSettingInt('xml-cdata-color', RGB(220, 220, 220));
      xskComment:
        if FDark then Color := ReadSettingInt('xml-comment-color-dark', RGB(220, 220, 128))
        else Color := ReadSettingInt('xml-comment-color', RGB(220, 220, 128));
    end;
    CF.crTextColor := Color;
    if (FSyntaxSpans[I].Kind = xskTag) and
      (ReadSettingInt('font-use-bold', 0) <> 0) then CF.dwEffects := CFE_BOLD
    else CF.dwEffects := 0;
    SendMessageW(FText, EM_SETSEL, LocalStart, LocalEnd);
    SendMessageW(FText, EM_SETCHARFORMAT, SCF_SELECTION, LPARAM(@CF));
  end;
  SendMessageW(FText, EM_SETSEL, SelectionStart, SelectionEnd);
  SendMessageW(FText, EM_SETSCROLLPOS, 0, LPARAM(@ScrollPosition));
  SendMessageW(FText, WM_SETREDRAW, 1, 0);
  InvalidateRect(FText, nil, True);
end;

procedure TXmlViewer.Layout;
var
  R, T: TRect;
  StatusH, TabTop: Integer;
begin
  CloseCellEdit(True);
  GetClientRect(FWnd, R);
  if FSplitter < 110 then FSplitter := 110;
  if (R.Right > 190) and (FSplitter > R.Right - 80) then
    FSplitter := R.Right - 80;
  SendMessageW(FStatus, WM_SIZE, 0, 0);
  GetClientRect(FStatus, T);
  StatusH := T.Bottom;
  MoveWindow(FTree, 0, 0, FSplitter, R.Bottom - StatusH, True);
  MoveWindow(FTab, FSplitter + SPLITTER_WIDTH, 0,
    R.Right - FSplitter - SPLITTER_WIDTH,
    R.Bottom - StatusH, True);
  GetClientRect(FTab, T);
  TabTop := 26;
  if FFilterVisible then
    MoveWindow(FGrid, 3, TabTop + 24, T.Right - 6, T.Bottom - TabTop - 27, True)
  else
    MoveWindow(FGrid, 3, TabTop, T.Right - 6, T.Bottom - TabTop - 3, True);
  MoveWindow(FText, 3, TabTop, T.Right - 6, T.Bottom - TabTop - 3, True);
  LayoutFilters;
end;

procedure TXmlViewer.AutoSizeColumns;
const
  HEADER_PADDING = 24;
  CELL_PADDING = 16;
var
  DC: HDC;
  OldFont: HGDIOBJ;
  C, Row, SourceRow, Count, Samples, SampleNo, HeaderWidth, CellWidth,
    DesiredWidth, ConfiguredMaxWidth, MaxSamples: Integer;
  Size: TSize;
  HeaderItem: HDItemW;
  HeaderText: array[0..4095] of WideChar;
  S: UnicodeString;
begin
  DC := GetDC(FGrid);
  if DC = 0 then Exit;
  OldFont := SelectObject(DC, FFont);
  try
    Count := Header_GetItemCount(ListView_GetHeader(FGrid));
    ConfiguredMaxWidth := ReadSettingInt('max-column-width', 300);
    MaxSamples := ReadSettingInt('max-column-samples', 1000);
    Samples := SampleCount(Length(FVisibleRows), MaxSamples);
    for C := 0 to Count - 1 do
    begin
      if ListView_GetColumnWidth(FGrid, C) = 0 then Continue;
      FillChar(HeaderText, SizeOf(HeaderText), 0);
      FillChar(HeaderItem, SizeOf(HeaderItem), 0);
      HeaderItem.mask := HDI_TEXT;
      HeaderItem.pszText := @HeaderText[0];
      HeaderItem.cchTextMax := Length(HeaderText);
      SendMessageW(ListView_GetHeader(FGrid), HDM_GETITEMW, C,
        LPARAM(@HeaderItem));
      S := HeaderText;
      FillChar(Size, SizeOf(Size), 0);
      GetTextExtentPoint32W(DC, PWideChar(S), Length(S), Size);
      HeaderWidth := Size.cx + HEADER_PADDING;
      DesiredWidth := HeaderWidth;
      for SampleNo := 0 to Samples - 1 do
      begin
        Row := SamplePosition(SampleNo, Samples, Length(FVisibleRows));
        SourceRow := FVisibleRows[Row];
        if (SourceRow < 0) or (SourceRow >= Length(FRows)) or
          (C >= Length(FRows[SourceRow])) then Continue;
        S := FRows[SourceRow][C];
        FillChar(Size, SizeOf(Size), 0);
        GetTextExtentPoint32W(DC, PWideChar(S), Length(S), Size);
        CellWidth := Size.cx + CELL_PADDING;
        if CellWidth > DesiredWidth then DesiredWidth := CellWidth;
        if (ConfiguredMaxWidth > 0) and
          (DesiredWidth >= ConfiguredMaxWidth) then
        begin
          DesiredWidth := ConfiguredMaxWidth;
          Break;
        end;
      end;
      if DesiredWidth < HeaderWidth then DesiredWidth := HeaderWidth;
      if (ConfiguredMaxWidth > 0) and (DesiredWidth > ConfiguredMaxWidth) and
        (ConfiguredMaxWidth >= HeaderWidth) then DesiredWidth := ConfiguredMaxWidth;
      ListView_SetColumnWidth(FGrid, C, DesiredWidth);
    end;
  finally
    SelectObject(DC, OldFont);
    ReleaseDC(FGrid, DC);
  end;
  UpdateDecimalAnchors;
  LayoutFilters;
end;

function TXmlViewer.CellRef(Row, Column: Integer): TXmlCellRef;
var
  SourceRow: Integer;
begin
  Result.Kind := xckReadOnly;
  Result.Node := nil;
  if (Row < 0) or (Row >= Length(FVisibleRows)) or (Column < 0) then Exit;
  SourceRow := FVisibleRows[Row];
  if (SourceRow < 0) or (SourceRow >= Length(FCellRefs)) or
    (Column >= Length(FCellRefs[SourceRow])) then Exit;
  Result := FCellRefs[SourceRow][Column];
end;

procedure TXmlViewer.BeginCellEdit(Row, Column: Integer);
var
  R: TRect;
  Ref: TXmlCellRef;
  Value: UnicodeString;
begin
  CloseCellEdit(True);
  if not FEditMode then Exit;
  Ref := CellRef(Row, Column);
  if Ref.Kind = xckReadOnly then
  begin
    MessageBeep(MB_ICONWARNING);
    UpdateEditStatus(' READ ONLY');
    Exit;
  end;
  FillChar(R, SizeOf(R), 0);
  R.Top := Column;
  R.Left := LVIR_BOUNDS;
  if SendMessageW(FGrid, LVM_GETSUBITEMRECT, Row, LPARAM(@R)) = 0 then Exit;
  if Column = 0 then R.Right := R.Left + ListView_GetColumnWidth(FGrid, 0);
  Value := CellRefValue(Ref);
  FEditorRow := Row;
  FEditorColumn := Column;
  FCellEditor := CreateWindowExW(0, 'EDIT', PWideChar(Value),
    WS_CHILD or WS_VISIBLE or WS_BORDER or ES_AUTOHSCROLL,
    R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top,
    FGrid, IDC_CELL_EDITOR, HInstance, nil);
  if FCellEditor = 0 then Exit;
  SendMessageW(FCellEditor, WM_SETFONT, FFont, 1);
  FEditorOldProc := WNDPROC(SetWindowLongPtrW(FCellEditor, GWLP_WNDPROC,
    PtrInt(@EditorWndProc)));
  SendMessageW(FCellEditor, EM_SETSEL, 0, -1);
  SetFocus(FCellEditor);
  UpdateEditStatus(' EDITING');
end;

procedure TXmlViewer.CloseCellEdit(Accept: Boolean);
var
  Buf: array[0..4095] of WideChar;
  Editor: HWND;
  EditorRect: TRect;
  Points: array[0..1] of TPoint;
begin
  if FClosingEditor or not IsWindow(FCellEditor) then Exit;
  FClosingEditor := True;
  FillChar(EditorRect, SizeOf(EditorRect), 0);
  GetWindowRect(FCellEditor, EditorRect);
  Points[0].X := EditorRect.Left;
  Points[0].Y := EditorRect.Top;
  Points[1].X := EditorRect.Right;
  Points[1].Y := EditorRect.Bottom;
  MapWindowPoints(0, FGrid, Points[0], 2);
  EditorRect.Left := Points[0].X;
  EditorRect.Top := Points[0].Y;
  EditorRect.Right := Points[1].X;
  EditorRect.Bottom := Points[1].Y;
  if Accept then
  begin
    Buf[0] := #0;
    GetWindowTextW(FCellEditor, Buf, Length(Buf));
    ShowWindow(FCellEditor, SW_HIDE);
    if not ApplyCellEdit(FEditorRow, FEditorColumn, Buf) then
    begin
      FClosingEditor := False;
      MessageBeep(MB_ICONWARNING);
      ShowWindow(FCellEditor, SW_SHOW);
      SetFocus(FCellEditor);
      SendMessageW(FCellEditor, EM_SETSEL, 0, -1);
      Exit;
    end;
  end;
  Editor := FCellEditor;
  FCellEditor := 0;
  DestroyWindow(Editor);
  FClosingEditor := False;
  RedrawWindow(FGrid, @EditorRect, 0,
    RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW or RDW_ALLCHILDREN);
  UpdateEditStatus;
end;

function TXmlViewer.ApplyCellEdit(Row, Column: Integer;
  const Value: UnicodeString): Boolean;
var
  Ref: TXmlCellRef;
  PatchedSource: UnicodeString;
  SourceRow, I: Integer;
  FilterText: array[0..4095] of WideChar;
  FiltersActive: Boolean;
begin
  Ref := CellRef(Row, Column);
  Result := Ref.Kind <> xckReadOnly;
  if not Result then Exit;
  if Value = CellRefValue(Ref) then Exit(True);
  SourceRow := FVisibleRows[Row];
  EnsureSourceMap;
  if not PatchCellSource(FSourceText, FNodeSpans, Ref, Value, PatchedSource) then
  begin
    UpdateEditStatus(' INVALID XML VALUE');
    Exit(False);
  end;
  Result := ApplyCellValue(Ref, Value);
  if not Result then Exit;
  FDirty := True;
  FSourceText := PatchedSource;
  FSourceMapReady := False;
  SetLength(FSyntaxSpans, 0);
  SetLength(FNodeSpans, 0);
  FRows[SourceRow][Column] := CellRefValue(Ref);
  FTextDirty := True;
  if IsWindowVisible(FText) then UpdateText(SelectedNode);
  FiltersActive := False;
  for I := 0 to High(FFilterEdits) do
  begin
    FilterText[0] := #0;
    GetWindowTextW(FFilterEdits[I], FilterText, Length(FilterText));
    if FilterText[0] <> #0 then
    begin
      FiltersActive := True;
      Break;
    end;
  end;
  if FiltersActive then ApplyFilters
  else
  begin
    UpdateDecimalAnchors;
    InvalidateRect(FGrid, nil, False);
    UpdateEditStatus;
  end;
  InvalidateRect(FTree, nil, True);
end;

function TXmlViewer.SaveChanges: Boolean;
begin
  CloseCellEdit(True);
  if IsWindow(FCellEditor) then Exit(False);
  if not FDirty then
  begin
    UpdateEditStatus(' NO CHANGES');
    Exit(True);
  end;
  Result := SaveXmlSourceAtomic(FFileName, FSourceText, FEncoding);
  if Result then
  begin
    FDirty := False;
    FEncoding.SourceText := FSourceText;
    UpdateEditStatus(' SAVED');
  end
  else
  begin
    UpdateEditStatus(' SAVE FAILED');
    MessageBeep(MB_ICONERROR);
  end;
end;

function TXmlViewer.ConfirmClose: Boolean;
var
  Choice: Integer;
  FileLabel, MessageText: UnicodeString;
begin
  Result := False;
  if FConfirmingClose then Exit;
  FConfirmingClose := True;
  try
    CloseCellEdit(True);
    if IsWindow(FCellEditor) then Exit;
    if not FDirty then Exit(True);

    FileLabel := ExtractFileName(FFileName);
    MessageText := 'Save changes to "' + FileLabel + '" before closing?';
    Choice := MessageBoxW(FWnd, PWideChar(MessageText),
      'xmltab', MB_YESNO or MB_ICONWARNING or MB_DEFBUTTON1);
    case Choice of
      IDYES: Result := SaveChanges;
      IDNO: Result := True;
    end;
  finally
    FConfirmingClose := False;
  end;
end;

procedure TXmlViewer.UpdateEditStatus(const MessageText: UnicodeString);
var
  S: UnicodeString;
begin
  if MessageText <> '' then S := MessageText
  else if FEditMode and FDirty then S := ' EDIT MODE *'
  else if FEditMode then S := ' EDIT MODE'
  else if FDirty then S := ' MODIFIED *'
  else S := '';
  SendMessageW(FStatus, SB_SETTEXTW, 4, LPARAM(PWideChar(S)));
end;

procedure TXmlViewer.SortGrid(Column: Integer);
var
  Temp: array of Integer;

  function CompareRows(A, B: Integer): Integer;
  begin
    Result := NaturalCompare(FRows[A][Column], FRows[B][Column]);
    if FSortDescending then Result := -Result;
  end;

  procedure MergeSort(Left, Right: Integer);
  var
    Middle, A, B, K: Integer;
  begin
    if Left >= Right then Exit;
    Middle := (Left + Right) div 2;
    MergeSort(Left, Middle);
    MergeSort(Middle + 1, Right);
    A := Left; B := Middle + 1; K := Left;
    while (A <= Middle) and (B <= Right) do
    begin
      if CompareRows(FVisibleRows[A], FVisibleRows[B]) <= 0 then
      begin Temp[K] := FVisibleRows[A]; Inc(A); end
      else begin Temp[K] := FVisibleRows[B]; Inc(B); end;
      Inc(K);
    end;
    while A <= Middle do begin Temp[K] := FVisibleRows[A]; Inc(A); Inc(K); end;
    while B <= Right do begin Temp[K] := FVisibleRows[B]; Inc(B); Inc(K); end;
    for K := Left to Right do FVisibleRows[K] := Temp[K];
  end;
begin
  CloseCellEdit(True);
  FSearchText := '';
  if (Column < 0) or (Length(FVisibleRows) < 2) then Exit;
  if FSortColumn = Column then FSortDescending := not FSortDescending
  else begin FSortColumn := Column; FSortDescending := False; end;
  SetLength(Temp, Length(FVisibleRows));
  MergeSort(0, High(FVisibleRows));
  UpdateDecimalAnchors;
  InvalidateRect(FGrid, nil, True); AutoSizeColumns;
end;

function TXmlViewer.ForwardHostHotKey(Key: WPARAM): Boolean;
var
  Ctrl: Boolean;
begin
  Ctrl := (GetKeyState(VK_CONTROL) and $8000) <> 0;
  Result := (Key = VK_ESCAPE) or (Key = VK_F11) or (Key = VK_F3) or
    (Key = VK_F5) or (Key = VK_F7) or (Ctrl and (Key = Ord('F'))) or
    (((Key >= Ord('1')) and (Key <= Ord('8'))) and not Ctrl and
      (ReadSettingInt('disable-num-keys', 0) = 0)) or
    (((Key = Ord('N')) or (Key = Ord('P'))) and
      (ReadSettingInt('disable-np-keys', 0) = 0)) or
    ((Key = Ord('Q')) and (ReadSettingInt('exit-by-q', 0) <> 0));
  if not Result then Exit;
  SetFocus(GetParent(FWnd));
  keybd_event(Byte(Key), Byte(MapVirtualKey(Key, MAPVK_VK_TO_VSC)),
    KEYEVENTF_EXTENDEDKEY, 0);
end;

function TXmlViewer.HandleHotKey(Key: WPARAM): Boolean;
var
  Ctrl, Shift: Boolean;
  Column, Columns: Integer;
begin
  Ctrl := (GetKeyState(VK_CONTROL) and $8000) <> 0;
  Shift := (GetKeyState(VK_SHIFT) and $8000) <> 0;
  if Ctrl and (Key = Ord('S')) then
  begin
    SaveChanges;
    Exit(True);
  end;
  if Ctrl and (Key = Ord('R')) then
  begin
    CloseCellEdit(True);
    FEditMode := not FEditMode;
    UpdateEditStatus;
    Exit(True);
  end;
  if (Key = VK_F2) and (GetFocus = FGrid) then
  begin
    BeginCellEdit(FCurrentRow, FCurrentColumn);
    Exit(True);
  end;
  if Ctrl and (Key = Ord('C')) then
  begin
    if GetFocus = FTree then CopyXPath
    else if Shift then CopyRows
    else if ReadSettingInt('copy-column', 0) <> 0 then CopySelectedColumn
    else CopySelectedCell;
    Exit(True);
  end;
  if Ctrl and (Key = VK_SPACE) then
  begin
    ShowAllColumns;
    Exit(True);
  end;
  Columns := Header_GetItemCount(ListView_GetHeader(FGrid));
  if Ctrl and (Key >= Ord('0')) and (Key <= Ord('9')) and
    (ReadSettingInt('disable-num-keys', 0) = 0) then
  begin
    if Key = Ord('0') then Column := FCurrentColumn else Column := Key - Ord('1');
    if (Column >= 0) and (Column < Columns) then
    begin
      SortGrid(Column);
      Exit(True);
    end;
  end;
  if Ctrl and (Key = Ord('L')) then begin LocateText; Exit(True); end;
  if Ctrl and (Key = VK_ADD) then begin SetFontSize(FFontSize - 1); Exit(True); end;
  if Ctrl and (Key = VK_SUBTRACT) then begin SetFontSize(FFontSize + 1); Exit(True); end;
  if (GetFocus = FGrid) and ((Key = VK_LEFT) or (Key = VK_RIGHT)) and
    (Columns > 0) then
  begin
    if Key = VK_LEFT then Dec(FCurrentColumn) else Inc(FCurrentColumn);
    if FCurrentColumn < 0 then FCurrentColumn := Columns - 1;
    if FCurrentColumn >= Columns then FCurrentColumn := 0;
    UpdatePositionStatus;
    InvalidateRect(FGrid, nil, False);
    Exit(True);
  end;
  Result := ForwardHostHotKey(Key);
end;

function TXmlViewer.Search(const S: UnicodeString; Flags: Integer): Integer;
var
  R, C, P, RelevantFlags: Integer;
  Hay, Needle: UnicodeString;
  ResetSearch, Backwards, WasBackwards, DirectionChanged,
    MatchCase, WholeWords: Boolean;

  function IsWordChar(Ch: WideChar): Boolean;
  begin
    Result := (Ch = '_') or ((Ch >= '0') and (Ch <= '9')) or
      ((Ch >= 'A') and (Ch <= 'Z')) or ((Ch >= 'a') and (Ch <= 'z')) or
      (Ord(Ch) >= 128);
  end;

  function ValidWholeWord(const Value: UnicodeString; PosNo: Integer): Boolean;
  var
    AfterPos: Integer;
  begin
    if not WholeWords then Exit(True);
    AfterPos := PosNo + Length(Needle);
    Result := ((PosNo = 1) or not IsWordChar(Value[PosNo - 1])) and
      ((AfterPos > Length(Value)) or not IsWordChar(Value[AfterPos]));
  end;

  function FindForward(const Value: UnicodeString; FromPos: Integer): Integer;
  var
    Found: Integer;
  begin
    Result := 0;
    if FromPos < 1 then FromPos := 1;
    while FromPos <= Length(Value) do
    begin
      Found := Pos(Needle, Copy(Value, FromPos, MaxInt));
      if Found = 0 then Exit;
      Result := FromPos + Found - 1;
      if ValidWholeWord(Value, Result) then Exit;
      FromPos := Result + 1;
    end;
  end;

  function FindBackward(const Value: UnicodeString; BeforePos: Integer): Integer;
  var
    Candidate, Found, FromPos: Integer;
  begin
    Result := 0;
    Candidate := 0;
    FromPos := 1;
    if BeforePos > Length(Value) + 1 then BeforePos := Length(Value) + 1;
    while FromPos < BeforePos do
    begin
      Found := Pos(Needle, Copy(Value, FromPos, BeforePos - FromPos));
      if Found = 0 then Break;
      Found := FromPos + Found - 1;
      if ValidWholeWord(Value, Found) then Candidate := Found;
      FromPos := Found + 1;
    end;
    Result := Candidate;
  end;

  function SearchValue(const Value: UnicodeString; FromPos: Integer): Integer;
  begin
    if Backwards then Result := FindBackward(Value, FromPos)
    else Result := FindForward(Value, FromPos);
  end;
begin
  Result := 0;
  if S = '' then Exit;
  Backwards := (Flags and lcs_backwards) <> 0;
  WasBackwards := (FSearchFlags and lcs_backwards) <> 0;
  DirectionChanged := (FSearchText = S) and (Backwards <> WasBackwards);
  RelevantFlags := Flags and (lcs_matchcase or lcs_wholewords);
  ResetSearch := (FSearchText <> S) or
    ((FSearchFlags and (lcs_matchcase or lcs_wholewords)) <> RelevantFlags) or
    (((Flags and lcs_findfirst) <> 0) and not DirectionChanged);
  MatchCase := (Flags and lcs_matchcase) <> 0;
  WholeWords := (Flags and lcs_wholewords) <> 0;
  Needle := S;
  if not MatchCase then Needle := LowerCase(Needle);
  FSearchText := S;
  FSearchFlags := RelevantFlags;
  if Backwards then FSearchFlags := FSearchFlags or lcs_backwards;
  if ResetSearch then
  begin
    if Backwards then
    begin
      FSearchRow := High(FVisibleRows);
      if FSearchRow >= 0 then FSearchColumn := High(FRows[FVisibleRows[FSearchRow]])
      else FSearchColumn := -1;
      FSearchCellPos := MaxInt;
    end;
    if not Backwards then
    begin
      FSearchRow := 0;
      FSearchColumn := 0;
      FSearchCellPos := 1;
    end;
  end;
  if DirectionChanged and not ResetSearch then
  begin
    if Backwards then Dec(FSearchCellPos, Length(S))
    else Inc(FSearchCellPos, Length(S));
  end;
  R := FSearchRow;
  C := FSearchColumn;
  while (R >= 0) and (R < Length(FVisibleRows)) do
  begin
    while (C >= 0) and (C < Length(FRows[FVisibleRows[R]])) do
    begin
      Hay := FRows[FVisibleRows[R]][C];
      if not MatchCase then Hay := LowerCase(Hay);
      P := SearchValue(Hay, FSearchCellPos);
      if P > 0 then
      begin
        ListView_SetItemState(FGrid, -1, 0, LVIS_SELECTED or LVIS_FOCUSED);
        ListView_SetItemState(FGrid, R, LVIS_SELECTED or LVIS_FOCUSED,
          LVIS_SELECTED or LVIS_FOCUSED);
        ListView_EnsureVisible(FGrid, R, False);
        FCurrentRow := R;
        FCurrentColumn := C;
        UpdatePositionStatus;
        FSearchRow := R;
        FSearchColumn := C;
        if Backwards then FSearchCellPos := P
        else FSearchCellPos := P + Length(S);
        SetFocus(FGrid);
        Exit(1);
      end;
      if Backwards then begin Dec(C); FSearchCellPos := MaxInt; end
      else begin Inc(C); FSearchCellPos := 1; end;
    end;
    if Backwards then
    begin
      Dec(R);
      if R >= 0 then C := High(FRows[FVisibleRows[R]]);
    end
    else
    begin
      Inc(R);
      C := 0;
    end;
  end;
  MessageBeep(0);
end;

function CreateXmlViewer(ParentWin: HWND; const FileName: UnicodeString; ShowFlags: Integer): HWND;
var
  V: TXmlViewer;
  Msg: UnicodeString;
begin
  Result := 0;
  try
    V := TXmlViewer.Create(ParentWin, FileName);
    Result := V.FWnd;
  except
    on E: Exception do
    begin
      Msg := 'xmltab: ' + E.Message;
      OutputDebugStringW(PWideChar(Msg));
    end;
  end;
end;

procedure CloseXmlViewer(Wnd: HWND);
var
  V: TXmlViewer;
begin
  if not IsWindow(Wnd) then Exit;
  V := ViewerFromWnd(Wnd);
  if not Assigned(V) or V.ConfirmClose then DestroyWindow(Wnd);
end;

function SearchXmlViewer(Wnd: HWND; const SearchText: UnicodeString; SearchFlags: Integer): Integer;
var
  V: TXmlViewer;
begin
  V := ViewerFromWnd(Wnd); if Assigned(V) then Result := V.Search(SearchText, SearchFlags) else Result := 0;
end;

end.
