program rundiagtests;

{$mode objfpc}{$H+}
{$DEFINE ENABLE_LCL_SOCKET_DIAG}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, consoletestrunner,
  LazLoggerBase,
  TestDiagRingBuffer,
  TestDiagServer;

type
  TDiagTestRunner = class(TTestRunner)
  end;

var
  App: TDiagTestRunner;
begin
  DebugLn('=== LCL Diagnostic Server Tests ===');
  App := TDiagTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'LCL Diagnostic Ring Buffer and Server Tests';
    App.Run;
  finally
    App.Free;
  end;
end.
