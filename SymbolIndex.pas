unit SymbolIndex;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.StrUtils,
  System.Generics.Collections, System.Generics.Defaults, System.SyncObjs,
  ExtratorUnit, Winapi.Windows, SymbolTypes, SQLiteEngine;

type
  TSymbolIndex = class
  private
    FSymbols: TDictionary<string, TArray<TSymbolInfo>>;
    FTypeMembers: TDictionary<string, TArray<TSymbolInfo>>;
    FTypeParents: TDictionary<string, string>;
    FIndexedFiles: TDictionary<string, TDateTime>;
    FTypeLocation: TDictionary<string, string>;
    FGlobalVars: TDictionary<string, string>;
    FSearchPaths: TArray<string>;
    FLock: TCriticalSection;
    procedure RemoveFileSymbolsUnsafe(const FileName: string);
    procedure AddSymbolUnsafe(const Sym: TSymbolInfo);
  public
    constructor Create;
    destructor Destroy; override;
    procedure IndexFile(const Caminho: string; InterfaceOnly: Boolean = False);
    procedure InvalidateFile(const Caminho: string);
    procedure BuildProjectIndex(const ProjectFiles: TArray<string>);
    procedure BuildRTLIndex(const BaseDirs: TArray<string>);
    procedure BuildStaticHelpers;
    procedure SetSearchPaths(const Paths: TArray<string>);
    function LookupType(const VarName, ContextFile: string; ContextLine: Integer = -1; const BufferText: string = ''): string;
    function GetMethodsOfType(const TypeName, ContextFile: string; IsSelfAccess: Boolean = False): TArray<TSymbolInfo>;
    function GetTypeDefinition(const TypeName: string): string;
  end;

var
  GSymbolIndex: TSymbolIndex;

implementation

function CarregarUnitSemBloqueio(const Caminho: string): string;
var
  FStream: TFileStream;
  SStream: TStringStream;
begin
  Result := '';
  try
    FStream := TFileStream.Create(Caminho, fmOpenRead or fmShareDenyNone);
    try
      SStream := TStringStream.Create('', TEncoding.UTF8);
      try
        SStream.CopyFrom(FStream, 0);
        Result := SStream.DataString;
      finally
        SStream.Free;
      end;
    finally
      FStream.Free;
    end;
  except
    try
      Result := TFile.ReadAllText(Caminho);
    except
      Result := '';
    end;
  end;
end;

function CortarNaImplementation(const Texto: string): string;
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
      Inc(P); Continue;
    end;
    if InComment1 then
    begin
      if P^ = #10 then InComment1 := False;
      Inc(P); Continue;
    end;
    if InComment2 then
    begin
      if P^ = '}' then InComment2 := False;
      Inc(P); Continue;
    end;
    if InComment3 then
    begin
      if (P^ = '*') and ((P+1)^ = ')') then
      begin
        InComment3 := False;
        Inc(P, 2);
      end else Inc(P);
      Continue;
    end;

    if P^ = '''' then begin InString := True; Inc(P); Continue; end;
    if (P^ = '/') and ((P+1)^ = '/') then begin InComment1 := True; Inc(P, 2); Continue; end;
    if P^ = '{' then begin InComment2 := True; Inc(P); Continue; end;
    if (P^ = '(') and ((P+1)^ = '*') then begin InComment3 := True; Inc(P, 2); Continue; end;

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

constructor TSymbolIndex.Create;
begin
  FSymbols      := TDictionary<string, TArray<TSymbolInfo>>.Create;
  FTypeMembers  := TDictionary<string, TArray<TSymbolInfo>>.Create;
  FTypeParents  := TDictionary<string, string>.Create;
  FIndexedFiles := TDictionary<string, TDateTime>.Create;
  FTypeLocation := TDictionary<string, string>.Create;
  FGlobalVars   := TDictionary<string, string>.Create;

  FGlobalVars.AddOrSetValue('dados', 'tdados');
  FGlobalVars.AddOrSetValue('dadosori', 'tdados');
  FGlobalVars.AddOrSetValue('application', 'tapplication');
  FGlobalVars.AddOrSetValue('screen', 'tscreen');
  FGlobalVars.AddOrSetValue('printer', 'tprinter');
  FGlobalVars.AddOrSetValue('clipboard', 'tclipboard');
  FGlobalVars.AddOrSetValue('mouse', 'tmouse');

  FTypeParents.AddOrSetValue('tapplication', 'tcomponent');
  FTypeParents.AddOrSetValue('tscreen', 'tcomponent');
  FTypeParents.AddOrSetValue('tprinter', 'tobject');
  FTypeParents.AddOrSetValue('tclipboard', 'tpersistent');
  FTypeParents.AddOrSetValue('tmouse', 'tobject');

  FLock := TCriticalSection.Create;
  BuildStaticHelpers;
end;

destructor TSymbolIndex.Destroy;
begin
  FLock.Free;
  FGlobalVars.Free;
  FIndexedFiles.Free;
  FTypeLocation.Free;
  FTypeParents.Free;
  FTypeMembers.Free;
  FSymbols.Free;
  inherited;
end;

procedure TSymbolIndex.RemoveFileSymbolsUnsafe(const FileName: string);
var
  Key: string;
  Arr: TArray<TSymbolInfo>;
  I, J: Integer;
begin
  for Key in FSymbols.Keys.ToArray do
  begin
    Arr := FSymbols[Key];
    J := 0;
    for I := 0 to High(Arr) do
      if not SameText(Arr[I].FileName, FileName) then
      begin
        Arr[J] := Arr[I];
        Inc(J);
      end;
    if J = 0 then FSymbols.Remove(Key)
    else
    begin
      SetLength(Arr, J);
      FSymbols[Key] := Arr;
    end;
  end;

  for Key in FTypeMembers.Keys.ToArray do
  begin
    Arr := FTypeMembers[Key];
    J := 0;
    for I := 0 to High(Arr) do
      if not SameText(Arr[I].FileName, FileName) then
      begin
        Arr[J] := Arr[I];
        Inc(J);
      end;
    if J = 0 then FTypeMembers.Remove(Key)
    else
    begin
      SetLength(Arr, J);
      FTypeMembers[Key] := Arr;
    end;
  end;
end;

procedure TSymbolIndex.AddSymbolUnsafe(const Sym: TSymbolInfo);
var
  Arr: TArray<TSymbolInfo>;
  Key: string;
begin
  Key := LowerCase(Sym.Name);
  if not FSymbols.TryGetValue(Key, Arr) then SetLength(Arr, 0);
  SetLength(Arr, Length(Arr) + 1);
  Arr[High(Arr)] := Sym;
  FSymbols.AddOrSetValue(Key, Arr);

  if Sym.Kind = skType then
  begin
    if Sym.ParentType <> '' then
      FTypeParents.AddOrSetValue(LowerCase(Sym.Name), Sym.ParentType);

    FTypeLocation.AddOrSetValue(LowerCase(Sym.Name), Sym.FileName);
  end;

  if (Sym.Kind in [skMethod, skProperty, skVar]) and (Sym.TypeName <> '') then
  begin
    Key := LowerCase(Sym.TypeName);
    if not FTypeMembers.TryGetValue(Key, Arr) then SetLength(Arr, 0);
    SetLength(Arr, Length(Arr) + 1);
    Arr[High(Arr)] := Sym;
    FTypeMembers.AddOrSetValue(Key, Arr);
  end;
end;

procedure TSymbolIndex.SetSearchPaths(const Paths: TArray<string>);
var
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(FSearchPaths, Length(Paths));
    for I := 0 to High(Paths) do
      FSearchPaths[I] := Paths[I];
  finally
    FLock.Leave;
  end;
end;

procedure TSymbolIndex.IndexFile(const Caminho: string; InterfaceOnly: Boolean = False);
var
  ModTime: TDateTime;
  LastTime: TDateTime;
  Extrato: TExtratoUnit;
  Sym: TSymbolInfo;
  I: Integer;
  ConteudoBruto: string;
  DB: TSQLiteEngine;
  AllSyms: TArray<TSymbolInfo>;
begin
  if not FileExists(Caminho) then Exit;
  FileAge(Caminho, ModTime);

  FLock.Enter;
  try
    if FIndexedFiles.TryGetValue(Caminho, LastTime) then
      if LastTime >= ModTime then Exit;
  finally
    FLock.Leave;
  end;

  ConteudoBruto := CarregarUnitSemBloqueio(Caminho);
  if InterfaceOnly then
    ConteudoBruto := CortarNaImplementation(ConteudoBruto);

  Extrato := ExtrairMetodosEPropriedades(ConteudoBruto);

  FLock.Enter;
  try
    RemoveFileSymbolsUnsafe(Caminho);
    Sym.FileName := Caminho;

    for I := 0 to High(Extrato.Tipos) do
    begin
      if Pos('.', Extrato.Tipos[I].Utilizavel) > 0 then Continue;
      Sym.Name := Extrato.Tipos[I].Utilizavel;
      Sym.Signature := Extrato.Tipos[I].Visual;
      Sym.TypeName := Extrato.Tipos[I].TipoNome;
      Sym.DataType := Extrato.Tipos[I].TipoRetorno;
      Sym.Kind := skType;
      Sym.Line := Extrato.Tipos[I].Linha;
      Sym.Visibility := Extrato.Tipos[I].Visibilidade;
      Sym.ParentType := Extrato.Tipos[I].ParentType;
      Sym.InheritDepth := 0;
      AddSymbolUnsafe(Sym);
    end;

    for I := 0 to High(Extrato.Variaveis) do
    begin
      if Pos('.', Extrato.Variaveis[I].Utilizavel) > 0 then Continue;
      Sym.Name := Extrato.Variaveis[I].Utilizavel;
      Sym.Signature := Extrato.Variaveis[I].Visual;
      Sym.TypeName := Extrato.Variaveis[I].TipoNome;
      Sym.DataType := Extrato.Variaveis[I].TipoRetorno;
      Sym.Kind := skVar;
      Sym.Line := Extrato.Variaveis[I].Linha;
      Sym.Visibility := Extrato.Variaveis[I].Visibilidade;
      Sym.ParentType := '';
      Sym.InheritDepth := 0;
      AddSymbolUnsafe(Sym);
    end;

    for I := 0 to High(Extrato.VariaveisLocais) do
    begin
      if Pos('.', Extrato.VariaveisLocais[I].Utilizavel) > 0 then Continue;
      Sym.Name := Extrato.VariaveisLocais[I].Utilizavel;
      Sym.Signature := Extrato.VariaveisLocais[I].Visual;
      Sym.TypeName := Extrato.VariaveisLocais[I].TipoNome;
      Sym.DataType := Extrato.VariaveisLocais[I].TipoRetorno;
      Sym.Kind := skVar;
      Sym.Line := Extrato.VariaveisLocais[I].Linha;
      Sym.Visibility := Extrato.VariaveisLocais[I].Visibilidade;
      Sym.ParentType := '';
      Sym.InheritDepth := 0;
      AddSymbolUnsafe(Sym);
    end;

    for I := 0 to High(Extrato.Metodos) do
    begin
      if Pos('.', Extrato.Metodos[I].Utilizavel) > 0 then Continue;
      Sym.Name := Extrato.Metodos[I].Utilizavel;
      Sym.Signature := Extrato.Metodos[I].Visual;
      Sym.TypeName := Extrato.Metodos[I].TipoNome;
      Sym.DataType := Extrato.Metodos[I].TipoRetorno;
      Sym.Kind := skMethod;
      Sym.Line := Extrato.Metodos[I].Linha;
      Sym.Visibility := Extrato.Metodos[I].Visibilidade;
      Sym.ParentType := '';
      Sym.InheritDepth := 0;
      AddSymbolUnsafe(Sym);
    end;

    for I := 0 to High(Extrato.Propriedades) do
    begin
      if Pos('.', Extrato.Propriedades[I].Utilizavel) > 0 then Continue;
      Sym.Name := Extrato.Propriedades[I].Utilizavel;
      Sym.Signature := Extrato.Propriedades[I].Visual;
      Sym.TypeName := Extrato.Propriedades[I].TipoNome;
      Sym.DataType := Extrato.Propriedades[I].TipoRetorno;
      Sym.Kind := skProperty;
      Sym.Line := Extrato.Propriedades[I].Linha;
      Sym.Visibility := Extrato.Propriedades[I].Visibilidade;
      Sym.ParentType := '';
      Sym.InheritDepth := 0;
      AddSymbolUnsafe(Sym);
    end;

    for I := 0 to High(Extrato.Constantes) do
    begin
      if Pos('.', Extrato.Constantes[I].Utilizavel) > 0 then Continue;
      Sym.Name := Extrato.Constantes[I].Utilizavel;
      Sym.Signature := Extrato.Constantes[I].Visual;
      Sym.TypeName := Extrato.Constantes[I].TipoNome;
      Sym.DataType := Extrato.Constantes[I].TipoRetorno;
      Sym.Kind := skConst;
      Sym.Line := Extrato.Constantes[I].Linha;
      Sym.Visibility := Extrato.Constantes[I].Visibilidade;
      Sym.ParentType := '';
      Sym.InheritDepth := 0;
      AddSymbolUnsafe(Sym);
    end;

    FIndexedFiles.AddOrSetValue(Caminho, ModTime);
  finally
    FLock.Leave;
  end;

  DB := DBForFile(Caminho);
  if Assigned(DB) and DB.IsConnected then
  begin
    SetLength(AllSyms, 0);

    for I := 0 to High(Extrato.Tipos) do
    begin
      if Pos('.', Extrato.Tipos[I].Utilizavel) > 0 then Continue;
      SetLength(AllSyms, Length(AllSyms) + 1);
      with AllSyms[High(AllSyms)] do
      begin
        Name := Extrato.Tipos[I].Utilizavel;
        Signature := Extrato.Tipos[I].Visual;
        TypeName := Extrato.Tipos[I].TipoNome;
        DataType := Extrato.Tipos[I].TipoRetorno;
        Kind := skType;
        FileName := Caminho;
        Line := Extrato.Tipos[I].Linha;
        Visibility := Extrato.Tipos[I].Visibilidade;
        ParentType := Extrato.Tipos[I].ParentType;
        InheritDepth := 0;
      end;
    end;

    for I := 0 to High(Extrato.Variaveis) do
    begin
      if Pos('.', Extrato.Variaveis[I].Utilizavel) > 0 then Continue;
      SetLength(AllSyms, Length(AllSyms) + 1);
      with AllSyms[High(AllSyms)] do
      begin
        Name := Extrato.Variaveis[I].Utilizavel;
        Signature := Extrato.Variaveis[I].Visual;
        TypeName := Extrato.Variaveis[I].TipoNome;
        DataType := Extrato.Variaveis[I].TipoRetorno;
        Kind := skVar;
        FileName := Caminho;
        Line := Extrato.Variaveis[I].Linha;
        Visibility := Extrato.Variaveis[I].Visibilidade;
        ParentType := '';
        InheritDepth := 0;
      end;
    end;

    for I := 0 to High(Extrato.VariaveisLocais) do
    begin
      if Pos('.', Extrato.VariaveisLocais[I].Utilizavel) > 0 then Continue;
      SetLength(AllSyms, Length(AllSyms) + 1);
      with AllSyms[High(AllSyms)] do
      begin
        Name := Extrato.VariaveisLocais[I].Utilizavel;
        Signature := Extrato.VariaveisLocais[I].Visual;
        TypeName := Extrato.VariaveisLocais[I].TipoNome;
        DataType := Extrato.VariaveisLocais[I].TipoRetorno;
        Kind := skVar;
        FileName := Caminho;
        Line := Extrato.VariaveisLocais[I].Linha;
        Visibility := Extrato.VariaveisLocais[I].Visibilidade;
        ParentType := '';
        InheritDepth := 0;
      end;
    end;

    for I := 0 to High(Extrato.Metodos) do
    begin
      if Pos('.', Extrato.Metodos[I].Utilizavel) > 0 then Continue;
      SetLength(AllSyms, Length(AllSyms) + 1);
      with AllSyms[High(AllSyms)] do
      begin
        Name := Extrato.Metodos[I].Utilizavel;
        Signature := Extrato.Metodos[I].Visual;
        TypeName := Extrato.Metodos[I].TipoNome;
        DataType := Extrato.Metodos[I].TipoRetorno;
        Kind := skMethod;
        FileName := Caminho;
        Line := Extrato.Metodos[I].Linha;
        Visibility := Extrato.Metodos[I].Visibilidade;
        ParentType := '';
        InheritDepth := 0;
      end;
    end;

    for I := 0 to High(Extrato.Propriedades) do
    begin
      if Pos('.', Extrato.Propriedades[I].Utilizavel) > 0 then Continue;
      SetLength(AllSyms, Length(AllSyms) + 1);
      with AllSyms[High(AllSyms)] do
      begin
        Name := Extrato.Propriedades[I].Utilizavel;
        Signature := Extrato.Propriedades[I].Visual;
        TypeName := Extrato.Propriedades[I].TipoNome;
        DataType := Extrato.Propriedades[I].TipoRetorno;
        Kind := skProperty;
        FileName := Caminho;
        Line := Extrato.Propriedades[I].Linha;
        Visibility := Extrato.Propriedades[I].Visibilidade;
        ParentType := '';
        InheritDepth := 0;
      end;
    end;

    for I := 0 to High(Extrato.Constantes) do
    begin
      if Pos('.', Extrato.Constantes[I].Utilizavel) > 0 then Continue;
      SetLength(AllSyms, Length(AllSyms) + 1);
      with AllSyms[High(AllSyms)] do
      begin
        Name := Extrato.Constantes[I].Utilizavel;
        Signature := Extrato.Constantes[I].Visual;
        TypeName := Extrato.Constantes[I].TipoNome;
        DataType := Extrato.Constantes[I].TipoRetorno;
        Kind := skConst;
        FileName := Caminho;
        Line := Extrato.Constantes[I].Linha;
        Visibility := Extrato.Constantes[I].Visibilidade;
        ParentType := '';
        InheritDepth := 0;
      end;
    end;

    DB.UpsertFileSymbols(Caminho, AllSyms);
  end;
end;

procedure TSymbolIndex.InvalidateFile(const Caminho: string);
begin
  FLock.Enter;
  try
    FIndexedFiles.Remove(Caminho);
  finally
    FLock.Leave;
  end;
end;

procedure TSymbolIndex.BuildProjectIndex(const ProjectFiles: TArray<string>);
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      Caminho, Conteudo: string;
      P, PStart: PChar;
      Token, TypeName: string;
      InVarSection: Boolean;
      TempNames: TArray<string>;
      TempCount, I: Integer;
    begin
      SetLength(TempNames, 64);
      for Caminho in ProjectFiles do
      begin
        if not FileExists(Caminho) then Continue;
        try
          Conteudo := TFile.ReadAllText(Caminho);
          Conteudo := CortarNaImplementation(Conteudo);
        except
          Continue;
        end;

        InVarSection := False;
        TempCount := 0;
        P := PChar(Conteudo);
        while P^ <> #0 do
        begin
          while CharInSet(P^, [#1..#32]) do Inc(P);
          if P^ = #0 then Break;

          if P^ = '{' then
          begin
            Inc(P);
            while (P^ <> #0) and (P^ <> '}') do Inc(P);
            if P^ = '}' then Inc(P);
            Continue;
          end;
          if (P^ = '/') and ((P+1)^ = '/') then
          begin
            while (P^ <> #0) and not CharInSet(P^, [#10,#13]) do Inc(P);
            Continue;
          end;
          if (P^ = '(') and ((P+1)^ = '*') then
          begin
            Inc(P, 2);
            while (P^ <> #0) and not ((P^ = '*') and ((P+1)^ = ')')) do Inc(P);
            if P^ <> #0 then Inc(P, 2);
            Continue;
          end;

          if P^ = '''' then
          begin
            Inc(P);
            while (P^ <> #0) and (P^ <> '''') do Inc(P);
            if P^ <> #0 then Inc(P);
            Continue;
          end;

          if P^ = '[' then
          begin
            Inc(P);
            while (P^ <> #0) and (P^ <> ']') do Inc(P);
            if P^ <> #0 then Inc(P);
            Continue;
          end;

          if CharInSet(P^, ['a'..'z','A'..'Z','_']) then
          begin
            PStart := P;
            while CharInSet(P^, ['a'..'z','A'..'Z','0'..'9','_']) do Inc(P);
            SetString(Token, PStart, P - PStart);

            if SameText(Token, 'implementation') then Break;

            if SameText(Token, 'var') or SameText(Token, 'threadvar') then
            begin
              InVarSection := True;
              TempCount := 0;
            end
            else if SameText(Token, 'type') or SameText(Token, 'const') or
                    SameText(Token, 'uses') or SameText(Token, 'procedure') or
                    SameText(Token, 'function') then
            begin
              InVarSection := False;
              TempCount := 0;
            end
            else
            begin
              while CharInSet(P^, [' ', #9]) do Inc(P);
              if P^ = '=' then
              begin
                Inc(P);
                while CharInSet(P^, [' ', #9]) do Inc(P);
                if (StrLIComp(P, 'class', 5) = 0) or
                   (StrLIComp(P, 'record', 6) = 0) or
                   (StrLIComp(P, 'interface', 9) = 0) then
                begin
                  FLock.Enter;
                  try
                    FTypeLocation.AddOrSetValue(LowerCase(Token), Caminho);
                  finally
                    FLock.Leave;
                  end;
                end;
                TempCount := 0;
              end
              else if InVarSection then
              begin
                if Pos('.', Token) = 0 then
                begin
                  if TempCount >= Length(TempNames) then
                    SetLength(TempNames, Length(TempNames) + 64);
                  TempNames[TempCount] := Token;
                  Inc(TempCount);
                end;
              end;
            end;
          end
          else if InVarSection and (P^ = ':') then
          begin
            Inc(P);
            while CharInSet(P^, [' ', #9, #13, #10]) do Inc(P);
            PStart := P;
            while CharInSet(P^, ['a'..'z','A'..'Z','0'..'9','_','.']) do Inc(P);
            SetString(TypeName, PStart, P - PStart);

            if (TypeName <> '') and (TempCount > 0) then
            begin
              FLock.Enter;
              try
                for I := 0 to TempCount - 1 do
                  FGlobalVars.AddOrSetValue(LowerCase(TempNames[I]), TypeName);
              finally
                FLock.Leave;
              end;
            end;
            TempCount := 0;
            while (P^ <> #0) and (P^ <> ';') do Inc(P);
            if P^ = ';' then Inc(P);
          end
          else if P^ = ',' then
          begin
            Inc(P);
          end
          else if P^ = ';' then
          begin
            TempCount := 0;
            Inc(P);
          end
          else
          begin
            TempCount := 0;
            Inc(P);
          end;
        end;
      end;
    end
  ).Start;
end;

procedure TSymbolIndex.BuildStaticHelpers;

  procedure AddM(const Owner, Name, Sig: string; Kind: TSymbolKind; Vis: Integer = 2);
  var
    Sym: TSymbolInfo;
    Arr: TArray<TSymbolInfo>;
    Key: string;
  begin
    Sym.Name       := Name;
    Sym.Signature  := Sig;
    Sym.TypeName   := Owner;
    Sym.DataType   := '';
    Sym.Kind       := Kind;
    Sym.FileName   := '<builtin>';
    Sym.Line       := 0;
    Sym.Visibility := Vis;
    Sym.ParentType := '';
    Sym.InheritDepth := 0;
    Key := LowerCase(Owner);
    FLock.Enter;
    try
      if not FTypeMembers.TryGetValue(Key, Arr) then SetLength(Arr, 0);
      SetLength(Arr, Length(Arr) + 1);
      Arr[High(Arr)] := Sym;
      FTypeMembers.AddOrSetValue(Key, Arr);
    finally
      FLock.Leave;
    end;
  end;

  procedure F(const O, N, S: string); begin AddM(O, N, S, skMethod);   end;
  procedure P(const O, N, S: string); begin AddM(O, N, S, skProperty); end;

begin
  F('tobject', 'Create', 'constructor Create');
  F('tobject', 'Free', 'procedure Free');
  F('tobject', 'DisposeOf', 'procedure DisposeOf');
  F('tobject', 'InitInstance', 'class function InitInstance(Instance: Pointer): TObject');
  F('tobject', 'CleanupInstance', 'procedure CleanupInstance');
  F('tobject', 'ClassType', 'function ClassType: TClass');
  F('tobject', 'ClassName', 'class function ClassName: string');
  F('tobject', 'ClassNameIs', 'class function ClassNameIs(const Name: string): Boolean');
  F('tobject', 'ClassParent', 'class function ClassParent: TClass');
  F('tobject', 'ClassInfo', 'class function ClassInfo: Pointer');
  F('tobject', 'InstanceSize', 'class function InstanceSize: Integer');
  F('tobject', 'InheritsFrom', 'class function InheritsFrom(AClass: TClass): Boolean');
  F('tobject', 'MethodAddress', 'class function MethodAddress(const Name: ShortString): Pointer');
  F('tobject', 'MethodName', 'class function MethodName(Address: Pointer): string');
  F('tobject', 'FieldAddress', 'function FieldAddress(const Name: ShortString): Pointer');
  F('tobject', 'GetInterface', 'function GetInterface(const IID: TGUID; out Obj): Boolean');
  F('tobject', 'SafeCallException', 'function SafeCallException(ExceptObject: TObject; ExceptAddr: Pointer): HRESULT');
  F('tobject', 'AfterConstruction', 'procedure AfterConstruction');
  F('tobject', 'BeforeDestruction', 'procedure BeforeDestruction');
  F('tobject', 'Dispatch', 'procedure Dispatch(var Message)');
  F('tobject', 'DefaultHandler', 'procedure DefaultHandler(var Message)');
  F('tobject', 'NewInstance', 'class function NewInstance: TObject');
  F('tobject', 'FreeInstance', 'procedure FreeInstance');
  F('tobject', 'ToString', 'function ToString: string');
  F('tobject', 'GetHashCode', 'function GetHashCode: Integer');
  F('tobject', 'Equals', 'function Equals(Obj: TObject): Boolean');

  F('tstringhelper','Contains',       'function Contains(const Value: string): Boolean');
  F('tstringhelper','StartsWith',     'function StartsWith(const Value: string): Boolean');
  F('tstringhelper','EndsWith',       'function EndsWith(const Value: string): Boolean');
  F('tstringhelper','ToUpper',        'function ToUpper: string');
  F('tstringhelper','ToLower',        'function ToLower: string');
  F('tstringhelper','Trim',           'function Trim: string');
  F('tstringhelper','TrimLeft',       'function TrimLeft: string');
  F('tstringhelper','TrimRight',      'function TrimRight: string');
  F('tstringhelper','IsEmpty',        'function IsEmpty: Boolean');
  F('tstringhelper','IsNullOrEmpty',  'class function IsNullOrEmpty(const Value: string): Boolean');
  F('tstringhelper','IsNullOrWhiteSpace','class function IsNullOrWhiteSpace(const Value: string): Boolean');
  F('tstringhelper','ToInteger',      'function ToInteger: Integer');
  F('tstringhelper','ToInt64',        'function ToInt64: Int64');
  F('tstringhelper','ToDouble',       'function ToDouble: Double');
  F('tstringhelper','ToBoolean',      'function ToBoolean: Boolean');
  F('tstringhelper','ToCharArray',    'function ToCharArray: TArray<Char>');
  F('tstringhelper','Substring',      'function Substring(StartIndex: Integer): string');
  F('tstringhelper','IndexOf',        'function IndexOf(Value: Char): Integer');
  F('tstringhelper','LastIndexOf',    'function LastIndexOf(Value: Char): Integer');
  F('tstringhelper','Insert',         'function Insert(StartIndex: Integer; const Value: string): string');
  F('tstringhelper','Remove',         'function Remove(StartIndex: Integer): string');
  F('tstringhelper','Replace',        'function Replace(OldValue, NewValue: string): string');
  F('tstringhelper','Split',          'function Split(const Separator: TArray<Char>): TArray<string>');
  F('tstringhelper','Join',           'class function Join(const Separator: string; const Values: TArray<string>): string');
  F('tstringhelper','Format',         'class function Format(const Fmt: string; const Args: array of const): string');
  F('tstringhelper','PadLeft',        'function PadLeft(TotalWidth: Integer): string');
  F('tstringhelper','PadRight',       'function PadRight(TotalWidth: Integer): string');
  F('tstringhelper','QuotedString',   'function QuotedString: string');
  F('tstringhelper','DeQuotedString', 'function DeQuotedString: string');
  F('tstringhelper','CountChar',      'function CountChar(const C: Char): Integer');
  F('tstringhelper','Compare',        'class function Compare(const StrA, StrB: string): Integer');
  P('tstringhelper','Length',         'property Length: Integer');
  P('tstringhelper','Chars',          'property Chars[Index: Integer]: Char');

  F('tintegerhelper','ToString',    'function ToString: string');
  F('tintegerhelper','ToHexString', 'function ToHexString: string');
  F('tintegerhelper','Parse',       'class function Parse(const S: string): Integer');
  F('tintegerhelper','TryParse',    'class function TryParse(const S: string; out Value: Integer): Boolean');
  P('tintegerhelper','MinValue',    'property MinValue: Integer');
  P('tintegerhelper','MaxValue',    'property MaxValue: Integer');

  F('tint64helper','ToString',    'function ToString: string');
  F('tint64helper','ToHexString', 'function ToHexString: string');
  F('tint64helper','Parse',       'class function Parse(const S: string): Int64');
  F('tint64helper','TryParse',    'class function TryParse(const S: string; out Value: Int64): Boolean');

  F('tdoublehelper',   'ToString', 'function ToString: string');
  F('tdoublehelper',   'Parse',    'class function Parse(const S: string): Double');
  F('tdoublehelper',   'TryParse', 'class function TryParse(const S: string; out Value: Double): Boolean');
  F('tsinglehelper',   'ToString', 'function ToString: string');
  F('textendedhelper', 'ToString', 'function ToString: string');

  F('tbooleanhelper','ToString',    'function ToString: string');
  F('tbooleanhelper','Parse',       'class function Parse(const S: string): Boolean');
  F('tbooleanhelper','TryParse',    'class function TryParse(const S: string; out Value: Boolean): Boolean');
  P('tbooleanhelper','TrueString',  'property TrueString: string');
  P('tbooleanhelper','FalseString', 'property FalseString: string');

  F('tcharhelper','IsLetter',        'class function IsLetter(C: Char): Boolean');
  F('tcharhelper','IsDigit',         'class function IsDigit(C: Char): Boolean');
  F('tcharhelper','IsWhiteSpace',    'class function IsWhiteSpace(C: Char): Boolean');
  F('tcharhelper','IsUpper',         'class function IsUpper(C: Char): Boolean');
  F('tcharhelper','IsLower',         'class function IsLower(C: Char): Boolean');
  F('tcharhelper','ToUpper',         'function ToUpper: Char');
  F('tcharhelper','ToLower',         'function To Lower: Char');
  F('tcharhelper','IsLetterOrDigit', 'class function IsLetterOrDigit(C: Char): Boolean');
  F('tcharhelper','ToString',        'function ToString: string');

  F('tbytehelper',     'ToString',    'function ToString: string');
  F('tbytehelper',     'ToHexString', 'function ToHexString: string');
  F('twordhelper',     'ToString',    'function ToString: string');
  F('tcardinalhelper', 'ToString',    'function ToString: string');
  F('tcardinalhelper', 'ToHexString', 'function ToHexString: string');
end;

procedure TSymbolIndex.BuildRTLIndex(const BaseDirs: TArray<string>);
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      CacheFile, AppDataFile: string;
      CacheList: TStringList;
      FilesList: TStringList;
      I, J: Integer;
      Dir, Caminho, Conteudo: string;
      Sym: TSymbolInfo;
      TempMembers: TDictionary<string, TList<TSymbolInfo>>;
      TempParents: TDictionary<string, string>;
      Parts: TArray<string>;
      CurrentType, Line: string;
      TempList: TList<TSymbolInfo>;
      Pair: TPair<string, TList<TSymbolInfo>>;
      PPair: TPair<string, string>;
      CacheIsOk: Boolean;
      Extrato: TExtratoUnit;
      EscopoAtual, ParentType, TargetType: string;

      procedure FindPas(const Path: string);
      var
        SR: TSearchRec;
      begin
        if FindFirst(TPath.Combine(Path, '*'), faAnyFile, SR) = 0 then
        begin
          try
            repeat
              if (SR.Name = '.') or (SR.Name = '..') then Continue;
              if (SR.Attr and faDirectory) <> 0 then
                FindPas(TPath.Combine(Path, SR.Name))
              else if SameText(ExtractFileExt(SR.Name), '.pas') then
                FilesList.Add(TPath.Combine(Path, SR.Name));
            until FindNext(SR) <> 0;
          finally
            System.SysUtils.FindClose(SR);
          end;
        end;
      end;

    begin
      CacheFile := TPath.Combine(ExtractFilePath(GetModuleName(HInstance)), 'rtl_cache.txt');
      AppDataFile := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'CodeInsight'), 'rtl_cache.txt');

      if not FileExists(CacheFile) and FileExists(AppDataFile) then
        CacheFile := AppDataFile;

      CacheIsOk := False;
      if FileExists(CacheFile) then
      begin
        CacheList := TStringList.Create;
        try
          try
            CacheList.LoadFromFile(CacheFile, TEncoding.UTF8);
            CurrentType := '';
            TempList := nil;

            if (CacheList.Count > 0) and (CacheList[0] = 'V=3') then
            begin
              CacheIsOk := True;
              for I := 1 to CacheList.Count - 1 do
              begin
                Line := CacheList[I];
                if Line.StartsWith('T=') then
                begin
                  if (CurrentType <> '') and Assigned(TempList) and (TempList.Count > 0) then
                  begin
                    FLock.Enter;
                    try
                      FTypeMembers.AddOrSetValue(CurrentType, TempList.ToArray);
                    finally
                      FLock.Leave;
                    end;
                  end;
                  if Assigned(TempList) then FreeAndNil(TempList);

                  Parts := Line.Substring(2).Split(['|']);
                  if Length(Parts) >= 1 then
                  begin
                    CurrentType := Parts[0];
                    TempList := TList<TSymbolInfo>.Create;
                    if (Length(Parts) >= 2) and (Parts[1] <> '') then
                    begin
                      FLock.Enter;
                      try
                        FTypeParents.AddOrSetValue(CurrentType, Parts[1]);
                      finally
                        FLock.Leave;
                      end;
                    end;
                  end
                  else
                    CurrentType := '';
                end
                else if Line.StartsWith('M=') and (CurrentType <> '') and Assigned(TempList) then
                begin
                  Parts := Line.Substring(2).Split(['|']);
                  if Length(Parts) >= 4 then
                  begin
                    Sym.Name := Parts[0];
                    Sym.Signature := Parts[1];
                    Sym.Kind := TSymbolKind(StrToIntDef(Parts[2], 0));
                    Sym.Visibility := StrToIntDef(Parts[3], 2);
                    Sym.TypeName := CurrentType;
                    if Length(Parts) >= 5 then
                      Sym.DataType := Parts[4]
                    else
                      Sym.DataType := '';
                    Sym.FileName := '<rtl_cache>';
                    Sym.Line := 0;
                    Sym.ParentType := '';
                    Sym.InheritDepth := 0;
                    if Pos('.', Sym.Name) = 0 then
                      TempList.Add(Sym);
                  end;
                end;
              end;

              if (CurrentType <> '') and Assigned(TempList) and (TempList.Count > 0) then
              begin
                FLock.Enter;
                try
                  FTypeMembers.AddOrSetValue(CurrentType, TempList.ToArray);
                finally
                  FLock.Leave;
                end;
              end;
              if Assigned(TempList) then FreeAndNil(TempList);
            end;
          except
          end;
        finally
          CacheList.Free;
        end;

        if CacheIsOk then Exit;
      end;

      if Length(BaseDirs) = 0 then Exit;

      TempMembers := TDictionary<string, TList<TSymbolInfo>>.Create;
      TempParents := TDictionary<string, string>.Create;
      FilesList := TStringList.Create;
      try
        for Dir in BaseDirs do
        begin
          if DirectoryExists(Dir) then
            FindPas(Dir);
        end;

        for I := 0 to FilesList.Count - 1 do
        begin
          Caminho := FilesList[I];
          try
            Conteudo := TFile.ReadAllText(Caminho);
            Conteudo := CortarNaImplementation(Conteudo);
            Extrato := ExtrairMetodosEPropriedades(Conteudo);

            for J := 0 to High(Extrato.Tipos) do
            begin
              if Pos('.', Extrato.Tipos[J].Utilizavel) > 0 then Continue;
              EscopoAtual := LowerCase(Extrato.Tipos[J].Utilizavel);
              ParentType := LowerCase(Extrato.Tipos[J].ParentType);

              if ParentType <> '' then
                TempParents.AddOrSetValue(EscopoAtual, ParentType);

              if not TempMembers.ContainsKey(EscopoAtual) then
                TempMembers.AddOrSetValue(EscopoAtual, TList<TSymbolInfo>.Create);
            end;

            for J := 0 to High(Extrato.Metodos) do
            begin
              if Extrato.Metodos[J].TipoNome = '' then Continue;
              if Pos('.', Extrato.Metodos[J].Utilizavel) > 0 then Continue;
              TargetType := LowerCase(Extrato.Metodos[J].TipoNome);
              if not TempMembers.TryGetValue(TargetType, TempList) then
              begin
                TempList := TList<TSymbolInfo>.Create;
                TempMembers.AddOrSetValue(TargetType, TempList);
              end;
              Sym.Name := Extrato.Metodos[J].Utilizavel;
              Sym.Signature := Extrato.Metodos[J].Visual;
              Sym.TypeName := TargetType;
              Sym.DataType := Extrato.Metodos[J].TipoRetorno;
              Sym.Kind := skMethod;
              Sym.FileName := Caminho;
              Sym.Line := 0;
              Sym.Visibility := Extrato.Metodos[J].Visibilidade;
              Sym.ParentType := '';
              Sym.InheritDepth := 0;
              TempList.Add(Sym);
            end;

            for J := 0 to High(Extrato.Propriedades) do
            begin
              if Extrato.Propriedades[J].TipoNome = '' then Continue;
              if Pos('.', Extrato.Propriedades[J].Utilizavel) > 0 then Continue;
              TargetType := LowerCase(Extrato.Propriedades[J].TipoNome);
              if not TempMembers.TryGetValue(TargetType, TempList) then
              begin
                TempList := TList<TSymbolInfo>.Create;
                TempMembers.AddOrSetValue(TargetType, TempList);
              end;
              Sym.Name := Extrato.Propriedades[J].Utilizavel;
              Sym.Signature := Extrato.Propriedades[J].Visual;
              Sym.TypeName := TargetType;
              Sym.DataType := Extrato.Propriedades[J].TipoRetorno;
              Sym.Kind := skProperty;
              Sym.FileName := Caminho;
              Sym.Line := 0;
              Sym.Visibility := Extrato.Propriedades[J].Visibilidade;
              Sym.ParentType := '';
              Sym.InheritDepth := 0;
              TempList.Add(Sym);
            end;

            for J := 0 to High(Extrato.Variaveis) do
            begin
              if Extrato.Variaveis[J].TipoNome = '' then Continue;
              if Pos('.', Extrato.Variaveis[J].Utilizavel) > 0 then Continue;
              TargetType := LowerCase(Extrato.Variaveis[J].TipoNome);
              if not TempMembers.TryGetValue(TargetType, TempList) then
              begin
                TempList := TList<TSymbolInfo>.Create;
                TempMembers.AddOrSetValue(TargetType, TempList);
              end;
              Sym.Name := Extrato.Variaveis[J].Utilizavel;
              Sym.Signature := Extrato.Variaveis[J].Visual;
              Sym.TypeName := TargetType;
              Sym.DataType := Extrato.Variaveis[J].TipoRetorno;
              Sym.Kind := skVar;
              Sym.FileName := Caminho;
              Sym.Line := 0;
              Sym.Visibility := Extrato.Variaveis[J].Visibilidade;
              Sym.ParentType := '';
              Sym.InheritDepth := 0;
              TempList.Add(Sym);
            end;

          except
            Continue;
          end;
        end;

        ForceDirectories(ExtractFilePath(AppDataFile));
        CacheList := TStringList.Create;
        try
          CacheList.Add('V=3');
          for Pair in TempMembers do
          begin
            if Pair.Value.Count = 0 then Continue;
            ParentType := '';
            TempParents.TryGetValue(Pair.Key, ParentType);
            CacheList.Add('T=' + Pair.Key + '|' + ParentType);

            for J := 0 to Pair.Value.Count - 1 do
            begin
              Sym := Pair.Value[J];
              CacheList.Add('M=' + Sym.Name + '|' + Sym.Signature + '|' + IntToStr(Integer(Sym.Kind)) + '|' + IntToStr(Sym.Visibility) + '|' + Sym.DataType);
            end;
          end;
          try
            CacheList.SaveToFile(AppDataFile, TEncoding.UTF8);
          except
          end;
        finally
          CacheList.Free;
        end;

        FLock.Enter;
        try
          for Pair in TempMembers do
            if Pair.Value.Count > 0 then
              FTypeMembers.AddOrSetValue(Pair.Key, Pair.Value.ToArray);
          for PPair in TempParents do
            FTypeParents.AddOrSetValue(PPair.Key, PPair.Value);
        finally
          FLock.Leave;
        end;

      finally
        for Pair in TempMembers do
          Pair.Value.Free;
        TempMembers.Free;
        TempParents.Free;
        FilesList.Free;
      end;
    end
  ).Start;
end;

function TSymbolIndex.LookupType(const VarName, ContextFile: string; ContextLine: Integer = -1; const BufferText: string = ''): string;
var
  Candidates: TList<TSymbolInfo>;
  Arr: TArray<TSymbolInfo>;
  Sym, BestSym: TSymbolInfo;
  UsesList: TArray<string>;
  U, BaseName: string;
  DB: TSQLiteEngine;
  Score, BestScore, Dist, MinDist: Integer;
begin
  Result := '';
  Candidates := TList<TSymbolInfo>.Create;
  try
    FLock.Enter;
    try
      if FSymbols.TryGetValue(LowerCase(VarName), Arr) then
        Candidates.AddRange(Arr);
    finally
      FLock.Leave;
    end;

    DB := GLocalDB;
    if Assigned(DB) and DB.IsConnected then
    begin
      Arr := DB.QuerySymbolByName(LowerCase(VarName));
      Candidates.AddRange(Arr);
    end;

    DB := GPublicDB;
    if Assigned(DB) and DB.IsConnected then
    begin
      Arr := DB.QuerySymbolByName(LowerCase(VarName));
      Candidates.AddRange(Arr);
    end;

    if Candidates.Count = 0 then
    begin
      FLock.Enter;
      try
        if FGlobalVars.TryGetValue(LowerCase(VarName), Result) then Exit;
      finally
        FLock.Leave;
      end;
      Exit;
    end;

    if BufferText <> '' then
      UsesList := ExtrairUses(BufferText)
    else
      UsesList := nil;

    BestScore := -1;
    MinDist := MaxInt;
    BestSym.DataType := '';

    for Sym in Candidates do
    begin
      Score := 0;
      Dist := MaxInt;

      if SameText(Sym.FileName, ContextFile) then
      begin
        Score := 3;
        if ContextLine >= 0 then Dist := Abs(Sym.Line - ContextLine);
      end
      else if SameText(Sym.FileName, '<builtin>') or SameText(Sym.FileName, '<rtl_cache>') then
      begin
        Score := 1;
      end
      else
      begin
        BaseName := ChangeFileExt(ExtractFileName(Sym.FileName), '');
        for U in UsesList do
        begin
          if SameText(U, BaseName) then
          begin
            Score := 2;
            Break;
          end;
        end;
      end;

      if Score > BestScore then
      begin
        BestScore := Score;
        BestSym := Sym;
        MinDist := Dist;
      end
      else if (Score = BestScore) and (Score = 3) and (Dist < MinDist) then
      begin
        BestSym := Sym;
        MinDist := Dist;
      end;
    end;

    if BestScore >= 0 then Result := BestSym.DataType
    else if Candidates.Count > 0 then Result := Candidates[0].DataType;

  finally
    Candidates.Free;
  end;
end;

function TSymbolIndex.GetTypeDefinition(const TypeName: string): string;
var
  Arr: TArray<TSymbolInfo>;
  Sym: TSymbolInfo;
begin
  Result := '';
  FLock.Enter;
  try
    if FSymbols.TryGetValue(LowerCase(TypeName), Arr) then
    begin
      for Sym in Arr do
        if Sym.Kind = skType then
        begin
          Result := Sym.DataType;
          Exit;
        end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TSymbolIndex.GetMethodsOfType(const TypeName, ContextFile: string; IsSelfAccess: Boolean = False): TArray<TSymbolInfo>;
var
  Visited: TList<string>;
  SeenSignatures: TDictionary<string, Boolean>;

  function ExtractParamsFromSig(const Sig: string): string;
  var
    P, StartP: PChar;
    Depth: Integer;
  begin
    Result := '';
    P := PChar(Sig);
    while (P^ <> #0) and (P^ <> '(') do Inc(P);
    if P^ <> '(' then Exit;
    StartP := P;
    Depth := 0;
    while P^ <> #0 do
    begin
      if P^ = '(' then Inc(Depth)
      else if P^ = ')' then Dec(Depth);
      if Depth = 0 then
      begin
        SetString(Result, StartP, P - StartP + 1);
        Exit;
      end;
      Inc(P);
    end;
  end;

  function MapPrimitive(const TName: string): string;
  begin
    if SameText(TName, 'string') then Result := 'TStringHelper'
    else if SameText(TName, 'integer') then Result := 'TIntegerHelper'
    else if SameText(TName, 'boolean') then Result := 'TBooleanHelper'
    else if SameText(TName, 'char') then Result := 'TCharHelper'
    else if SameText(TName, 'byte') then Result := 'TByteHelper'
    else if SameText(TName, 'word') then Result := 'TWordHelper'
    else if SameText(TName, 'cardinal') then Result := 'TCardinalHelper'
    else if SameText(TName, 'shortint') then Result := 'TShortIntHelper'
    else if SameText(TName, 'smallint') then Result := 'TSmallIntHelper'
    else if SameText(TName, 'int64') then Result := 'TInt64Helper'
    else if SameText(TName, 'uint64') then Result := 'TUInt64Helper'
    else if SameText(TName, 'single') then Result := 'TSingleHelper'
    else if SameText(TName, 'double') then Result := 'TDoubleHelper'
    else if SameText(TName, 'extended') then Result := 'TExtendedHelper'
    else if SameText(TName, 'nativeint') then Result := 'TNativeIntHelper'
    else if SameText(TName, 'nativeuint') then Result := 'TNativeUIntHelper'
    else Result := TName;
  end;

  procedure PegaMetodosRecursivo(const TName: string; Depth: Integer);
  var
    BaseType, LocationFile, PName: string;
    Arr: TArray<TSymbolInfo>;
    Sym: TSymbolInfo;
    SearchDir, TestPath, PossibleName: string;
    I: Integer;
    DBL: TSQLiteEngine;
    DBP: TSQLiteEngine;
    DBRes: TArray<TSymbolInfo>;
    SigKey, ParamsStr: string;
    CommaPos: Integer;
  begin
    BaseType := LowerCase(MapPrimitive(TName));
    if Visited.Contains(BaseType) then Exit;
    Visited.Add(BaseType);

    Arr := nil;
    if not FTypeMembers.TryGetValue(BaseType, Arr) then
    begin
      if (Arr = nil) or (Length(Arr) = 0) then
      begin
        DBL := GLocalDB;
        if Assigned(DBL) and DBL.IsConnected then
        begin
          FLock.Leave;
          try
            Arr := DBL.QueryTypeMembers(BaseType);
          finally
            FLock.Enter;
          end;
        end;
      end;

      if (Arr = nil) or (Length(Arr) = 0) then
      begin
        DBP := GPublicDB;
        if Assigned(DBP) and DBP.IsConnected then
        begin
          FLock.Leave;
          try
            Arr := DBP.QueryTypeMembers(BaseType);
          finally
            FLock.Enter;
          end;
        end;
      end;

      if (Length(Arr) > 0) and not FTypeMembers.ContainsKey(BaseType) then
        FTypeMembers.AddOrSetValue(BaseType, Arr);

      if (Arr = nil) or (Length(Arr) = 0) then
      begin
        LocationFile := '';
        if not FTypeLocation.TryGetValue(BaseType, LocationFile) then
        begin
          DBL := GLocalDB;
          if Assigned(DBL) and DBL.IsConnected then
          begin
            FLock.Leave;
            try
              DBRes := DBL.QuerySymbolByName(BaseType);
              if Length(DBRes) > 0 then LocationFile := DBRes[0].FileName;
            finally
              FLock.Enter;
            end;
          end;

          if LocationFile = '' then
          begin
            DBP := GPublicDB;
            if Assigned(DBP) and DBP.IsConnected then
            begin
              FLock.Leave;
              try
                DBRes := DBP.QuerySymbolByName(BaseType);
                if Length(DBRes) > 0 then LocationFile := DBRes[0].FileName;
              finally
                FLock.Enter;
              end;
            end;
          end;

          if LocationFile = '' then
          begin
            PossibleName := BaseType;
            if (Length(PossibleName) > 1) and (PossibleName[1] = 't') then
              PossibleName := Copy(PossibleName, 2, MaxInt);

            for I := 0 to High(FSearchPaths) do
            begin
              SearchDir := FSearchPaths[I];
              TestPath := TPath.Combine(SearchDir, PossibleName + '.pas');
              if FileExists(TestPath) then
              begin
                LocationFile := TestPath;
                Break;
              end;
              TestPath := TPath.Combine(SearchDir, 'u' + PossibleName + '.pas');
              if FileExists(TestPath) then
              begin
                LocationFile := TestPath;
                Break;
              end;
              TestPath := TPath.Combine(SearchDir, PossibleName + 's.pas');
              if FileExists(TestPath) then
              begin
                LocationFile := TestPath;
                Break;
              end;
            end;
          end;
        end;

        if LocationFile <> '' then
        begin
          FLock.Leave;
          try
            IndexFile(LocationFile, True);
          finally
            FLock.Enter;
          end;
          FTypeMembers.TryGetValue(BaseType, Arr);
        end;
      end;
    end;

    for Sym in Arr do
    begin
      if not SameText(Sym.FileName, ContextFile) and not SameText(Sym.FileName, '<builtin>') then
      begin
        if Sym.Visibility = 0 then Continue;
        if (Sym.Visibility = 1) and not IsSelfAccess then Continue;
      end;

      SigKey := LowerCase(Sym.Name);
      if Sym.Kind = skMethod then
      begin
        ParamsStr := ExtractParamsFromSig(Sym.Signature);
        ParamsStr := ReplaceText(ParamsStr, ' ', '');
        SigKey := SigKey + '|' + LowerCase(ParamsStr);
      end;

      if SeenSignatures.ContainsKey(SigKey) then Continue;
      SeenSignatures.Add(SigKey, True);

      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Sym;
      Result[High(Result)].InheritDepth := Depth;
    end;

    PName := '';
    if FTypeParents.TryGetValue(BaseType, PName) then
    begin
    end
    else
    begin
      FLock.Leave;
      try
        DBL := GLocalDB;
        if Assigned(DBL) and DBL.IsConnected then
        begin
          DBRes := DBL.QuerySymbolByName(BaseType);
          if (Length(DBRes) > 0) and (DBRes[0].Kind = skType) then PName := DBRes[0].ParentType;
        end;
        if PName = '' then
        begin
          DBP := GPublicDB;
          if Assigned(DBP) and DBP.IsConnected then
          begin
            DBRes := DBP.QuerySymbolByName(BaseType);
            if (Length(DBRes) > 0) and (DBRes[0].Kind = skType) then PName := DBRes[0].ParentType;
          end;
        end;
      finally
        FLock.Enter;
      end;
      if PName <> '' then
        FTypeParents.AddOrSetValue(BaseType, PName);
    end;

    if PName <> '' then
    begin
      CommaPos := Pos(',', PName);
      if CommaPos > 0 then
        PName := Trim(Copy(PName, 1, CommaPos - 1));

      PegaMetodosRecursivo(PName, Depth + 1);
    end;
  end;

begin
  SetLength(Result, 0);
  Visited := TList<string>.Create;
  SeenSignatures := TDictionary<string, Boolean>.Create;
  FLock.Enter;
  try
    PegaMetodosRecursivo(TypeName, 0);
  finally
    FLock.Leave;
    SeenSignatures.Free;
    Visited.Free;
  end;
end;

initialization
  GSymbolIndex := TSymbolIndex.Create;

finalization
  FreeAndNil(GSymbolIndex);

end.
