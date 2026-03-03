unit ConfigManager;

interface

uses
  System.SysUtils, System.IOUtils, System.IniFiles;

function LoadPublicDir: string;
procedure SavePublicDir(const APath: string);

implementation

function GetConfigPath: string;
var
  AppData: string;
begin
  AppData := TPath.Combine(TPath.GetHomePath, 'CodeInsight');
  ForceDirectories(AppData);
  Result := TPath.Combine(AppData, 'config.ini');
end;

function LoadPublicDir: string;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(GetConfigPath);
  try
    Result := Ini.ReadString('Paths', 'PublicoV11', '');
  finally
    Ini.Free;
  end;
end;

procedure SavePublicDir(const APath: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(GetConfigPath);
  try
    Ini.WriteString('Paths', 'PublicoV11', APath);
  finally
    Ini.Free;
  end;
end;

end.
