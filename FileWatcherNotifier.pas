unit FileWatcherNotifier;

interface

uses
  ToolsAPI, SymbolIndex, System.Classes, System.SysUtils;

type
  TFileWatcherNotifier = class(TNotifierObject, IOTANotifier, IOTAModuleNotifier)
  private
    FFileName: string;
    FIndex: Integer;
  public
    constructor Create(const AFileName: string);
    procedure AfterSave;
    function CheckOverwrite: Boolean;
    procedure ModuleRenamed(const NewName: string);
    procedure Destroyed;
    property Index: Integer read FIndex write FIndex;
  end;

procedure RegisterGlobalFileWatchers;
procedure UnregisterGlobalFileWatchers;

implementation

type
  TModNotifier = record
    Module: IOTAModule;
    Index: Integer;
  end;

var
  GNotifiers: TArray<TModNotifier>;

constructor TFileWatcherNotifier.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FIndex := -1;
end;

procedure TFileWatcherNotifier.AfterSave;
begin
  TThread.CreateAnonymousThread(
    procedure
    begin
      if Assigned(GSymbolIndex) then
      begin
        GSymbolIndex.InvalidateFile(FFileName);
        GSymbolIndex.IndexFile(FFileName);
      end;
    end).Start;
end;

function TFileWatcherNotifier.CheckOverwrite: Boolean;
begin
  Result := True;
end;

procedure TFileWatcherNotifier.ModuleRenamed(const NewName: string);
begin
  FFileName := NewName;
end;

procedure TFileWatcherNotifier.Destroyed;
var
  I: Integer;
begin
  for I := 0 to High(GNotifiers) do
  begin
    if GNotifiers[I].Index = FIndex then
    begin
      GNotifiers[I].Module := nil;
      Break;
    end;
  end;
end;

procedure RegisterGlobalFileWatchers;
var
  ModServices: IOTAModuleServices;
  I, Idx: Integer;
  Module: IOTAModule;
  NotifierObj: TFileWatcherNotifier;
begin
  SetLength(GNotifiers, 0);
  if BorlandIDEServices.QueryInterface(IOTAModuleServices, ModServices) = S_OK then
  begin
    for I := 0 to ModServices.ModuleCount - 1 do
    begin
      Module := ModServices.Modules[I];
      NotifierObj := TFileWatcherNotifier.Create(Module.FileName);
      Idx := Module.AddNotifier(NotifierObj);
      NotifierObj.Index := Idx;

      SetLength(GNotifiers, Length(GNotifiers) + 1);
      GNotifiers[High(GNotifiers)].Module := Module;
      GNotifiers[High(GNotifiers)].Index := Idx;
    end;
  end;
end;

procedure UnregisterGlobalFileWatchers;
var
  I: Integer;
begin
  for I := 0 to High(GNotifiers) do
  begin
    try
      if Assigned(GNotifiers[I].Module) then
        GNotifiers[I].Module.RemoveNotifier(GNotifiers[I].Index);
    except
    end;
  end;
  SetLength(GNotifiers, 0);
end;

end.
