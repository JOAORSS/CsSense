unit ExtratorUnit;

interface

uses
  System.SysUtils, System.Classes, System.StrUtils, System.IOUtils, System.Generics.Collections, SymbolTypes;

type
  TItemRecord = record
    Utilizavel: string;
    Visual: string;
    TipoNome: string;
    TipoRetorno: string;
    Linha: Integer;
    Visibilidade: Integer;
    Tipo: Integer;
    ParentType: string;
  end;

  TExtratoUnit = record
    Tipos: TArray<TItemRecord>;
    Variaveis: TArray<TItemRecord>;
    VariaveisLocais: TArray<TItemRecord>;
    Metodos: TArray<TItemRecord>;
    Propriedades: TArray<TItemRecord>;
    Constantes: TArray<TItemRecord>;
  end;

function ProcessarArquivoDelphi(const CaminhoArquivo: string): TExtratoUnit;
function ExtrairMetodosEPropriedades(const Texto: string): TExtratoUnit;
function ExtrairUses(const Texto: string): TArray<string>;

implementation

type
  TTokenType = (ttIdent, ttSymbol, ttString, ttEOF);

  TLexer = class
  private
    FText: string;
    FPos: Integer;
    FLen: Integer;
    FLine: Integer;
    procedure AdvancePos(Count: Integer = 1);
    procedure SkipWhitespaceAndComments;
  public
    constructor Create(const AText: string);
    function NextToken(out TokenStr: string): TTokenType;
    function GetText(StartP, EndP: Integer): string;
    function GetPos: Integer;
    function GetLine: Integer;
  end;

  TParserState = (psGlobal, psClass);

  TParser = class
  private
    FLexer: TLexer;
    FToken: TTokenType;
    FTokenStr: string;
    FState: TParserState;
    FContext: Integer;
    FCurrentClass: string;
    FCurrentVis: Integer;
    FNestedDepth: Integer;
    FExtrato: TExtratoUnit;
    procedure Advance;
    procedure SkipGenerics;
    procedure SkipGenericsAsText(var OutStr: string);
    procedure SkipParameters;
    procedure SkipAttributes;
    procedure ParseGlobal;
    procedure ParseClassMember;
    procedure ParseMethod;
    procedure ParseProperty;
    procedure ParseField(IsGlobal: Boolean);
    procedure AddSymbol(Kind: Integer; const Name, TypeName, DataType, Sig: string);
  public
    constructor Create(const AText: string);
    destructor Destroy; override;
    function Parse: TExtratoUnit;
  end;

function ProcessarArquivoDelphi(const CaminhoArquivo: string): TExtratoUnit;
var
  ConteudoBruto: string;
begin
  if not FileExists(CaminhoArquivo) then
  begin
    Result.Tipos := nil;
    Result.Variaveis := nil;
    Result.VariaveisLocais := nil;
    Result.Metodos := nil;
    Result.Propriedades := nil;
    Result.Constantes := nil;
    Exit;
  end;

  try
    ConteudoBruto := TFile.ReadAllText(CaminhoArquivo);
    Result := ExtrairMetodosEPropriedades(ConteudoBruto);
  except
    Result.Tipos := nil;
    Result.Variaveis := nil;
    Result.VariaveisLocais := nil;
    Result.Metodos := nil;
    Result.Propriedades := nil;
    Result.Constantes := nil;
  end;
end;

function ExtrairMetodosEPropriedades(const Texto: string): TExtratoUnit;
var
  Parser: TParser;
begin
  Parser := TParser.Create(Texto);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

function ExtrairUses(const Texto: string): TArray<string>;
var
  Lexer: TLexer;
  Tok: TTokenType;
  S: string;
  InUses: Boolean;
  List: TStringList;
  I: Integer;
begin
  SetLength(Result, 0);
  if Texto = '' then Exit;

  List := TStringList.Create;
  try
    Lexer := TLexer.Create(Texto);
    try
      InUses := False;
      Tok := Lexer.NextToken(S);

      while Tok <> ttEOF do
      begin
        if Tok = ttIdent then
        begin
          if SameText(S, 'uses') then
            InUses := True
          else if InUses then
          begin
            if not SameText(S, 'in') then
              List.Add(S);
          end;
        end
        else if Tok = ttSymbol then
        begin
          if (S = ';') and InUses then
            InUses := False;
        end;
        Tok := Lexer.NextToken(S);
      end;
    finally
      Lexer.Free;
    end;

    SetLength(Result, List.Count);
    for I := 0 to List.Count - 1 do
      Result[I] := List[I];
  finally
    List.Free;
  end;
end;

constructor TLexer.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
  FLen := Length(AText);
  FLine := 1;
end;

procedure TLexer.AdvancePos(Count: Integer = 1);
var
  I: Integer;
begin
  for I := 1 to Count do
  begin
    if FPos <= FLen then
    begin
      if FText[FPos] = #10 then Inc(FLine);
      Inc(FPos);
    end;
  end;
end;

procedure TLexer.SkipWhitespaceAndComments;
var
  C, NextC: Char;
begin
  while FPos <= FLen do
  begin
    C := FText[FPos];
    if CharInSet(C, [#1..#32]) then
    begin
      AdvancePos;
      Continue;
    end;

    if FPos < FLen then NextC := FText[FPos + 1] else NextC := #0;

    if (C = '/') and (NextC = '/') then
    begin
      AdvancePos(2);
      while (FPos <= FLen) and not CharInSet(FText[FPos], [#10, #13]) do AdvancePos;
      Continue;
    end;

    if C = '{' then
    begin
      AdvancePos;
      while (FPos <= FLen) and (FText[FPos] <> '}') do AdvancePos;
      if FPos <= FLen then AdvancePos;
      Continue;
    end;

    if (C = '(') and (NextC = '*') then
    begin
      AdvancePos(2);
      while FPos < FLen do
      begin
        if (FText[FPos] = '*') and (FPos + 1 <= FLen) and (FText[FPos+1] = ')') then
        begin
          AdvancePos(2);
          Break;
        end;
        AdvancePos;
      end;
      Continue;
    end;

    Break;
  end;
end;

function TLexer.NextToken(out TokenStr: string): TTokenType;
var
  StartPos: Integer;
  C: Char;
begin
  SkipWhitespaceAndComments;
  if FPos > FLen then
  begin
    TokenStr := '';
    Exit(ttEOF);
  end;

  StartPos := FPos;
  C := FText[FPos];

  if C = '''' then
  begin
    AdvancePos;
    while FPos <= FLen do
    begin
      if FText[FPos] = '''' then
      begin
        AdvancePos;
        if (FPos <= FLen) and (FText[FPos] = '''') then
          AdvancePos
        else
          Break;
      end
      else
        AdvancePos;
    end;
    TokenStr := Copy(FText, StartPos, FPos - StartPos);
    Exit(ttString);
  end;

  if CharInSet(C, ['a'..'z', 'A'..'Z', '_']) then
  begin
    while (FPos <= FLen) and CharInSet(FText[FPos], ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      AdvancePos;
    TokenStr := Copy(FText, StartPos, FPos - StartPos);
    Exit(ttIdent);
  end;

  if CharInSet(C, ['0'..'9', '$']) then
  begin
    while (FPos <= FLen) and CharInSet(FText[FPos], ['0'..'9', 'A'..'F', 'a'..'f', 'x', 'X', '.', '$']) do
      AdvancePos;
    TokenStr := Copy(FText, StartPos, FPos - StartPos);
    Exit(ttIdent);
  end;

  TokenStr := C;
  AdvancePos;
  Result := ttSymbol;
end;

function TLexer.GetText(StartP, EndP: Integer): string;
begin
  if EndP > StartP then
    Result := Copy(FText, StartP, EndP - StartP)
  else
    Result := '';
end;

function TLexer.GetPos: Integer;
begin
  Result := FPos;
end;

function TLexer.GetLine: Integer;
begin
  Result := FLine;
end;

constructor TParser.Create(const AText: string);
begin
  inherited Create;
  FLexer := TLexer.Create(AText);
  FState := psGlobal;
  FContext := 0;
  FCurrentVis := 2;
  FNestedDepth := 0;
  FCurrentClass := '';
  FExtrato.Tipos := nil;
  FExtrato.Variaveis := nil;
  FExtrato.VariaveisLocais := nil;
  FExtrato.Metodos := nil;
  FExtrato.Propriedades := nil;
  FExtrato.Constantes := nil;
end;

destructor TParser.Destroy;
begin
  FLexer.Free;
  inherited;
end;

procedure TParser.Advance;
begin
  FToken := FLexer.NextToken(FTokenStr);
end;

procedure TParser.SkipGenerics;
var
  Depth: Integer;
begin
  Depth := 1;
  Advance;
  while (Depth > 0) and (FToken <> ttEOF) do
  begin
    if FTokenStr = '<' then Inc(Depth)
    else if FTokenStr = '>' then Dec(Depth);
    Advance;
  end;
end;

procedure TParser.SkipGenericsAsText(var OutStr: string);
var
  Depth: Integer;
begin
  OutStr := OutStr + FTokenStr;
  Depth := 1;
  Advance;
  while (Depth > 0) and (FToken <> ttEOF) do
  begin
    OutStr := OutStr + FTokenStr;
    if FTokenStr = '<' then Inc(Depth)
    else if FTokenStr = '>' then Dec(Depth);
    Advance;
  end;
end;

procedure TParser.SkipParameters;
var
  Depth: Integer;
begin
  Depth := 1;
  Advance;
  while (Depth > 0) and (FToken <> ttEOF) do
  begin
    if FTokenStr = '(' then Inc(Depth)
    else if FTokenStr = ')' then Dec(Depth);
    Advance;
  end;
end;

procedure TParser.SkipAttributes;
var
  Depth: Integer;
begin
  Depth := 1;
  Advance;
  while (Depth > 0) and (FToken <> ttEOF) do
  begin
    if FTokenStr = '[' then Inc(Depth)
    else if FTokenStr = ']' then Dec(Depth);
    Advance;
  end;
end;

function IsMethodDirective(const S: string): Boolean;
begin
  Result := SameText(S, 'overload') or SameText(S, 'virtual') or SameText(S, 'override') or
            SameText(S, 'abstract') or SameText(S, 'reintroduce') or SameText(S, 'dynamic') or
            SameText(S, 'stdcall') or SameText(S, 'cdecl') or SameText(S, 'pascal') or
            SameText(S, 'register') or SameText(S, 'safecall') or SameText(S, 'inline') or
            SameText(S, 'deprecated') or SameText(S, 'final') or SameText(S, 'message');
end;

function IsPropDirective(const S: string): Boolean;
begin
  Result := SameText(S, 'read') or SameText(S, 'write') or SameText(S, 'default') or
            SameText(S, 'nodefault') or SameText(S, 'stored') or SameText(S, 'implements') or
            SameText(S, 'readonly') or SameText(S, 'writeonly') or SameText(S, 'index');
end;

procedure TParser.AddSymbol(Kind: Integer; const Name, TypeName, DataType, Sig: string);
var
  Item: TItemRecord;
begin
  if Pos('.', Name) > 0 then Exit;
  if Pos(' ', Name) > 0 then Exit;
  if SameText(Name, 'strict') or SameText(Name, 'private') or SameText(Name, 'public') or
     SameText(Name, 'protected') or SameText(Name, 'published') or SameText(Name, 'class') or
     SameText(Name, 'record') or SameText(Name, 'type') then Exit;

  Item.Utilizavel := Name;
  Item.Visual := Sig;
  Item.TipoNome := TypeName;
  Item.TipoRetorno := DataType;
  Item.Linha := FLexer.GetLine;
  Item.Visibilidade := FCurrentVis;
  Item.Tipo := Kind;
  Item.ParentType := '';

  if Kind = 0 then
  begin
    SetLength(FExtrato.Propriedades, Length(FExtrato.Propriedades) + 1);
    FExtrato.Propriedades[High(FExtrato.Propriedades)] := Item;
  end
  else if Kind = 1 then
  begin
    SetLength(FExtrato.Metodos, Length(FExtrato.Metodos) + 1);
    FExtrato.Metodos[High(FExtrato.Metodos)] := Item;
  end
  else if Kind = 3 then
  begin
    SetLength(FExtrato.Variaveis, Length(FExtrato.Variaveis) + 1);
    FExtrato.Variaveis[High(FExtrato.Variaveis)] := Item;
  end
  else if Kind = 4 then
  begin
    Item.ParentType := DataType;
    Item.TipoRetorno := '';
    SetLength(FExtrato.Tipos, Length(FExtrato.Tipos) + 1);
    FExtrato.Tipos[High(FExtrato.Tipos)] := Item;
  end
  else if Kind = 5 then
  begin
    SetLength(FExtrato.Constantes, Length(FExtrato.Constantes) + 1);
    FExtrato.Constantes[High(FExtrato.Constantes)] := Item;
  end;
end;

procedure TParser.ParseField(IsGlobal: Boolean);
var
  Names: TList<string>;
  TypeStr: string;
  I: Integer;
begin
  Names := TList<string>.Create;
  try
    Names.Add(FTokenStr);
    Advance;

    while FTokenStr = ',' do
    begin
      Advance;
      if FToken = ttIdent then
      begin
        Names.Add(FTokenStr);
        Advance;
      end;
    end;

    if FTokenStr = ':' then
    begin
      Advance;
      TypeStr := '';
      while (FToken <> ttEOF) and (FTokenStr <> ';') and (FTokenStr <> '=') do
      begin
        TypeStr := TypeStr + FTokenStr;
        Advance;
        if FTokenStr = '<' then SkipGenericsAsText(TypeStr);
      end;

      if FTokenStr = '=' then
      begin
        while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
      end;

      if FTokenStr = ';' then Advance;

      for I := 0 to Names.Count - 1 do
      begin
        if IsGlobal then
          AddSymbol(3, Names[I], '', TypeStr, Names[I] + ': ' + TypeStr)
        else
          AddSymbol(3, Names[I], FCurrentClass, TypeStr, Names[I] + ': ' + TypeStr);
      end;
    end
    else
    begin
      while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
      if FTokenStr = ';' then Advance;
    end;
  finally
    Names.Free;
  end;
end;

procedure TParser.ParseMethod;
var
  StartP, EndP: Integer;
  MName, MType, Sig: string;
  IsFunc: Boolean;
begin
  IsFunc := SameText(FTokenStr, 'function');
  StartP := FLexer.GetPos - Length(FTokenStr);
  Advance;

  if FToken <> ttIdent then
  begin
    while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
    if FTokenStr = ';' then Advance;
    Exit;
  end;

  MName := FTokenStr;
  Advance;

  if FTokenStr = '<' then SkipGenerics;
  if FTokenStr = '(' then SkipParameters;

  MType := '';
  if IsFunc and (FTokenStr = ':') then
  begin
    Advance;
    while (FToken <> ttEOF) and (FTokenStr <> ';') and not IsMethodDirective(FTokenStr) do
    begin
      MType := MType + FTokenStr;
      Advance;
      if FTokenStr = '<' then SkipGenericsAsText(MType);
    end;
  end;

  while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
  EndP := FLexer.GetPos;
  if FTokenStr = ';' then Advance;

  Sig := Trim(FLexer.GetText(StartP, EndP));
  Sig := ReplaceStr(Sig, #13, '');
  Sig := ReplaceStr(Sig, #10, ' ');

  AddSymbol(1, MName, FCurrentClass, MType, Sig);
end;

procedure TParser.ParseProperty;
var
  StartP, EndP: Integer;
  PName, PType, Sig: string;
begin
  StartP := FLexer.GetPos - Length(FTokenStr);
  Advance;

  if FToken <> ttIdent then
  begin
    while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
    if FTokenStr = ';' then Advance;
    Exit;
  end;

  PName := FTokenStr;
  Advance;

  if FTokenStr = '[' then SkipAttributes;

  PType := '';
  if FTokenStr = ':' then
  begin
    Advance;
    while (FToken <> ttEOF) and (FTokenStr <> ';') and not IsPropDirective(FTokenStr) do
    begin
      PType := PType + FTokenStr;
      Advance;
      if FTokenStr = '<' then SkipGenericsAsText(PType);
    end;
  end;

  while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
  EndP := FLexer.GetPos;
  if FTokenStr = ';' then Advance;

  Sig := Trim(FLexer.GetText(StartP, EndP));
  Sig := ReplaceStr(Sig, #13, '');
  Sig := ReplaceStr(Sig, #10, ' ');

  AddSymbol(0, PName, FCurrentClass, PType, Sig);
end;

procedure TParser.ParseGlobal;
var
  TypeName, ParentType, SetBaseType: string;
  IsInterfaceDecl, IsRecordDecl: Boolean;
begin
  if SameText(FTokenStr, 'implementation') then
  begin
    FToken := ttEOF;
    Exit;
  end;

  if SameText(FTokenStr, 'type') then
  begin
    FContext := 1;
    Advance;
    Exit;
  end
  else if SameText(FTokenStr, 'var') or SameText(FTokenStr, 'threadvar') then
  begin
    FContext := 2;
    Advance;
    Exit;
  end
  else if SameText(FTokenStr, 'const') then
  begin
    FContext := 3;
    Advance;
    Exit;
  end
  else if SameText(FTokenStr, 'procedure') or SameText(FTokenStr, 'function') then
  begin
    FContext := 0;
    FCurrentClass := '';
    ParseMethod;
    Exit;
  end;

  if (FContext = 0) or (FContext = 1) then
  begin
    if FToken = ttIdent then
    begin
      TypeName := FTokenStr;
      Advance;
      if FTokenStr = '<' then SkipGenerics;

      if FTokenStr = '=' then
      begin
        Advance;
        if FTokenStr = '[' then SkipAttributes;

        if SameText(FTokenStr, 'class') or SameText(FTokenStr, 'record') or
           SameText(FTokenStr, 'interface') or SameText(FTokenStr, 'dispinterface') then
        begin
          IsInterfaceDecl := SameText(FTokenStr, 'interface') or SameText(FTokenStr, 'dispinterface');
          IsRecordDecl := SameText(FTokenStr, 'record');
          FContext := 1;
          Advance;

          if SameText(FTokenStr, 'of') then
          begin
            AddSymbol(4, TypeName, '', 'class', TypeName + ' = class of');
            while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
            if FTokenStr = ';' then Advance;
            Exit;
          end;

          if SameText(FTokenStr, 'helper') then
          begin
            Advance;
            if SameText(FTokenStr, 'for') then
            begin
              Advance;
              ParentType := FTokenStr;
              AddSymbol(4, TypeName, '', ParentType, TypeName + ' = helper for ' + ParentType);
              FState := psClass;
              FCurrentClass := TypeName;
              FCurrentVis := 2;
              FNestedDepth := 0;
              Exit;
            end;
          end;

          ParentType := '';
          if FTokenStr = '(' then
          begin
            Advance;
            while (FToken <> ttEOF) and (FTokenStr <> ')') do
            begin
              ParentType := ParentType + FTokenStr;
              Advance;
            end;
            if FTokenStr = ')' then Advance;
          end;

          if ParentType = '' then
          begin
            if IsInterfaceDecl and not SameText(TypeName, 'IInterface') then
              ParentType := 'IInterface'
            else if not IsInterfaceDecl and not IsRecordDecl and not SameText(TypeName, 'TObject') then
              ParentType := 'TObject';
          end;

          AddSymbol(4, TypeName, '', ParentType, TypeName + ' = class');

          if FTokenStr = ';' then
          begin
            Advance;
          end
          else
          begin
            FState := psClass;
            FCurrentClass := TypeName;
            FCurrentVis := 3;
            FNestedDepth := 0;
          end;
          Exit;
        end
        else
        begin
          if FContext = 1 then
          begin
            if FTokenStr = '(' then
            begin
              AddSymbol(4, TypeName, '', 'enum', TypeName + ' = (...)');
              Advance;
              while (FToken <> ttEOF) and (FTokenStr <> ')') do
              begin
                if FToken = ttIdent then
                begin
                  AddSymbol(5, FTokenStr, TypeName, TypeName, FTokenStr);
                  Advance;
                  if FTokenStr = '=' then
                  begin
                    while (FToken <> ttEOF) and (FTokenStr <> ',') and (FTokenStr <> ')') do Advance;
                  end;
                end
                else
                begin
                  Advance;
                end;
              end;
              if FTokenStr = ')' then Advance;
              if FTokenStr = ';' then Advance;
              Exit;
            end
            else if SameText(FTokenStr, 'set') then
            begin
              Advance;
              if SameText(FTokenStr, 'of') then
              begin
                Advance;
                SetBaseType := '';
                while (FToken <> ttEOF) and (FTokenStr <> ';') do
                begin
                  SetBaseType := SetBaseType + FTokenStr;
                  Advance;
                end;
                AddSymbol(4, TypeName, SetBaseType, 'set', TypeName + ' = set of ' + SetBaseType);
                if FTokenStr = ';' then Advance;
                Exit;
              end;
            end
            else
            begin
              AddSymbol(4, TypeName, '', FTokenStr, TypeName + ' = ' + FTokenStr);
            end;
          end;
          while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
          if FTokenStr = ';' then Advance;
          Exit;
        end;
      end
      else if FTokenStr = ';' then
      begin
        if FContext = 1 then
          AddSymbol(4, TypeName, '', '', TypeName + ';');
        Advance;
        Exit;
      end
      else
      begin
        Exit;
      end;
    end;
  end
  else if FContext = 2 then
  begin
    if FToken = ttIdent then
    begin
      ParseField(True);
      Exit;
    end;
  end;

  Advance;
end;

procedure TParser.ParseClassMember;
begin
  if SameText(FTokenStr, 'end') then
  begin
    if FNestedDepth > 0 then
    begin
      Dec(FNestedDepth);
      Advance;
    end
    else
    begin
      FState := psGlobal;
      Advance;
    end;
    Exit;
  end;

  if SameText(FTokenStr, 'class') then
  begin
    Advance;
    if SameText(FTokenStr, 'operator') then
    begin
      while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
      if FTokenStr = ';' then Advance;
      Exit;
    end
    else if SameText(FTokenStr, 'procedure') or SameText(FTokenStr, 'function') or
            SameText(FTokenStr, 'constructor') or SameText(FTokenStr, 'destructor') then
    begin
      if FNestedDepth = 0 then ParseMethod
      else
      begin
        while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
        if FTokenStr = ';' then Advance;
      end;
      Exit;
    end
    else if SameText(FTokenStr, 'property') then
    begin
      if FNestedDepth = 0 then ParseProperty
      else
      begin
        while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
        if FTokenStr = ';' then Advance;
      end;
      Exit;
    end
    else if SameText(FTokenStr, 'var') then
    begin
      Advance;
      Exit;
    end
    else if SameText(FTokenStr, 'of') then
    begin
      while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
      if FTokenStr = ';' then Advance;
      Exit;
    end
    else
    begin
      Inc(FNestedDepth);
      Exit;
    end;
  end;

  if SameText(FTokenStr, 'record') or SameText(FTokenStr, 'interface') or SameText(FTokenStr, 'dispinterface') then
  begin
    Inc(FNestedDepth);
    Advance;
    Exit;
  end;

  if SameText(FTokenStr, 'private') or SameText(FTokenStr, 'protected') or
     SameText(FTokenStr, 'public') or SameText(FTokenStr, 'published') then
  begin
    if FNestedDepth = 0 then
    begin
      if SameText(FTokenStr, 'private') then FCurrentVis := 0
      else if SameText(FTokenStr, 'protected') then FCurrentVis := 1
      else if SameText(FTokenStr, 'public') then FCurrentVis := 2
      else if SameText(FTokenStr, 'published') then FCurrentVis := 3;
    end;
    Advance;
    Exit;
  end;

  if SameText(FTokenStr, 'strict') then
  begin
    Advance;
    if FNestedDepth = 0 then
    begin
      if SameText(FTokenStr, 'private') then FCurrentVis := 0
      else if SameText(FTokenStr, 'protected') then FCurrentVis := 1;
    end;
    Advance;
    Exit;
  end;

  if SameText(FTokenStr, 'procedure') or SameText(FTokenStr, 'function') or
     SameText(FTokenStr, 'constructor') or SameText(FTokenStr, 'destructor') then
  begin
    if FNestedDepth = 0 then
      ParseMethod
    else
    begin
       while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
       if FTokenStr = ';' then Advance;
    end;
    Exit;
  end;

  if SameText(FTokenStr, 'property') then
  begin
    if FNestedDepth = 0 then
      ParseProperty
    else
    begin
       while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
       if FTokenStr = ';' then Advance;
    end;
    Exit;
  end;

  if FToken = ttIdent then
  begin
    if FNestedDepth = 0 then
      ParseField(False)
    else
    begin
       while (FToken <> ttEOF) and (FTokenStr <> ';') do Advance;
       if FTokenStr = ';' then Advance;
    end;
    Exit;
  end;

  Advance;
end;

function TParser.Parse: TExtratoUnit;
begin
  Advance;
  while FToken <> ttEOF do
  begin
    if SameText(FTokenStr, 'implementation') then Break;

    if FState = psGlobal then
      ParseGlobal
    else if FState = psClass then
      ParseClassMember
    else
      Advance;
  end;

  Result := FExtrato;
end;

end.
