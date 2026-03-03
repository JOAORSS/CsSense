unit GoToDefinition;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, Vcl.Forms,
  Vcl.AppEvnts, ToolsAPI, SQLiteEngine, SymbolTypes, ExtratorUnit;

type
  TGoToManager = class
  private
    FAppEvents: TApplicationEvents;
    procedure AppMessage(var Msg: TMsg; var Handled: Boolean);
    function GetWordAtCursor(EditView: IOTAEditView): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ExecutarGoToDefinition;
  end;

var
  GoToManager: TGoToManager;

implementation

constructor TGoToManager.Create;
begin
  inherited Create;
  FAppEvents := TApplicationEvents.Create(nil);
  FAppEvents.OnMessage := AppMessage;
end;

destructor TGoToManager.Destroy;
begin
  FAppEvents.Free;
  inherited;
end;

function TGoToManager.GetWordAtCursor(EditView: IOTAEditView): string;
var
  Reader: IOTAEditReader;
  Buf: array[0..8191] of Byte;
  BytesRead: Integer;
  Offset: Integer;
  MemStream: TMemoryStream;
  S: AnsiString;
  LineText: string;
  LineNum, ColNum, StartCol, EndCol: Integer;
  Lines: TArray<string>;
begin
  Result := '';
  if not Assigned(EditView) then Exit;

  Reader := EditView.Buffer.CreateReader;
  if not Assigned(Reader) then Exit;

  MemStream := TMemoryStream.Create;
  try
    Offset := 0;
    repeat
      BytesRead := Reader.GetText(Offset, @Buf[0], SizeOf(Buf));
      if BytesRead > 0 then
      begin
        MemStream.WriteBuffer(Buf[0], BytesRead);
        Inc(Offset, BytesRead);
      end;
    until BytesRead = 0;

    if MemStream.Size > 0 then
    begin
      SetString(S, PAnsiChar(MemStream.Memory), MemStream.Size);

      LineNum := EditView.CursorPos.Line;
      ColNum := EditView.CursorPos.Col;

      Lines := string(S).Split([#10]);
      if LineNum - 1 > High(Lines) then Exit;

      LineText := Lines[LineNum - 1].TrimRight([#13]);
      if ColNum > Length(LineText) + 1 then Exit;

      if (ColNum > 1) and (ColNum > Length(LineText)) then Dec(ColNum);
      if (ColNum > 1) and not CharInSet(LineText[ColNum], ['a'..'z', 'A'..'Z', '0'..'9', '_']) then Dec(ColNum);

      if not CharInSet(LineText[ColNum], ['a'..'z', 'A'..'Z', '0'..'9', '_']) then Exit;

      StartCol := ColNum;
      while (StartCol > 1) and CharInSet(LineText[StartCol - 1], ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
        Dec(StartCol);

      EndCol := ColNum;
      while (EndCol <= Length(LineText)) and CharInSet(LineText[EndCol], ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
        Inc(EndCol);

      Result := Copy(LineText, StartCol, EndCol - StartCol);
    end;
  finally
    MemStream.Free;
  end;
end;

procedure TGoToManager.ExecutarGoToDefinition;
var
  EditSvc: IOTAEditorServices;
  EditView: IOTAEditView;
  ModSvc: IOTAModuleServices;
  WordToFind, TargetFile: string;
  TargetLine: Integer;
  DBRes: TArray<TSymbolInfo>;
  ActionSvc: IOTAActionServices;
begin
  if BorlandIDEServices.QueryInterface(IOTAEditorServices, EditSvc) <> S_OK then Exit;
  EditView := EditSvc.TopView;
  if not Assigned(EditView) then Exit;

  WordToFind := GetWordAtCursor(EditView);
  if WordToFind = '' then Exit;

  TargetFile := '';
  TargetLine := 1;

  if Assigned(GLocalDB) and GLocalDB.IsConnected then
  begin
    DBRes := GLocalDB.QuerySymbolByName(LowerCase(WordToFind));
    if Length(DBRes) > 0 then
    begin
      TargetFile := DBRes[0].FileName;
      TargetLine := DBRes[0].Line;
    end;
  end;

  if (TargetFile = '') and Assigned(GPublicDB) and GPublicDB.IsConnected then
  begin
    DBRes := GPublicDB.QuerySymbolByName(LowerCase(WordToFind));
    if Length(DBRes) > 0 then
    begin
      TargetFile := DBRes[0].FileName;
      TargetLine := DBRes[0].Line;
    end;
  end;

  if (TargetFile <> '') and FileExists(TargetFile) then
  begin
    if BorlandIDEServices.QueryInterface(IOTAModuleServices, ModSvc) = S_OK then
    begin
      if BorlandIDEServices.QueryInterface(IOTAActionServices, ActionSvc) = S_OK then
      begin
        ActionSvc.OpenFile(TargetFile);

        EditView := EditSvc.TopView;
        if Assigned(EditView) then
        begin
          EditView.Position.Move(TargetLine, 1);
          EditView.MoveViewToCursor;
          EditView.Paint;
        end;
      end;
    end;
  end;
end;

procedure TGoToManager.AppMessage(var Msg: TMsg; var Handled: Boolean);
var
  ClassNameBuf: array[0..255] of Char;
  IsCtrlDown: Boolean;
begin
  IsCtrlDown := (GetKeyState(VK_CONTROL) < 0);

  if Msg.message = WM_SETCURSOR then
  begin
    if IsCtrlDown then
    begin
      GetClassName(Msg.wParam, ClassNameBuf, Length(ClassNameBuf));
      if SameText(string(ClassNameBuf), 'TEditControl') then
      begin
        Winapi.Windows.SetCursor(LoadCursor(0, IDC_HAND));
        Handled := True;
        Exit;
      end;
    end;
  end;

  if Msg.message = WM_MBUTTONUP then
  begin
    if IsCtrlDown then
    begin
      GetClassName(Msg.hwnd, ClassNameBuf, Length(ClassNameBuf));
      if SameText(string(ClassNameBuf), 'TEditControl') then
      begin
        ExecutarGoToDefinition;
        Handled := True;
        Exit;
      end;
    end;
  end;
end;

initialization
  GoToManager := TGoToManager.Create;

finalization
  FreeAndNil(GoToManager);

end.
