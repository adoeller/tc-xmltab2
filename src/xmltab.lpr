library xmltab;

{$mode delphi}{$H+}
{$calling stdcall}

uses
  Windows,
  plugin_main in 'plugin_main.pas',
  listplug in 'listplug.pas',
  uSettings in 'uSettings.pas',
  uXmlModel in 'uXmlModel.pas',
  uViewer in 'uViewer.pas';

exports
  plugin_main.ListLoad name 'ListLoad',
  plugin_main.ListLoadW name 'ListLoadW',
  plugin_main.ListCloseWindow name 'ListCloseWindow',
  plugin_main.ListGetDetectString name 'ListGetDetectString',
  plugin_main.ListSetDefaultParams name 'ListSetDefaultParams',
  plugin_main.ListSearchText name 'ListSearchText',
  plugin_main.ListSearchTextW name 'ListSearchTextW';

{$R *.res}

begin
  IsMultiThread := True;
end.
