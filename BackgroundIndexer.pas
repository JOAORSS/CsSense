unit BackgroundIndexer;

interface

uses
  System.Classes, System.SysUtils, System.IOUtils, SQLiteEngine, SymbolTypes,
  ExtratorUnit, FireDAC.Comp.Client, FireDAC.Stan.Param, FireDAC.DApt;

type
  TBackgroundIndexer = class(TThread)
  private
    FFiles: TArray<string>;
    FDBPath: string;
    function CortarNaImplementation(const Texto: string): string;
  public
    constructor Create(const AFiles: TArray<string>; const ADBPath: string);
    procedure Execute; override;
  end;

implementation

uses
  Winapi.Windows;

type
  TSQLiteEngineAccess = class
  public
    FConn: TFDConnection;
  end;

constructor TBackgroundIndexer.Create(const AFiles: TArray<string>; const ADBPath: string);
var
  I: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FDBPath := ADBPath;
  SetLength(FFiles, Length(AFiles));
  for I := Low(AFiles) to High(AFiles) do
    FFiles[I] := AFiles[I];
end;

function TBackgroundIndexer.CortarNaImplementation(const Texto: string): string;
var
  P, PStart: PChar;
  Token: string;
  InString, InComment1, InComment2, InComment3: Boolean;
begin
  P := PChar(Texto);
  InString := False;
  InComment1 := False;
  InComment2 := False;
  InComment3 := False;

  while P^ <> #0 do
  begin
    if InString then
    begin
      if P^ = '''' then InString := False;
      Inc(P);
      Continue;
    end;

    if InComment1 then
    begin
      if P^ = #10 then InComment1 := False;
      Inc(P);
      Continue;
    end;

    if InComment2 then
    begin
      if P^ = '}' then InComment2 := False;
      Inc(P);
      Continue;
    end;

    if InComment3 then
    begin
      if (P^ = '*') and ((P+1)^ = ')') then
      begin
        InComment3 := False;
        Inc(P, 2);
      end
      else
        Inc(P);
      Continue;
    end;

    if P^ = '''' then
    begin
      InString := True;
      Inc(P);
      Continue;
    end;

    if (P^ = '/') and ((P+1)^ = '/') then
    begin
      InComment1 := True;
      Inc(P, 2);
      Continue;
    end;

    if P^ = '{' then
    begin
      InComment2 := True;
      Inc(P);
      Continue;
    end;

    if (P^ = '(') and ((P+1)^ = '*') then
    begin
      InComment3 := True;
      Inc(P, 2);
      Continue;
    end;

    if CharInSet(P^, ['a'..'z','A'..'Z','_']) then
    begin
      PStart := P;
      while CharInSet(P^, ['a'..'z','A'..'Z','0'..'9','_']) do Inc(P);
      SetString(Token, PStart, P - PStart);
      if SameText(Token, 'implementation') then
      begin
        SetString(Result, PChar(Texto), PStart - PChar(Texto));
        Exit;
      end;
      Continue;
    end;

    Inc(P);
  end;
  Result := Texto;
end;

procedure TBackgroundIndexer.Execute;
var
  I, J: Integer;
  Arquivo: string;
  Q: TFDQuery;
  LModTime, DBModTime: TDateTime;
  NeedsIndex: Boolean;
  Extrato: TExtratoUnit;
  AllSyms: TArray<TSymbolInfo>;
  LocalDB: TSQLiteEngine;
  ConteudoBruto: string;
begin
  if FDBPath = '' then Exit;

  OutputDebugString(PChar('[CS-CodeInsight] BGI Iniciando fila com ' + IntToStr(Length(FFiles)) + ' arquivos para o DB: ' + FDBPath));

  LocalDB := TSQLiteEngine.Create;
  try
    LocalDB.Connect(FDBPath);
    if not LocalDB.IsConnected then
    begin
      OutputDebugString(PChar('[CS-CodeInsight] BGI Erro ao conectar banco local da thread.'));
      Exit;
    end;

    for I := Low(FFiles) to High(FFiles) do
    begin
      if Terminated then Break;

      Arquivo := FFiles[I];
      if not FileExists(Arquivo) then Continue;

      if not FileAge(Arquivo, LModTime) then
        LModTime := 0;

      NeedsIndex := True;

      try
        Q := TFDQuery.Create(nil);
        try
          Q.Connection := TSQLiteEngineAccess(LocalDB).FConn;
          Q.SQL.Text := 'SELECT file_mod_time FROM file_meta WHERE file_path = :fp';
          Q.ParamByName('fp').AsString := Arquivo;
          Q.Open;

          if not Q.Eof then
          begin
            DBModTime := Q.FieldByName('file_mod_time').AsFloat;
            if DBModTime = LModTime then
              NeedsIndex := False;
          end;
        finally
          Q.Free;
        end;
      except
        on E: Exception do
          OutputDebugString(PChar('[CS-CodeInsight] BGI Erro SELECT file_meta: ' + E.Message));
      end;

      if not NeedsIndex then
      begin
        Continue;
      end;

      OutputDebugString(PChar('[CS-CodeInsight] BGI Processando extrator: ' + ExtractFileName(Arquivo)));

      try
        ConteudoBruto := TFile.ReadAllText(Arquivo);
        ConteudoBruto := CortarNaImplementation(ConteudoBruto);
        Extrato := ExtrairMetodosEPropriedades(ConteudoBruto);
      except
        on E: Exception do
        begin
          OutputDebugString(PChar('[CS-CodeInsight] BGI Erro na extracao: ' + E.Message));
          Continue;
        end;
      end;

      if Terminated then Break;

      SetLength(AllSyms, 0);

      for J := Low(Extrato.Tipos) to High(Extrato.Tipos) do
      begin
        if Pos('.', Extrato.Tipos[J].Utilizavel) > 0 then Continue;
        SetLength(AllSyms, Length(AllSyms) + 1);
        with AllSyms[High(AllSyms)] do
        begin
          Name := Extrato.Tipos[J].Utilizavel;
          Signature := Extrato.Tipos[J].Visual;
          TypeName := Extrato.Tipos[J].TipoNome;
          DataType := Extrato.Tipos[J].TipoRetorno;
          Kind := skType;
          FileName := Arquivo;
          Line := Extrato.Tipos[J].Linha;
          Visibility := Extrato.Tipos[J].Visibilidade;
          ParentType := Extrato.Tipos[J].ParentType;
          InheritDepth := 0;
        end;
      end;

      for J := Low(Extrato.Variaveis) to High(Extrato.Variaveis) do
      begin
        if Pos('.', Extrato.Variaveis[J].Utilizavel) > 0 then Continue;
        SetLength(AllSyms, Length(AllSyms) + 1);
        with AllSyms[High(AllSyms)] do
        begin
          Name := Extrato.Variaveis[J].Utilizavel;
          Signature := Extrato.Variaveis[J].Visual;
          TypeName := Extrato.Variaveis[J].TipoNome;
          DataType := Extrato.Variaveis[J].TipoRetorno;
          Kind := skVar;
          FileName := Arquivo;
          Line := Extrato.Variaveis[J].Linha;
          Visibility := Extrato.Variaveis[J].Visibilidade;
          ParentType := '';
          InheritDepth := 0;
        end;
      end;

      for J := Low(Extrato.VariaveisLocais) to High(Extrato.VariaveisLocais) do
      begin
        if Pos('.', Extrato.VariaveisLocais[J].Utilizavel) > 0 then Continue;
        SetLength(AllSyms, Length(AllSyms) + 1);
        with AllSyms[High(AllSyms)] do
        begin
          Name := Extrato.VariaveisLocais[J].Utilizavel;
          Signature := Extrato.VariaveisLocais[J].Visual;
          TypeName := Extrato.VariaveisLocais[J].TipoNome;
          DataType := Extrato.VariaveisLocais[J].TipoRetorno;
          Kind := skVar;
          FileName := Arquivo;
          Line := Extrato.VariaveisLocais[J].Linha;
          Visibility := Extrato.VariaveisLocais[J].Visibilidade;
          ParentType := '';
          InheritDepth := 0;
        end;
      end;

      for J := Low(Extrato.Metodos) to High(Extrato.Metodos) do
      begin
        if Pos('.', Extrato.Metodos[J].Utilizavel) > 0 then Continue;
        SetLength(AllSyms, Length(AllSyms) + 1);
        with AllSyms[High(AllSyms)] do
        begin
          Name := Extrato.Metodos[J].Utilizavel;
          Signature := Extrato.Metodos[J].Visual;
          TypeName := Extrato.Metodos[J].TipoNome;
          DataType := Extrato.Metodos[J].TipoRetorno;
          Kind := skMethod;
          FileName := Arquivo;
          Line := Extrato.Metodos[J].Linha;
          Visibility := Extrato.Metodos[J].Visibilidade;
          ParentType := '';
          InheritDepth := 0;
        end;
      end;

      for J := Low(Extrato.Propriedades) to High(Extrato.Propriedades) do
      begin
        if Pos('.', Extrato.Propriedades[J].Utilizavel) > 0 then Continue;
        SetLength(AllSyms, Length(AllSyms) + 1);
        with AllSyms[High(AllSyms)] do
        begin
          Name := Extrato.Propriedades[J].Utilizavel;
          Signature := Extrato.Propriedades[J].Visual;
          TypeName := Extrato.Propriedades[J].TipoNome;
          DataType := Extrato.Propriedades[J].TipoRetorno;
          Kind := skProperty;
          FileName := Arquivo;
          Line := Extrato.Propriedades[J].Linha;
          Visibility := Extrato.Propriedades[J].Visibilidade;
          ParentType := '';
          InheritDepth := 0;
        end;
      end;

      for J := Low(Extrato.Constantes) to High(Extrato.Constantes) do
      begin
        if Pos('.', Extrato.Constantes[J].Utilizavel) > 0 then Continue;
        SetLength(AllSyms, Length(AllSyms) + 1);
        with AllSyms[High(AllSyms)] do
        begin
          Name := Extrato.Constantes[J].Utilizavel;
          Signature := Extrato.Constantes[J].Visual;
          TypeName := Extrato.Constantes[J].TipoNome;
          DataType := Extrato.Constantes[J].TipoRetorno;
          Kind := skConst;
          FileName := Arquivo;
          Line := Extrato.Constantes[J].Linha;
          Visibility := Extrato.Constantes[J].Visibilidade;
          ParentType := '';
          InheritDepth := 0;
        end;
      end;

      if Terminated then Break;

      try
        LocalDB.UpsertFileSymbols(Arquivo, AllSyms);
      except
        on E: Exception do
          OutputDebugString(PChar('[CS-CodeInsight] BGI Erro UpsertFileSymbols: ' + E.Message));
      end;
    end;
  finally
    LocalDB.Free;
  end;

  OutputDebugString(PChar('[CS-CodeInsight] BGI Fila finalizada.'));
end;

end.
