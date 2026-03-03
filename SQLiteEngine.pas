unit SQLiteEngine;

interface

uses
  System.SysUtils, System.StrUtils,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Async,
  FireDAC.Stan.ExprFuncs, FireDAC.Comp.Client,
  FireDAC.Phys, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.Param, FireDAC.DApt,
  SymbolTypes;

type
  TSQLiteEngine = class
  private
    FConn: TFDConnection;
    FDBPath: string;
    FLastError: string;
    procedure CreateTablesIfNeeded;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const APath: string);
    procedure Disconnect;
    function IsConnected: Boolean;
    procedure UpsertFileSymbols(const FilePath: string; const Syms: TArray<TSymbolInfo>);
    function QueryTypeMembers(const TypeName: string): TArray<TSymbolInfo>;
    function QuerySymbolByName(const SymName: string): TArray<TSymbolInfo>;
    property LastError: string read FLastError;
    property DBPath: string read FDBPath;
  end;

var
  GLocalDB: TSQLiteEngine;
  GPublicDB: TSQLiteEngine;
  GPublicDir: string;
  GCurrentProjectDir: string;
  GDelphiLibDirs: TArray<string>;

function DBForFile(const FilePath: string): TSQLiteEngine;

implementation

uses
  Winapi.Windows;

function DBForFile(const FilePath: string): TSQLiteEngine;
var
  Dir: string;
  UpperPath: string;
begin
  OutputDebugString(PChar('[CS-CodeInsight] #--------------------'));
  OutputDebugString(PChar('[CS-CodeInsight] Analisando Arquivo: ' + FilePath));

  UpperPath := UpperCase(FilePath);

  if ((GPublicDir <> '') and StartsText(GPublicDir, FilePath)) or
     (Pos('\PUBLICOV11\', UpperPath) > 0) then
  begin
    OutputDebugString(PChar('[CS-CodeInsight] -> Decisao: PUBLICO (Match PublicoV11)'));
    OutputDebugString(PChar('[CS-CodeInsight] #--------------------'));
    Exit(GPublicDB);
  end;

  if (GCurrentProjectDir <> '') and StartsText(GCurrentProjectDir, FilePath) then
  begin
    OutputDebugString(PChar('[CS-CodeInsight] -> Decisao: LOCAL (Match GCurrentProjectDir: ' + GCurrentProjectDir + ')'));
    OutputDebugString(PChar('[CS-CodeInsight] #--------------------'));
    Exit(GLocalDB);
  end;

  for Dir in GDelphiLibDirs do
  begin
    if StartsText(Dir, FilePath) then
    begin
      OutputDebugString(PChar('[CS-CodeInsight] -> Decisao: RAM / IGNORADO (Match LibDir: ' + Dir + ')'));
      OutputDebugString(PChar('[CS-CodeInsight] #--------------------'));
      Exit(nil);
    end;
  end;

  OutputDebugString(PChar('[CS-CodeInsight] -> Decisao: NENHUM (Fora do escopo)'));
  OutputDebugString(PChar('[CS-CodeInsight] #--------------------'));
  Result := nil;
end;

constructor TSQLiteEngine.Create;
begin
  inherited Create;
end;

destructor TSQLiteEngine.Destroy;
begin
  Disconnect;
  FreeAndNil(FConn);
  inherited Destroy;
end;

procedure TSQLiteEngine.CreateTablesIfNeeded;
var
  Q: TFDQuery;
begin
  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text :=
        'CREATE TABLE IF NOT EXISTS symbols (' +
        '  id          INTEGER PRIMARY KEY AUTOINCREMENT,' +
        '  file_path   TEXT    NOT NULL,' +
        '  name        TEXT    NOT NULL COLLATE NOCASE,' +
        '  signature   TEXT,' +
        '  type_name   TEXT    COLLATE NOCASE,' +
        '  data_type   TEXT,' +
        '  kind        INTEGER NOT NULL,' +
        '  line        INTEGER,' +
        '  visibility  INTEGER,' +
        '  parent_type TEXT' +
        ')';
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro DDL symbols: ' + E.Message));
  end;

  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'CREATE INDEX IF NOT EXISTS idx_sym_name ON symbols(name)';
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  except
  end;

  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'CREATE INDEX IF NOT EXISTS idx_sym_file ON symbols(file_path)';
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  except
  end;

  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'CREATE INDEX IF NOT EXISTS idx_sym_typename ON symbols(type_name)';
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  except
  end;

  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text :=
        'CREATE TABLE IF NOT EXISTS file_meta (' +
        '  file_path     TEXT PRIMARY KEY,' +
        '  indexed_at    REAL,' +
        '  file_mod_time REAL' +
        ')';
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro DDL file_meta: ' + E.Message));
  end;
end;

procedure TSQLiteEngine.Connect(const APath: string);
begin
  try
    if not Assigned(FConn) then
      FConn := TFDConnection.Create(nil);

    FDBPath := APath;

    FConn.LoginPrompt := False;

    FConn.Params.Clear;
    FConn.Params.Add('DriverID=SQLite');
    FConn.Params.Add('Database=' + APath);
    FConn.Params.Add('JournalMode=WAL');
    FConn.Params.Add('Synchronous=NORMAL');

    FConn.ResourceOptions.SilentMode := True;

    FConn.Connected := True;

    CreateTablesIfNeeded;
    OutputDebugString(PChar('[CS-CodeInsight] DB Connect OK: ' + APath));
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro Connect: ' + E.Message));
      if Assigned(FConn) then
        FConn.Connected := False;
    end;
  end;
end;

procedure TSQLiteEngine.Disconnect;
var
  Q: TFDQuery;
begin
  try
    if Assigned(FConn) and FConn.Connected then
    begin
      try
        Q := TFDQuery.Create(nil);
        try
          Q.Connection := FConn;
          Q.ExecSQL('PRAGMA wal_checkpoint(TRUNCATE)');
        finally
          Q.Free;
        end;
      except
      end;
      FConn.Connected := False;
    end;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro Disconnect: ' + E.Message));
    end;
  end;
end;

function TSQLiteEngine.IsConnected: Boolean;
begin
  Result := Assigned(FConn) and FConn.Connected;
end;

procedure TSQLiteEngine.UpsertFileSymbols(const FilePath: string; const Syms: TArray<TSymbolInfo>);
var
  Q: TFDQuery;
  I: Integer;
  LModTime: TDateTime;
begin
  try
    if not IsConnected then Exit;

    FConn.StartTransaction;
    try
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := FConn;

        Q.SQL.Text := 'DELETE FROM symbols WHERE file_path = :fp';
        Q.ParamByName('fp').AsString := FilePath;
        Q.ExecSQL;

        Q.SQL.Text :=
          'INSERT INTO symbols ' +
          '  (file_path, name, signature, type_name, data_type, kind, line, visibility, parent_type)' +
          ' VALUES (:fp, :nm, :sg, :tn, :dt, :kd, :ln, :vs, :pt)';

        if Length(Syms) > 0 then
        begin
          Q.Params.ArraySize := Length(Syms);

          for I := 0 to High(Syms) do
          begin
            Q.ParamByName('fp').AsStrings[I]  := FilePath;
            Q.ParamByName('nm').AsStrings[I]  := Syms[I].Name;
            Q.ParamByName('sg').AsStrings[I]  := Syms[I].Signature;
            Q.ParamByName('tn').AsStrings[I]  := Syms[I].TypeName;
            Q.ParamByName('dt').AsStrings[I]  := Syms[I].DataType;
            Q.ParamByName('kd').AsIntegers[I] := Integer(Syms[I].Kind);
            Q.ParamByName('ln').AsIntegers[I] := Syms[I].Line;
            Q.ParamByName('vs').AsIntegers[I] := Syms[I].Visibility;
            Q.ParamByName('pt').AsStrings[I]  := Syms[I].ParentType;
          end;

          Q.Execute(Length(Syms), 0);
        end;

        if not FileAge(FilePath, LModTime) then
          LModTime := 0;

        Q.SQL.Text :=
          'INSERT OR REPLACE INTO file_meta (file_path, indexed_at, file_mod_time)' +
          ' VALUES (:fp, :ia, :mt)';
        Q.ParamByName('fp').AsString := FilePath;
        Q.ParamByName('ia').AsFloat  := Now;
        Q.ParamByName('mt').AsFloat  := LModTime;
        Q.ExecSQL;

      finally
        Q.Free;
      end;
      FConn.Commit;
    except
      on E: Exception do
      begin
        try FConn.Rollback; except end;
        FLastError := E.Message;
        OutputDebugString(PChar('[CS-CodeInsight] DB Erro Transacao Upsert: ' + E.Message));
      end;
    end;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro Upsert Externo: ' + E.Message));
    end;
  end;
end;

function TSQLiteEngine.QueryTypeMembers(const TypeName: string): TArray<TSymbolInfo>;
var
  Q: TFDQuery;
  Count: Integer;
begin
  SetLength(Result, 0);
  try
    if not IsConnected then Exit;

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text :=
        'SELECT file_path, name, signature, type_name, data_type, kind, line, visibility, parent_type ' +
        'FROM   symbols ' +
        'WHERE  type_name = :tn COLLATE NOCASE';
      Q.ParamByName('tn').AsString := LowerCase(TypeName);
      Q.Open;

      Count := 0;
      SetLength(Result, 64);
      while not Q.Eof do
      begin
        if Count >= Length(Result) then
          SetLength(Result, Length(Result) * 2);

        Result[Count].Name         := Q.FieldByName('name').AsString;
        Result[Count].Signature    := Q.FieldByName('signature').AsString;
        Result[Count].TypeName     := Q.FieldByName('type_name').AsString;
        Result[Count].DataType     := Q.FieldByName('data_type').AsString;
        Result[Count].Kind         := TSymbolKind(Q.FieldByName('kind').AsInteger);
        Result[Count].Line         := Q.FieldByName('line').AsInteger;
        Result[Count].Visibility   := Q.FieldByName('visibility').AsInteger;
        Result[Count].ParentType   := Q.FieldByName('parent_type').AsString;
        Result[Count].FileName     := Q.FieldByName('file_path').AsString;
        Result[Count].InheritDepth := 0;
        Inc(Count);
        Q.Next;
      end;
      SetLength(Result, Count);
    finally
      Q.Free;
    end;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro QueryTypeMembers: ' + E.Message));
    end;
  end;
end;

function TSQLiteEngine.QuerySymbolByName(const SymName: string): TArray<TSymbolInfo>;
var
  Q: TFDQuery;
  Count: Integer;
begin
  SetLength(Result, 0);
  try
    if not IsConnected then Exit;

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text :=
        'SELECT file_path, name, signature, type_name, data_type, kind, line, visibility, parent_type ' +
        'FROM   symbols ' +
        'WHERE  name = :nm COLLATE NOCASE ' +
        'LIMIT  50';
      Q.ParamByName('nm').AsString := LowerCase(SymName);
      Q.Open;

      Count := 0;
      SetLength(Result, 64);
      while not Q.Eof do
      begin
        if Count >= Length(Result) then
          SetLength(Result, Length(Result) * 2);

        Result[Count].Name         := Q.FieldByName('name').AsString;
        Result[Count].Signature    := Q.FieldByName('signature').AsString;
        Result[Count].TypeName     := Q.FieldByName('type_name').AsString;
        Result[Count].DataType     := Q.FieldByName('data_type').AsString;
        Result[Count].Kind         := TSymbolKind(Q.FieldByName('kind').AsInteger);
        Result[Count].Line         := Q.FieldByName('line').AsInteger;
        Result[Count].Visibility   := Q.FieldByName('visibility').AsInteger;
        Result[Count].ParentType   := Q.FieldByName('parent_type').AsString;
        Result[Count].FileName     := Q.FieldByName('file_path').AsString;
        Result[Count].InheritDepth := 0;
        Inc(Count);
        Q.Next;
      end;
      SetLength(Result, Count);
    finally
      Q.Free;
    end;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      OutputDebugString(PChar('[CS-CodeInsight] DB Erro QuerySymbolByName: ' + E.Message));
    end;
  end;
end;

initialization
  GLocalDB  := TSQLiteEngine.Create;
  GPublicDB := TSQLiteEngine.Create;

finalization
  if Assigned(GLocalDB)  then GLocalDB.Disconnect;
  if Assigned(GPublicDB) then GPublicDB.Disconnect;
  FreeAndNil(GLocalDB);
  FreeAndNil(GPublicDB);

end.
