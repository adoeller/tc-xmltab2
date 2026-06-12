unit uSettings;

{$mode delphi}{$H+}

interface

uses Windows, SysUtils;

procedure SetDefaultIniName(const AName: AnsiString);
function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
function ReadSettingInt(const Name: UnicodeString; Default: Integer): Integer;
procedure WriteSettingInt(const Name: UnicodeString; Value: Integer);
function IniPath: UnicodeString;

implementation

var
  GDefaultIniPath: UnicodeString;

function IniPath: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  LocalIniPath: UnicodeString;
begin
  GetModuleFileNameW(HInstance, Buf, MAX_PATH);
  LocalIniPath := ChangeFileExt(Buf, '.ini');
  if FileExists(LocalIniPath) or (GDefaultIniPath = '') then
    Result := LocalIniPath
  else
    Result := GDefaultIniPath;
end;

procedure SetDefaultIniName(const AName: AnsiString);
begin
  if GDefaultIniPath = '' then
    GDefaultIniPath := UnicodeString(AName);
end;

function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
var
  Buf: array[0..1023] of WideChar;
begin
  GetPrivateProfileStringW('xmltab', PWideChar(Name), PWideChar(Default),
    Buf, Length(Buf), PWideChar(IniPath));
  Result := Buf;
end;

function ReadSettingInt(const Name: UnicodeString; Default: Integer): Integer;
var
  Value: UnicodeString;
  CommentPos: Integer;
begin
  Value := ReadSetting(Name, IntToStr(Default));
  CommentPos := Pos(';', Value);
  if CommentPos > 0 then Value := Copy(Value, 1, CommentPos - 1);
  Result := StrToIntDef(Trim(Value), Default);
end;

procedure WriteSettingInt(const Name: UnicodeString; Value: Integer);
begin
  WritePrivateProfileStringW('xmltab', PWideChar(Name),
    PWideChar(UnicodeString(IntToStr(Value))), PWideChar(IniPath));
end;

end.
