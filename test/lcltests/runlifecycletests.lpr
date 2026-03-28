program runlifecycletests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, consoletestrunner,
  Interfaces, // Initialize widgetset
  Forms, Controls, StdCtrls,
  LazLoggerBase,
  TestFormLifecycle;

type
  TMyTestRunner = class(TTestRunner)
  end;

var
  App: TMyTestRunner;
begin
  DebugLn('=== LCL Lifecycle Tests ===');
  App := TMyTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'LCL Form Lifecycle Tests';
    App.Run;
  finally
    App.Free;
  end;
end.
