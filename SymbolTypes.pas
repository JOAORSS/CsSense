unit SymbolTypes;

interface

type
  TSymbolKind = (skVar, skType, skMethod, skProperty, skConst);

  TSymbolInfo = record
    Name: string;
    Signature: string;
    TypeName: string;
    DataType: string;
    Kind: TSymbolKind;
    FileName: string;
    Line: Integer;
    Visibility: Integer;
    ParentType: string;
    InheritDepth: Integer;
  end;

implementation

end.
