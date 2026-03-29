program testserversimple;

{$mode objfpc}{$H+}
{$DEFINE ENABLE_LCL_SOCKET_DIAG}

uses
  {$IFDEF UNIX}
  cthreads, BaseUnix,
  {$ENDIF}
  Classes, SysUtils, Sockets, ssockets,
  Interfaces,
  LCLDiagServer;

var
  Server: TLCLDiagServer;
  Sock: TInetSocket;
  Buf: array[0..4095] of Byte;
  Line, Resp: string;
  N: Integer;

procedure Step(const S: string);
begin
  WriteLn(S);
  Flush(Output);
end;

procedure SendRecv(ASock: TInetSocket; const ACmd: string);
var
  TV: TTimeVal;
  FDS: TFDSet;
  Sel: Integer;
begin
  Line := ACmd + #10;
  Step('  SEND: ' + ACmd);
  ASock.WriteBuffer(Line[1], Length(Line));
  Resp := '';

  { Use select() with 5 second timeout so we don't hang forever }
  TV.tv_sec := 5;
  TV.tv_usec := 0;
  fpFD_ZERO(FDS);
  fpFD_SET(ASock.Handle, FDS);
  Sel := fpSelect(ASock.Handle + 1, @FDS, nil, nil, @TV);
  if Sel <= 0 then begin
    Step('  RECV: (timeout or error, select=' + IntToStr(Sel) + ')');
    Exit;
  end;

  repeat
    N := ASock.Read(Buf{%H-}, SizeOf(Buf));
    if N <= 0 then begin
      Step('  RECV: (connection closed)');
      Exit;
    end;
    Resp := Resp + Copy(PChar(@Buf[0]), 1, N);
  until Pos(#10, Resp) > 0;
  Step('  RECV: ' + Trim(Resp));
end;

begin
  Step('1. Creating server on port 14747...');
  Server := TLCLDiagServer.Create(14747);

  Step('2. Starting server thread...');
  Server.Start;

  Step('3. Waiting for server ready...');
  Server.WaitReady;
  Step('   Server bound to port ' + IntToStr(Server.Port));

  Step('4. Pushing events to DiagRing...');
  if DiagRing <> nil then begin
    DiagRing.Push('test event 1');
    DiagRing.Push('test event 2');
    Step('   Pushed 2 events');
  end else
    Step('   DiagRing is NIL');

  Step('5. Connecting client...');
  Sock := TInetSocket.Create('127.0.0.1', Server.Port);

  Step('6. Sending ping...');
  SendRecv(Sock, '{"id":1,"cmd":"ping"}');

  Step('7. Sending stats...');
  SendRecv(Sock, '{"id":2,"cmd":"stats"}');

  Step('8. Sending events query...');
  SendRecv(Sock, '{"id":3,"cmd":"events","since_seq":0,"max":10}');

  Step('9. Sending unknown command...');
  SendRecv(Sock, '{"id":4,"cmd":"bogus"}');

  Step('10. Closing client socket...');
  Sock.Free;

  Step('11. Calling StopListening...');
  Server.StopListening;

  Step('12. Calling WaitFor...');
  Server.WaitFor;

  Step('13. Freeing server...');
  Server.Free;

  Step('14. Done. Exiting...');
end.
